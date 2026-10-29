"""
APS 수요 예측 (머신러닝)
─────────────────────────────────────────────
매일 밤 GitHub Actions(.github/workflows/forecast.yml)에서 실행.

1) Supabase에서 매출(aps_sales_daily) + 행사(aps_promotions)를 읽음
2) 지난 행사의 실제 효과(평소 대비 배수)를 계산해 aps_promotions.actual_uplift에 기록
3) LightGBM 모델 학습 — 요일, 최근 추세, 같은 요일 평균, 행사, 공휴일·명절 거리 등
   + 딥러닝(Amazon Chronos-Bolt, 미리 학습된 시계열 모델 — 우리 데이터로 다시 학습하지 않음)
4) 마지막 4주를 "모르는 척" 하고 예측해 기존 방식(최근 8주 같은 요일 평균) / ML / 딥러닝 정확도 비교
   상품마다 가장 정확한 쪽을 사용 (딥러닝은 다른 두 쪽보다 확실히(3%+) 나을 때만)
5) 마지막 매출일 다음날부터 28일치 예측(+ 적게/많이 팔릴 때 범위)을 aps_forecast에 저장

로컬 시험:
  python forecast_aps.py --csv sales.csv [--promos promos.csv] --dry-run
  sales.csv  : date,code,name,qty
  promos.csv : code,start_date,end_date,kind,discount_pct,uplift
  딥러닝 끄기: FC_DL=0 · 모델 바꾸기: FC_DL_MODEL=amazon/chronos-bolt-base
"""
import os
import sys
import json
import argparse
import datetime as dt

import numpy as np
import pandas as pd
import requests

try:
    import lightgbm as lgb
except Exception:  # 설치 안 됐으면 기존 방식만
    lgb = None
try:
    import holidays as holidays_lib
except Exception:
    holidays_lib = None

SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://mmmpqmvwpuxqyxlxytsh.supabase.co")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")

HORIZON = 28          # 예측 일수 (마지막 매출일 다음날부터)
EVAL_DAYS = 28        # 정확도 비교에 쓰는 마지막 기간
EVAL_H = 14           # 비교 시 며칠 앞까지 맞히는지 (실제 계획 범위)
BASE_WEEKS = 8        # 기존 방식: 최근 8주 같은 요일 평균
MIN_DAYS = 35         # 매출 올라온 날짜가 이보다 적으면 기존 방식만
MIN_AGE = 14          # 상품 판매 이력이 이보다 짧으면 기존 방식
ACTIVE_DAYS = 90      # 최근 90일 안에 팔린 상품만 예측
PROMO_MIN_SAMPLES = 30  # 행사일 학습 데이터가 이보다 적으면 행사일은 "기존 방식 × 배수"
DL_MODEL = os.environ.get("FC_DL_MODEL", "amazon/chronos-bolt-small")
DL_OFF = os.environ.get("FC_DL", "1").strip().lower() in ("0", "false", "no", "off")
DL_BATCH = 256
KIND_CODES = {"할인": 1, "1+1": 2, "기획전": 3, "타임딜": 4, "기타": 5}

KST = dt.timezone(dt.timedelta(hours=9))


def log(*a):
    print(*a, flush=True)


# ───────────────────────── Supabase ─────────────────────────
def _headers(extra=None):
    h = {"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}", "Content-Type": "application/json"}
    if extra:
        h.update(extra)
    return h


def sb_get_all(table, params):
    rows, off, size = [], 0, 1000
    while True:
        p = dict(params, limit=size, offset=off)
        r = requests.get(f"{SUPABASE_URL}/rest/v1/{table}", headers=_headers(), params=p, timeout=60)
        r.raise_for_status()
        chunk = r.json()
        rows += chunk
        if len(chunk) < size:
            return rows
        off += size


def sb_post(table, rows, returning=False):
    out = []
    for i in range(0, len(rows), 500):
        r = requests.post(f"{SUPABASE_URL}/rest/v1/{table}", headers=_headers(
            {"Prefer": "return=representation" if returning else "return=minimal"}),
            data=json.dumps(rows[i:i + 500], ensure_ascii=False, default=str), timeout=60)
        if not r.ok:
            raise RuntimeError(f"{table} 저장 실패 {r.status_code}: {r.text[:300]}")
        if returning:
            out += r.json()
    return out


def sb_delete(table, params):
    r = requests.delete(f"{SUPABASE_URL}/rest/v1/{table}", headers=_headers(), params=params, timeout=60)
    if not r.ok:
        raise RuntimeError(f"{table} 삭제 실패 {r.status_code}: {r.text[:300]}")


def sb_patch(table, params, body):
    r = requests.patch(f"{SUPABASE_URL}/rest/v1/{table}", headers=_headers(), params=params,
                       data=json.dumps(body, default=str), timeout=60)
    if not r.ok:
        raise RuntimeError(f"{table} 수정 실패 {r.status_code}: {r.text[:300]}")


# ───────────────────────── 데이터 ─────────────────────────
def load_from_supabase():
    sales = pd.DataFrame(sb_get_all("aps_sales_daily", {"select": "date,code,name,qty", "order": "date.asc,code.asc"}))
    try:
        promos = pd.DataFrame(sb_get_all("aps_promotions", {"select": "*", "order": "id.asc"}))
    except Exception as e:
        log("⚠ aps_promotions 읽기 실패 (setup_aps_forecast.sql 실행 필요?):", e)
        promos = pd.DataFrame()
    return sales, promos


def load_from_csv(sales_path, promos_path):
    sales = pd.read_csv(sales_path, dtype={"code": str})
    promos = pd.read_csv(promos_path, dtype={"code": str}) if promos_path else pd.DataFrame()
    if len(promos) and "id" not in promos:
        promos["id"] = range(1, len(promos) + 1)
    return sales, promos


def holiday_map(years):
    """{날짜: 이름} 한국 공휴일 (holidays 패키지 없으면 빈 dict)"""
    if holidays_lib is None:
        return {}
    try:
        return dict(holidays_lib.country_holidays("KR", years=years).items())
    except Exception:
        return {}


# ───────────────────────── 본체 ─────────────────────────
def build(sales, promos):
    sales = sales.copy()
    sales["date"] = pd.to_datetime(sales["date"]).dt.normalize()
    sales["code"] = sales["code"].astype(str).str.strip()
    sales["qty"] = pd.to_numeric(sales["qty"], errors="coerce").fillna(0)
    sales = sales[sales["code"] != ""]
    names = sales.sort_values("date").groupby("code")["name"].last().fillna("").to_dict()

    start, end = sales["date"].min(), sales["date"].max()
    cal = pd.date_range(start, end + pd.Timedelta(days=HORIZON), freq="D")
    T_end = (end - start).days            # 마지막 매출일 위치
    uploaded = pd.Series(False, index=cal)
    uploaded.loc[sales["date"].unique()] = True

    piv = sales.pivot_table(index="date", columns="code", values="qty", aggfunc="sum")
    Q = piv.reindex(cal)                   # 업로드 안 된 날 = NaN
    Q.loc[uploaded[uploaded].index] = Q.loc[uploaded[uploaded].index].fillna(0)
    first = sales.groupby("code")["date"].min()
    for c in Q.columns:                    # 첫 판매 이전 = 없던 상품
        Q.loc[Q.index < first[c], c] = np.nan
    Q.loc[Q.index > end] = np.nan
    codes = list(Q.columns)
    C = len(codes)
    col = {c: i for i, c in enumerate(codes)}

    # 행사 행렬
    P = np.zeros((len(cal), C), bool)
    P_idx = np.zeros((len(cal), C))        # 행사 며칠째
    P_len = np.zeros((len(cal), C))
    P_disc = np.full((len(cal), C), np.nan)
    P_kind = np.zeros((len(cal), C))
    P_user = np.full((len(cal), C), np.nan)
    plist = []
    if len(promos):
        for _, r in promos.iterrows():
            c = str(r.get("code", "")).strip()
            if c not in col:
                continue
            s, e = pd.to_datetime(r["start_date"]), pd.to_datetime(r["end_date"])
            plist.append({"id": r.get("id"), "c": col[c], "s": s, "e": e,
                          "user": pd.to_numeric(r.get("uplift"), errors="coerce"),
                          "disc": pd.to_numeric(r.get("discount_pct"), errors="coerce"),
                          "kind": KIND_CODES.get(str(r.get("kind") or "기타"), 5)})
    for p in plist:
        for d in pd.date_range(max(p["s"], cal[0]), min(p["e"], cal[-1])):
            t = (d - start).days
            j = p["c"]
            P[t, j] = True
            P_idx[t, j] = (d - p["s"]).days + 1
            P_len[t, j] = (p["e"] - p["s"]).days + 1
            if not np.isnan(p["disc"]):
                P_disc[t, j] = np.nanmax([P_disc[t, j], p["disc"]])
            P_kind[t, j] = p["kind"]
            if not np.isnan(p["user"]):
                P_user[t, j] = np.nanmax([P_user[t, j], p["user"]])

    # 공휴일·명절 — 고기 판매는 설날·추석 2~3주 전부터 늘고, 다른 공휴일은 전날·다음날 정도만 영향
    hol = holiday_map(range(start.year, cal[-1].year + 2))
    is_hol = np.array([d.date() in hol for d in cal], float)
    hdates = [pd.Timestamp(h) for h in sorted(hol)]
    major = [pd.Timestamp(h) for h, n in sorted(hol.items()) if ("설날" in n or "추석" in n) and "전날" in n]
    major = major or [pd.Timestamp(h) for h, n in sorted(hol.items()) if n in ("설날", "추석")]

    def dist(targets, cap):
        to = np.full(len(cal), cap + 1.0)
        since = np.full(len(cal), cap + 1.0)
        for i, d in enumerate(cal):
            for h in targets:
                k = (h - d).days
                if 0 <= k <= cap:
                    to[i] = min(to[i], k)
                if 0 <= -k <= cap:
                    since[i] = min(since[i], -k)
        return to, since

    to_hol, since_hol = dist(hdates, 3)
    to_major, since_major = dist(major, 21)

    Qv = Q.to_numpy(float)
    Pdf = pd.DataFrame(P, index=cal, columns=codes)
    # 평소 판매 = 행사일과 설날·추석 앞뒤(2주 전 ~ 5일 뒤)를 뺀 날 → 평소 기준이 명절 대목에 부풀지 않게
    near_major = (to_major <= 14) | (since_major <= 5)
    normal = (~Pdf).to_numpy() & ~near_major[:, None]
    Qnp = Q.where(pd.DataFrame(normal, index=cal, columns=codes))

    wk = cal.weekday.to_numpy()

    def dow_means(frame):
        out = []
        for d in range(7):
            fd = frame.where(pd.Series(wk == d, index=cal), axis=0)
            s = fd.rolling(BASE_WEEKS * 7, min_periods=1).sum()
            n = fd.rolling(BASE_WEEKS * 7, min_periods=1).count()
            out.append((s / n.replace(0, np.nan)).to_numpy(float))
        return np.stack(out)               # [7, T, C]

    DOW = dow_means(Q)                     # 기존 방식과 같은 값
    DOWNP = dow_means(Qnp)
    M14 = Q.rolling(14, min_periods=1).mean().to_numpy(float)
    M28 = Q.rolling(28, min_periods=1).mean().to_numpy(float)
    NP28 = Qnp.rolling(28, min_periods=1).mean().to_numpy(float)
    S28 = Q.rolling(28, min_periods=3).std().to_numpy(float)
    LAST = Q.ffill().to_numpy(float)
    up = uploaded.to_numpy()
    upP = Pdf.where(pd.Series(up, index=cal), axis=0, other=False).astype(float)
    PF28 = (upP.rolling(28, min_periods=1).sum().to_numpy(float) /
            np.maximum(pd.Series(up, index=cal).astype(float).rolling(28, min_periods=1).sum().to_numpy(float)[:, None], 1))
    # 업로드 된 적 있는 요일 (한 번도 매출 파일이 없던 요일은 예측 0 — 예: 일요일 휴무)
    dow_seen = np.array([up[:T_end + 1][wk[:T_end + 1] == d].any() for d in range(7)])

    # ── 지난 행사의 실제 효과 (평소 같은 요일 평균 대비) ──
    learned = []
    for p in plist:
        j = p["c"]
        s0 = (p["s"] - start).days
        if s0 <= 0:
            continue
        acts, bases = [], []
        for d in pd.date_range(p["s"], min(p["e"], end)):
            t = (d - start).days
            if not up[t] or np.isnan(Qv[t, j]):
                continue
            b = DOWNP[wk[t], s0 - 1, j]
            if np.isnan(b):
                continue
            acts.append(Qv[t, j])
            bases.append(b)
        if len(acts) and sum(bases) > 0:
            p["actual"] = sum(acts) / sum(bases)
            p["actual_days"] = len(acts)
            learned.append(p)
    # 행사 배수 힌트: 직접 입력 > 같은 상품 지난 행사 실제 배수 평균 > 전체 평균
    by_code = {}
    for p in learned:
        by_code.setdefault(p["c"], []).append(p)
    all_up = [p["actual"] for p in learned]
    glob_up = float(np.median(all_up)) if all_up else np.nan
    P_hint = P_user.copy()
    for t in range(len(cal)):
        for j in np.where(P[t] & np.isnan(P_hint[t]))[0]:
            past = [q["actual"] for q in by_code.get(j, []) if q["e"] < cal[t]]
            P_hint[t, j] = float(np.mean(past)) if past else glob_up

    ctx = dict(start=start, end=end, cal=cal, T_end=T_end, codes=codes, names=names, Qv=Qv, up=up, wk=wk,
               P=P, P_idx=P_idx, P_len=P_len, P_disc=P_disc, P_kind=P_kind, P_hint=P_hint,
               DOW=DOW, DOWNP=DOWNP, M14=M14, M28=M28, NP28=NP28, S28=S28, LAST=LAST, PF28=PF28,
               is_hol=is_hol, to_hol=to_hol, since_hol=since_hol, to_major=to_major, since_major=since_major, first=first, dow_seen=dow_seen,
               plist=plist, learned=learned)
    return ctx


FEATS = ["code", "h", "dow", "dom", "month", "log_scale", "dow_r", "downp_r", "m14_r", "np28_r",
         "std_r", "last_r", "pf28", "promo", "promo_idx", "promo_len", "promo_disc", "promo_kind",
         "promo_hint", "is_hol", "to_hol", "since_hol", "to_major", "since_major", "age"]
# 학습에서 빼는 특징 — 상품코드·날짜(일/월)는 데이터가 몇 달뿐이라 "그날 그 상품"을 외워버림(과적합)
DROP = [f for f in os.environ.get("FC_DROP", "code,dom,month").split(",") if f]
USE = [f for f in FEATS if f not in DROP]
_USE_IDX = [FEATS.index(f) for f in USE]


def samples(ctx, origins, hs, train=True):
    """origins: [(위치, 상품번호)] → 특징 행렬 X, 정답 y, 스케일, 기존 방식 값, 개선 기준값, (origin, target, 상품)

    기존 방식(base) = 최근 8주 같은 요일 평균 (지금 🤖 자동 생성이 쓰는 값, 행사일도 섞여 있음)
    개선 기준(clean) = 행사일을 뺀 같은 요일 평균 × (행사일이면 행사 배수)
    스케일 = 행사일 뺀 최근 28일 평균 → 상품마다 크기가 달라도 한 모델로 학습
    """
    cal, Qv, up, wk = ctx["cal"], ctx["Qv"], ctx["up"], ctx["wk"]
    first_pos = {j: (ctx["first"][c] - ctx["start"]).days for j, c in enumerate(ctx["codes"])}
    rows, ys, scales, bases, cleans, meta = [], [], [], [], [], []
    for (o, j) in origins:
        scale = ctx["NP28"][o, j]
        if np.isnan(scale):
            scale = ctx["M28"][o, j]
        if np.isnan(scale):
            continue
        scale = max(scale, 0.3)
        age = o - first_pos[j]
        for h in hs:
            t = o + h
            if t >= len(cal):
                continue
            if train and (t > ctx["T_end"] or not up[t] or np.isnan(Qv[t, j])):
                continue
            d = wk[t]
            dw = ctx["DOW"][d, o, j]
            dnp = ctx["DOWNP"][d, o, j]
            base = 0.0 if np.isnan(dw) else dw
            clean = dnp if not np.isnan(dnp) else base
            promo = bool(ctx["P"][t, j])
            hint = ctx["P_hint"][t, j]
            if promo and not np.isnan(hint):
                clean = clean * hint
            rows.append([j, h, d, cal[t].day, cal[t].month, np.log1p(scale),
                         dw / scale, dnp / scale, ctx["M14"][o, j] / scale, ctx["NP28"][o, j] / scale,
                         ctx["S28"][o, j] / scale, ctx["LAST"][o, j] / scale, ctx["PF28"][o, j],
                         float(promo), ctx["P_idx"][t, j], ctx["P_len"][t, j], ctx["P_disc"][t, j],
                         ctx["P_kind"][t, j], hint,
                         ctx["is_hol"][t], ctx["to_hol"][t], ctx["since_hol"][t],
                         ctx["to_major"][t], ctx["since_major"][t], min(age, 365)])
            ys.append(Qv[t, j] if train else np.nan)
            scales.append(scale)
            bases.append(base)
            cleans.append(clean)
            meta.append((o, t, j))
    X = np.array(rows, float) if rows else np.zeros((0, len(FEATS)))
    X = X[:, _USE_IDX]
    return X, np.array(ys, float), np.array(scales, float), np.array(bases, float), np.array(cleans, float), meta


def fit(X, y, scale, alpha=None):
    params = dict(learning_rate=0.03, num_leaves=15, min_data_in_leaf=50, bagging_fraction=0.8,
                  bagging_freq=1, feature_fraction=0.8, lambda_l2=1.0, verbose=-1, seed=7)
    rounds = 500
    if alpha is None:
        params["objective"] = "regression"
    else:
        params.update(objective="quantile", alpha=alpha)
        rounds = 300
    ds = lgb.Dataset(X, label=y / scale, weight=scale, feature_name=USE,
                     categorical_feature=[0] if USE[0] == "code" else [], free_raw_data=False)
    return lgb.train(params, ds, num_boost_round=rounds)


def wape(pred, act):
    """오차율 = Σ|예측−실제| ÷ Σ실제 (낮을수록 좋음)"""
    s = float(np.sum(act))
    return round(float(np.sum(np.abs(pred - act)) / s), 4) if s > 0 else None


def predict_ml(models, X, scale, clean, promo, promo_ok):
    q = np.maximum(models[0].predict(X) * scale, 0)
    lo = np.maximum(models[1].predict(X) * scale, 0)
    hi = np.maximum(models[2].predict(X) * scale, 0)
    if not promo_ok:  # 행사 학습 데이터가 적으면 행사일은 개선 기준(평소 × 배수) 사용
        q = np.where(promo, clean, q)
        hi = np.where(promo, np.maximum(hi, clean * 1.3), hi)
        lo = np.where(promo, np.minimum(lo, clean * 0.7), lo)
    return q, np.minimum(lo, q), np.maximum(hi, q)


# ── 딥러닝 (Chronos-Bolt) ─────────────────────────────
# 수많은 시계열로 미리 학습된 모델이라 몇 달치 데이터로도 쓸 수 있음.
# 매출 숫자 흐름만 보므로 행사는 모름 → 지난 행사일은 비워서 넣고, 앞으로의 행사일은 행사 배수를 곱함.
_dl_pipe = None


def load_dl():
    global _dl_pipe
    if DL_OFF or _dl_pipe is False:
        return None
    if _dl_pipe is None:
        try:
            import torch
            from chronos import BaseChronosPipeline
            torch.set_num_threads(max(1, os.cpu_count() or 1))
            _dl_pipe = BaseChronosPipeline.from_pretrained(DL_MODEL, device_map="cpu", torch_dtype=torch.float32)
            log(f"딥러닝 모델 준비: {DL_MODEL}")
        except Exception as e:
            log("딥러닝(Chronos) 사용 안 함:", e)
            _dl_pipe = False
            return None
    return _dl_pipe


def dl_forecast(ctx, origins, H):
    """[(위치, 상품번호)] → {(o, j): (중간[H], 적게[H], 많이[H])} — 행사 없는 '평소' 예측 (o 다음날부터)"""
    pipe = load_dl()
    if pipe is None:
        return {}
    import torch
    first_pos = {j: (ctx["first"][c] - ctx["start"]).days for j, c in enumerate(ctx["codes"])}
    keys, seqs = [], []
    for (o, j) in origins:
        fp = max(0, first_pos[j])
        seq = ctx["Qv"][fp:o + 1, j].copy()       # 업로드 안 된 날 = NaN (모델이 빈칸으로 처리)
        seq[ctx["P"][fp:o + 1, j]] = np.nan       # 지난 행사일도 빈칸 → 평소 수준만 보게
        if np.isfinite(seq).sum() < MIN_AGE // 2:
            continue
        keys.append((o, j))
        seqs.append(torch.tensor(seq, dtype=torch.float32))
    out = {}
    for b in range(0, len(seqs), DL_BATCH):
        qs, _ = pipe.predict_quantiles(seqs[b:b + DL_BATCH], prediction_length=H,
                                       quantile_levels=[0.15, 0.5, 0.85])
        qs = np.maximum(qs.detach().cpu().numpy().astype(float), 0)
        for k, key in enumerate(keys[b:b + DL_BATCH]):
            out[key] = (qs[k, :, 1], qs[k, :, 0], qs[k, :, 2])
    return out


def dl_value(ctx, fc, o, t, j):
    """fc 예측에서 (o → t) 값을 꺼내 행사일이면 배수를 곱함. 없으면 None"""
    f = fc.get((o, j))
    if f is None:
        return None
    h = t - o
    q, lo, hi = f[0][h - 1], f[1][h - 1], f[2][h - 1]
    hint = ctx["P_hint"][t, j]
    if ctx["P"][t, j] and not np.isnan(hint):
        q, lo, hi = q * hint, lo * hint, hi * hint
    return q, min(lo, q), max(hi, q)


def run(ctx):
    T_end, codes, up = ctx["T_end"], ctx["codes"], ctx["up"]
    n_days = int(up[:T_end + 1].sum())
    active = [j for j, c in enumerate(codes)
              if np.nansum(ctx["Qv"][max(0, T_end - ACTIVE_DAYS + 1):T_end + 1, j]) > 0]
    first_pos = {j: (ctx["first"][c] - ctx["start"]).days for j, c in enumerate(codes)}
    up_pos = np.where(up[:T_end + 1])[0]
    metrics = {"n_days": n_days, "learned_promos": len(ctx["learned"]), "promos": len(ctx["plist"])}
    status, message = "ok", ""
    enough = n_days >= MIN_DAYS
    use_ml = lgb is not None and enough
    PI = USE.index("promo")

    choice = {j: "base" for j in active}
    models = None
    promo_ok = False
    has_dl = False
    if enough:
        all_origins = [(o, j) for j in active for o in up_pos if o - first_pos[j] >= MIN_AGE]
        hs = range(1, HORIZON + 1)
        cutoff = T_end - EVAL_DAYS
        # ── 정확도 비교: cutoff 이전 데이터로만 → 이후 4주를 맞혀봄 ──
        te = [(o, j) for (o, j) in all_origins if cutoff <= o < T_end]
        Xb, yb, sb, bb, cb, mb = samples(ctx, te, range(1, EVAL_H + 1))
        pred = lo = hi = None
        if len(Xb) > 50:
            isp = Xb[:, PI] > 0
            if use_ml:
                tr = [(o, j) for (o, j) in all_origins if o + 1 <= cutoff]
                Xa, ya, sa, _, _, ma = samples(ctx, tr, hs)
                keep = np.array([t <= cutoff for (_, t, _) in ma], bool)
                Xa, ya, sa = Xa[keep], ya[keep], sa[keep]
                if len(Xa) > 500:
                    ok_eval = int(np.sum(Xa[:, PI] > 0)) >= PROMO_MIN_SAMPLES
                    ms = (fit(Xa, ya, sa), fit(Xa, ya, sa, 0.15), fit(Xa, ya, sa, 0.85))
                    pred, lo, hi = predict_ml(ms, Xb, sb, cb, isp, ok_eval)
            # 딥러닝: 같은 시점·같은 상품을 맞혀봄 (각 시점까지의 매출만 넣음 — 미래는 안 봄)
            dfc = dl_forecast(ctx, sorted({(o, j) for (o, _, j) in mb}), EVAL_H)
            dpred = dlo = dhi = None
            if dfc:
                has_dl = True
                dv = [dl_value(ctx, dfc, o, t, j) for (o, t, j) in mb]
                dpred = np.array([v[0] if v else cb[i] for i, v in enumerate(dv)])
                dlo = np.array([v[1] if v else cb[i] for i, v in enumerate(dv)])
                dhi = np.array([v[2] if v else cb[i] for i, v in enumerate(dv)])
            if pred is not None or dpred is not None:
                prod = {}
                mj = np.array([j for (_, _, j) in mb])
                for j in active:
                    k = mj == j
                    if k.sum() == 0 or yb[k].sum() <= 0:
                        choice[j] = "ml" if pred is not None else "base"
                        continue
                    w = {"base": wape(cb[k], yb[k])}
                    if pred is not None:
                        w["ml"] = wape(pred[k], yb[k])
                    if dpred is not None:
                        w["dl"] = wape(dpred[k], yb[k])
                    best = "base"
                    if "ml" in w and w["ml"] <= w["base"] * 1.03:
                        best = "ml"
                    if "dl" in w and w["dl"] < w[best] * 0.97:   # 딥러닝은 확실히 나을 때만
                        best = "dl"
                    choice[j] = best
                    prod[codes[j]] = {"ml": w.get("ml"), "dl": w.get("dl"), "clean": w["base"],
                                      "base": wape(bb[k], yb[k]), "n": int(k.sum()),
                                      "actual": round(float(yb[k].sum()), 1), "model": best}
                pick = {"base": (cb, None, None), "ml": (pred, lo, hi), "dl": (dpred, dlo, dhi)}
                fin = np.array([pick[choice[mb[i][2]]][0][i] for i in range(len(yb))])
                rng = [i for i in range(len(yb)) if choice[mb[i][2]] != "base"]
                cov = None
                if rng:
                    flo = np.array([pick[choice[mb[i][2]]][1][i] for i in rng])
                    fhi = np.array([pick[choice[mb[i][2]]][2][i] for i in rng])
                    cov = round(float(np.mean((yb[rng] >= flo - 1e-9) & (yb[rng] <= fhi + 1e-9))), 3)
                elif lo is not None:
                    cov = round(float(np.mean((yb >= lo - 1e-9) & (yb <= hi + 1e-9))), 3)

                def w2(x, m=None):
                    if x is None:
                        return None
                    return wape(x, yb) if m is None else wape(x[m], yb[m])
                metrics["products"] = prod
                metrics["eval"] = {
                    "from": str(ctx["cal"][cutoff + 1].date()), "to": str(ctx["end"].date()), "horizon": EVAL_H,
                    "n": int(len(yb)), "actual": round(float(yb.sum()), 1),
                    "base": wape(bb, yb), "clean": wape(cb, yb), "ml": w2(pred), "dl": w2(dpred),
                    "final": wape(fin, yb),
                    "promo_n": int(isp.sum()),
                    "promo": {"base": wape(bb[isp], yb[isp]), "clean": wape(cb[isp], yb[isp]),
                              "ml": w2(pred, isp), "dl": w2(dpred, isp), "final": wape(fin[isp], yb[isp]),
                              "actual": round(float(yb[isp].sum()), 1)} if isp.any() else None,
                    "coverage": cov,
                }
        if pred is None:
            use_ml = False
        if not use_ml and not has_dl:
            status = "baseline_only"
            message = ("lightgbm 미설치 — 행사 반영 요일 평균으로 예측" if lgb is None
                       else "학습 데이터 부족 — 행사 반영 요일 평균으로 예측")
        elif lgb is None:
            message = "lightgbm 미설치 — 딥러닝/요일 평균만 사용"

        if use_ml:
            Xf, yf, sf, _, _, _ = samples(ctx, all_origins, hs)
            promo_ok = int(np.sum(Xf[:, PI] > 0)) >= PROMO_MIN_SAMPLES
            models = (fit(Xf, yf, sf), fit(Xf, yf, sf, 0.15), fit(Xf, yf, sf, 0.85))
            imp = models[0].feature_importance("gain")
            metrics["importance"] = {USE[i]: round(float(v) / max(imp.sum(), 1), 3)
                                     for i, v in sorted(enumerate(imp), key=lambda x: -x[1])[:10]}
            metrics["promo_train_samples"] = int(np.sum(Xf[:, PI] > 0))
        else:
            for j in active:
                if choice[j] == "ml":
                    choice[j] = "base"
    else:
        status, message = "baseline_only", f"매출 데이터 {n_days}일 — {MIN_DAYS}일 이상 쌓이면 ML·딥러닝 사용"

    # ── 최종 예측: 마지막 매출일 다음날부터 HORIZON일 ──
    out = []
    Xp, _, sp, bp, cp, mp = samples(ctx, [(T_end, j) for j in active], range(1, HORIZON + 1), train=False)
    if models is not None and len(Xp):
        pq, pl, ph = predict_ml(models, Xp, sp, cp, Xp[:, PI] > 0, promo_ok)
    dl_js = [j for j in active if choice.get(j) == "dl"]
    ffc = dl_forecast(ctx, [(T_end, j) for j in dl_js], HORIZON) if dl_js else {}
    used = {"ml": set(), "dl": set()}
    for i, (o, t, j) in enumerate(mp):
        std = ctx["S28"][o, j]
        std = 0.0 if np.isnan(std) else std
        promo = bool(ctx["P"][t, j])
        young = (T_end - first_pos[j]) < MIN_AGE
        dv = dl_value(ctx, ffc, o, t, j) if choice.get(j) == "dl" and not young else None
        if not ctx["dow_seen"][ctx["wk"][t]]:
            q = lo = hi = 0.0
            model = "base"
        elif models is not None and choice.get(j) == "ml" and not young:
            q, lo, hi, model = pq[i], pl[i], ph[i], "ml"
        elif dv is not None:
            (q, lo, hi), model = dv, "dl"
        else:
            q = cp[i]
            spread = std * (ctx["P_hint"][t, j] if promo and not np.isnan(ctx["P_hint"][t, j]) else 1.0)
            lo, hi, model = max(0.0, q - spread), q + spread, "base"
        if model in used:
            used[model].add(j)
        out.append({"date": str(ctx["cal"][t].date()), "code": codes[j], "name": ctx["names"].get(codes[j], "") or "",
                    "qty": round(float(q), 2), "qty_lo": round(float(lo), 2), "qty_hi": round(float(hi), 2),
                    "base": round(float(bp[i]), 2), "promo": promo, "model": model})
    metrics["ml_products"] = len(used["ml"])
    metrics["dl_products"] = len(used["dl"])
    if has_dl:
        metrics["dl_model"] = DL_MODEL
    return out, metrics, status, message, len(active), n_days


def fmt_pct(v):
    return "–" if v is None else f"{v:.1%}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv")
    ap.add_argument("--promos")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out", default="forecast_out.csv")
    a = ap.parse_args()

    if a.csv:
        sales, promos = load_from_csv(a.csv, a.promos)
    else:
        if not SUPABASE_KEY:
            log("❌ SUPABASE_KEY 환경변수가 없습니다")
            sys.exit(1)
        sales, promos = load_from_supabase()
    if sales.empty:
        log("매출 데이터 없음 — 종료")
        return
    log(f"매출 {len(sales)}행 · 상품 {sales['code'].nunique()}개 · 행사 {len(promos)}건 · "
        f"lightgbm={'O' if lgb else 'X'} 딥러닝={'X' if DL_OFF else DL_MODEL} holidays={'O' if holidays_lib else 'X'}")

    ctx = build(sales, promos)
    out, metrics, status, message, n_prod, n_days = run(ctx)
    ev = metrics.get("eval")
    if ev:
        log(f"정확도 비교 {ev['from']}~{ev['to']} (오차율, 낮을수록 좋음): 기존 {ev['base']:.1%} · 행사반영 {ev['clean']:.1%}"
            f" · ML {fmt_pct(ev['ml'])} · 딥러닝 {fmt_pct(ev['dl'])} → 최종 {ev['final']:.1%} · 범위 안 비율 {fmt_pct(ev['coverage'])} · 행사일 {ev['promo_n']}건")
        if ev.get("promo"):
            log("  행사일만:", ev["promo"])
    log(f"상태 {status} {message} · 예측 {len(out)}행 · 상품 {n_prod}개 (ML {metrics.get('ml_products', 0)}개 · 딥러닝 {metrics.get('dl_products', 0)}개)")

    if a.dry_run:
        pd.DataFrame(out).to_csv(a.out, index=False, encoding="utf-8-sig")
        log(json.dumps({k: v for k, v in metrics.items() if k != "products"}, ensure_ascii=False, indent=1, default=str))
        log("저장 →", a.out)
        return

    run_row = sb_post("aps_forecast_runs", [{
        "data_start": str(ctx["start"].date()), "data_end": str(ctx["end"].date()), "n_days": n_days,
        "n_products": n_prod, "horizon": HORIZON, "status": status, "message": message, "metrics": metrics,
    }], returning=True)
    run_id = run_row[0]["id"] if run_row else None
    for r in out:
        r["run_id"] = run_id
    sb_delete("aps_forecast", {"date": "gte.1900-01-01"})
    sb_post("aps_forecast", out)
    for p in ctx["learned"]:
        if p.get("id") is not None:
            sb_patch("aps_promotions", {"id": f"eq.{int(p['id'])}"},
                     {"actual_uplift": round(p["actual"], 3), "actual_days": p["actual_days"]})
    # 실행 기록은 60개만 보관
    try:
        old = sb_get_all("aps_forecast_runs", {"select": "id", "order": "run_at.desc"})[60:]
        for r in old:
            sb_delete("aps_forecast_runs", {"id": f"eq.{r['id']}"})
    except Exception as e:
        log("⚠ 오래된 실행 기록 정리 실패:", e)
    log("✓ Supabase 저장 완료 (run_id", run_id, ")")


if __name__ == "__main__":
    main()
