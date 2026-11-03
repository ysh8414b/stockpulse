"""급등 종목 AI — 매일 장 마감 후 실행 (GitHub Actions surge.yml)

1. 오늘 +5% 이상 & 거래대금 3,000억 이상 종목 → 거래대금 상위 10개
2. 상승 원인 분석
   - 시황: 지수, 같은 섹터·테마 동반 상승, 공시(DART), 뉴스, 투자자 수급
   - 차트: 신고가·박스권 돌파, 거래량 급증, 갭 상승, 장대양봉, 윗꼬리, 낙폭 반등 등
3. 딥러닝 예측 (CNN + GRU)
   - 학습 데이터: 시총 3,000억+ 종목의 약 3년 일봉에서 찾은 과거 급등일
     (+5% 이상 & 거래대금 1,000억 이상 — 오늘 기준보다 넓혀 표본을 늘림)
   - 입력: 급등일까지 60일 차트(수익률·고저·갭·거래량·이평 이격·지수) + 그날 상황 18개 지표
   - 출력: D+1 / D+5 / D+20 상승 확률 + 수익률 10·50·90% 범위
   - 마지막 20% 기간은 학습에 쓰지 않고 시험 → 단순 모델(로지스틱)·기본 확률과 비교해 성적 기록
   - 모델이 배운 특징 공간에서 가장 비슷한 과거 급등 사례 + 그 이후 수익률
4. 지난 선정 종목의 실제 D+1/5/20 수익률 채우기 (성과 추적)
5. Groq로 원인 해설 (주어진 숫자만 사용)
6. Supabase surge_stocks / surge_model_runs 저장

로컬 시험:
    python surge_ai.py --dry-run --universe 150 --skip-groq
    (--dry-run: Supabase에 쓰지 않고 결과만 출력. SUPABASE_KEY 없으면 anon 키로 읽기만)
"""

import os
import re
import sys
import json
import math
import time
import pickle
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1tbXBxbXZ3cHV4cXl4bHh5dHNoIiwicm9sZSI6ImFub24i"
    "LCJpYXQiOjE3NzE3NTI5ODQsImV4cCI6MjA4NzMyODk4NH0."
    "KsXLXL6g-WeodZ-wYOCJnZBkUWMZ-F06Tq4XBUQsKaA"
)
HAS_SERVICE_KEY = bool(os.environ.get("SUPABASE_KEY"))
if not HAS_SERVICE_KEY:
    os.environ["SUPABASE_KEY"] = ANON_KEY

import numpy as np  # noqa: E402
import requests  # noqa: E402
import crawl  # noqa: E402

log = crawl.log
KST = timezone(timedelta(hours=9))
TODAY = crawl.TODAY
TODAY_INT = int(TODAY.replace("-", ""))

# ── 선정 기준 ──
PICK_MIN_CHANGE = 5.0            # %
PICK_MIN_TV = 3000 * 10**8       # 거래대금 3,000억
PICK_TOP = 10
UNIVERSE_MIN_CAP = 3000 * 10**8  # 학습 종목: 시총 3,000억+

# ── 학습 이벤트 기준 (표본을 늘리려고 거래대금 기준만 낮춤) ──
EV_MIN_RET = 0.05
EV_MIN_TV = 1000 * 10**8
EV_MAX_RET = 0.31                # 30% 넘는 값은 액면분할·데이터 오류로 보고 제외
HORIZONS = (1, 5, 20)
SEQ_LEN = 60
HIST_COUNT = 800                 # 일봉 약 3년
MIN_HIST = 90                    # 급등일 이전 최소 90거래일 필요

CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "surge_cache")
PRICE_CACHE = os.path.join(CACHE_DIR, "prices.pkl")
CHART_URL = "https://fchart.stock.naver.com/sise.nhn"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
ITEM_RE = re.compile(r'data="(\d{8})\|([\d.]+)\|([\d.]+)\|([\d.]+)\|([\d.]+)\|(\d+)"')


# ═════════════════════════════════════════
# 1. 일봉 데이터 (네이버 차트)
# ═════════════════════════════════════════
def fetch_chart(symbol, count):
    """[[yyyymmdd, 시, 고, 저, 종, 거래량], ...] (날짜 오름차순)"""
    for attempt in range(3):
        try:
            r = requests.get(CHART_URL, params={"symbol": symbol, "timeframe": "day",
                                                "count": count, "requestType": 0},
                             headers=UA, timeout=10)
            if r.status_code != 200:
                time.sleep(1 + attempt)
                continue
            rows = []
            for m in ITEM_RE.finditer(r.text):
                d, o, h, l, c, v = m.groups()
                c = float(c)
                if c <= 0:
                    continue
                o, h, l = float(o), float(h), float(l)
                if o <= 0 or h <= 0 or l <= 0:   # 거래정지일 등 → 종가로 채움
                    o = h = l = c
                rows.append([int(d), o, max(h, o, c), min(l, o, c), c, float(v)])
            return np.array(rows, dtype=np.float64) if rows else None
        except Exception:
            time.sleep(1 + attempt)
    return None


def load_cache():
    try:
        with open(PRICE_CACHE, "rb") as f:
            return pickle.load(f)
    except Exception:
        return {}


def save_cache(cache):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = PRICE_CACHE + ".tmp"
    with open(tmp, "wb") as f:
        pickle.dump(cache, f)
    os.replace(tmp, PRICE_CACHE)


def _merge(old, new):
    if old is None or len(old) == 0:
        return new
    if new is None or len(new) == 0:
        return old
    keep = old[old[:, 0] < new[0, 0]]
    out = np.vstack([keep, new])
    return out[-HIST_COUNT:]


def update_prices(cache, symbols):
    """캐시에 없거나 오래된 종목은 800일, 나머지는 최근 30일만 받아 합침"""
    stale_cut = int((datetime.now(KST) - timedelta(days=45)).strftime("%Y%m%d"))
    jobs = []
    for s in symbols:
        arr = cache.get(s)
        full = arr is None or len(arr) < 30 or arr[-1, 0] < stale_cut
        jobs.append((s, HIST_COUNT if full else 30, full))

    def work(job):
        s, cnt, full = job
        return s, full, fetch_chart(s, cnt)

    n_full = sum(1 for j in jobs if j[2])
    log(f"  📈 일봉 갱신: {len(jobs)}종목 (전체 {n_full} / 최근분 {len(jobs) - n_full})")
    ok = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        for s, full, arr in ex.map(work, jobs):
            if arr is None:
                continue
            cache[s] = arr[-HIST_COUNT:] if full else _merge(cache.get(s), arr)
            ok += 1
    log(f"  ✅ 일봉 {ok}/{len(jobs)}종목 갱신")
    return cache


# ═════════════════════════════════════════
# 2. 특징 만들기
# ═════════════════════════════════════════
def _ma(x, n):
    c = np.cumsum(np.insert(x, 0, 0.0))
    out = np.full(len(x), np.nan)
    out[n - 1:] = (c[n:] - c[:-n]) / n
    return out


class IndexSeries:
    """지수 일봉 → 날짜별 수익률·5일 수익률"""

    def __init__(self, arr):
        self.ret, self.ret5 = {}, {}
        if arr is None or len(arr) < 7:
            return
        c = arr[:, 4]
        for i in range(1, len(arr)):
            self.ret[int(arr[i, 0])] = c[i] / c[i - 1] - 1
            if i >= 5:
                self.ret5[int(arr[i, 0])] = c[i] / c[i - 5] - 1

    def r(self, d):
        return self.ret.get(int(d), 0.0)

    def r5(self, d):
        return self.ret5.get(int(d), 0.0)


N_SEQ_CH = 8
TAB_NAMES = ["등락률", "갭", "윗꼬리", "종가위치", "거래대금", "거래량배수", "직전5일", "직전20일",
             "직전60일", "52주고점거리", "60일선이격", "연속상승", "지수당일", "지수5일",
             "시장과열도", "최근급등횟수", "코스닥", "상한가"]


def make_features(arr, t, idx, heat, prior_surges, is_kosdaq):
    """arr[t] = 급등일. 반환: (seq[60,8], tab[18]) — t 이후 데이터는 절대 쓰지 않음"""
    d = arr[:, 0]; o = arr[:, 1]; h = arr[:, 2]; l = arr[:, 3]; c = arr[:, 4]; v = arr[:, 5]
    s0 = t - SEQ_LEN + 1
    ma20 = _ma(c[:t + 1], 20)
    seq = np.zeros((SEQ_LEN, N_SEQ_CH), dtype=np.float32)
    vmed = np.median(v[max(0, t - 60):t]) + 1.0
    wmax = c[s0:t + 1].max()
    for k, i in enumerate(range(s0, t + 1)):
        seq[k, 0] = np.clip(math.log(c[i] / c[i - 1]), -0.3, 0.3) * 10
        seq[k, 1] = math.log(h[i] / c[i]) * 10
        seq[k, 2] = math.log(c[i] / l[i]) * 10
        seq[k, 3] = np.clip(math.log(o[i] / c[i - 1]), -0.3, 0.3) * 10
        seq[k, 4] = np.clip(math.log((v[i] + 1) / vmed), -4, 4) / 2
        seq[k, 5] = np.clip(c[i] / ma20[i] - 1, -0.5, 0.5) * 5 if not np.isnan(ma20[i]) else 0
        seq[k, 6] = math.log(c[i] / wmax) * 5
        seq[k, 7] = np.clip(idx.r(d[i]), -0.1, 0.1) * 20
    rng = h[t] - l[t] + 1e-9
    v20 = v[t - 20:t].mean() + 1.0
    hi250 = h[max(0, t - 250):t].max()
    ma60 = c[t - 59:t + 1].mean()
    up = 0
    for i in range(t - 1, max(t - 15, 1), -1):
        if c[i] > c[i - 1]:
            up += 1
        else:
            break
    ret_t = c[t] / c[t - 1] - 1
    tab = np.array([
        ret_t * 10,
        math.log(o[t] / c[t - 1]) * 10,
        (h[t] - c[t]) / rng,
        (c[t] - l[t]) / rng,
        math.log10(max(c[t] * v[t], 1e9)) - 11,
        np.clip(math.log((v[t] + 1) / v20), -3, 6),
        (c[t - 1] / c[t - 6] - 1) * 5,
        (c[t - 1] / c[t - 21] - 1) * 3,
        (c[t - 1] / c[t - 61] - 1) * 2,
        (c[t] / hi250 - 1) * 3,
        (c[t] / ma60 - 1) * 3,
        up / 5,
        idx.r(d[t]) * 20,
        idx.r5(d[t]) * 10,
        math.log1p(heat) / 3,
        prior_surges / 3,
        1.0 if is_kosdaq else 0.0,
        1.0 if ret_t >= 0.295 else 0.0,
    ], dtype=np.float32)
    return seq, np.nan_to_num(tab)


def find_events(cache, markets, idx_map):
    """과거 급등일 전부 → 특징·정답(이후 수익률)"""
    raw = []   # (code, t, date)
    heat = {}
    for code, arr in cache.items():
        if code in ("KOSPI", "KOSDAQ") or arr is None or len(arr) < MIN_HIST + 2:
            continue
        c = arr[:, 4]; v = arr[:, 5]
        ret = np.zeros(len(c)); ret[1:] = c[1:] / c[:-1] - 1
        tv = c * v
        hits = np.where((ret >= EV_MIN_RET) & (ret <= EV_MAX_RET) & (tv >= EV_MIN_TV))[0]
        for t in hits:
            if t < MIN_HIST or v[t - 1] <= 0:
                continue
            raw.append((code, int(t), int(arr[t, 0])))
            heat[int(arr[t, 0])] = heat.get(int(arr[t, 0]), 0) + 1
    log(f"  🔎 과거 급등 이벤트 {len(raw)}건 (+{EV_MIN_RET*100:.0f}% · 거래대금 {EV_MIN_TV/1e8:,.0f}억+)")

    per_code = {}
    for code, t, d in raw:
        per_code.setdefault(code, []).append(t)
    S, T, Y, meta = [], [], [], []
    for code, t, d in raw:
        arr = cache[code]
        kosdaq = markets.get(code) == "KOSDAQ"
        idx = idx_map["KOSDAQ" if kosdaq else "KOSPI"]
        prior = sum(1 for x in per_code[code] if t - 20 <= x < t)
        seq, tab = make_features(arr, t, idx, heat.get(d, 1), prior, kosdaq)
        c = arr[:, 4]
        y = [c[t + hh] / c[t] - 1 if t + hh < len(c) else np.nan for hh in HORIZONS]
        S.append(seq); T.append(tab); Y.append(y)
        meta.append({"code": code, "date": d, "chg": round((c[t] / c[t - 1] - 1) * 100, 2)})
    if not S:
        return None
    return (np.stack(S), np.stack(T), np.array(Y, dtype=np.float32), meta, heat)


# ═════════════════════════════════════════
# 3. 딥러닝 모델
# ═════════════════════════════════════════
def _torch():
    import torch
    import torch.nn as nn
    torch.set_num_threads(max(1, (os.cpu_count() or 2)))
    return torch, nn


def build_net(n_tab):
    torch, nn = _torch()

    class SurgeNet(nn.Module):
        def __init__(self):
            super().__init__()
            self.conv = nn.Sequential(
                nn.Conv1d(N_SEQ_CH, 32, 5, padding=2), nn.GELU(),
                nn.Conv1d(32, 32, 5, padding=2), nn.GELU())
            self.gru = nn.GRU(32, 32, batch_first=True)
            self.tab = nn.Sequential(nn.Linear(n_tab, 32), nn.GELU())
            self.emb = nn.Sequential(nn.Dropout(0.2), nn.Linear(64, 32), nn.GELU())
            self.cls = nn.Linear(32, len(HORIZONS))
            self.qnt = nn.Linear(32, len(HORIZONS) * 3)

        def embed(self, x, z):
            a = self.conv(x.transpose(1, 2)).transpose(1, 2)
            _, hn = self.gru(a)
            return self.emb(torch.cat([hn[-1], self.tab(z)], 1))

        def forward(self, x, z):
            e = self.embed(x, z)
            q = torch.sort(self.qnt(e).view(-1, len(HORIZONS), 3), dim=2).values
            return self.cls(e), q, e

    return SurgeNet()


QS = (0.1, 0.5, 0.9)


def _loss(logit, q, y, torch):
    mask = ~torch.isnan(y)
    yy = torch.nan_to_num(y)
    bce = torch.nn.functional.binary_cross_entropy_with_logits(logit, (yy > 0).float(), reduction="none")
    ys = torch.clamp(yy * 10, -10, 10).unsqueeze(2)
    qs = torch.tensor(QS).view(1, 1, 3)
    diff = ys - q
    pin = torch.maximum(qs * diff, (qs - 1) * diff).mean(2)
    m = mask.float()
    return ((bce + pin) * m).sum() / m.sum().clamp(min=1)


class Scaler:
    def fit(self, S, T):
        self.sm = S.reshape(-1, S.shape[2]).mean(0); self.ss = S.reshape(-1, S.shape[2]).std(0) + 1e-6
        self.tm = T.mean(0); self.ts = T.std(0) + 1e-6
        return self

    def __call__(self, S, T):
        return ((S - self.sm) / self.ss).astype(np.float32), ((T - self.tm) / self.ts).astype(np.float32)


def train_net(S, T, Y, seed, epochs=30, val=None, patience=6):
    torch, nn = _torch()
    torch.manual_seed(seed); np.random.seed(seed)
    net = build_net(T.shape[1])
    opt = torch.optim.AdamW(net.parameters(), lr=2e-3, weight_decay=1e-4)
    Xs, Xt, Yt = torch.tensor(S), torch.tensor(T), torch.tensor(Y)
    best, best_ep, best_state, bad = 1e9, epochs, None, 0
    n = len(Xs)
    for ep in range(1, epochs + 1):
        net.train()
        perm = torch.randperm(n)
        for i in range(0, n, 512):
            b = perm[i:i + 512]
            logit, q, _ = net(Xs[b], Xt[b])
            loss = _loss(logit, q, Yt[b], torch)
            opt.zero_grad(); loss.backward(); opt.step()
        if val is not None:
            net.eval()
            with torch.no_grad():
                lg, qq, _ = net(torch.tensor(val[0]), torch.tensor(val[1]))
                vl = _loss(lg, qq, torch.tensor(val[2]), torch).item()
            if vl < best - 1e-4:
                best, best_ep, bad = vl, ep, 0
                best_state = {k: v.clone() for k, v in net.state_dict().items()}
            else:
                bad += 1
                if bad >= patience:
                    break
    if best_state is not None:
        net.load_state_dict(best_state)
    net.eval()
    return net, best_ep


def predict(nets, S, T):
    torch, _ = _torch()
    ps, qs, es = [], [], []
    with torch.no_grad():
        for net in nets:
            lg, q, e = net(torch.tensor(S), torch.tensor(T))
            ps.append(torch.sigmoid(lg).numpy()); qs.append(q.numpy() / 10); es.append(e.numpy())
    return np.mean(ps, 0), np.mean(qs, 0), es[0]


def train_logistic(T, Y, Tte):
    """비교용 단순 모델: 그날 상황 18개 지표만 쓰는 로지스틱 회귀 (기간별)"""
    torch, nn = _torch()
    out = np.zeros((len(Tte), len(HORIZONS)), dtype=np.float32)
    for k in range(len(HORIZONS)):
        m = ~np.isnan(Y[:, k])
        if m.sum() < 50:
            out[:, k] = 0.5
            continue
        torch.manual_seed(0)
        lin = nn.Linear(T.shape[1], 1)
        opt = torch.optim.Adam(lin.parameters(), lr=0.05, weight_decay=1e-3)
        x = torch.tensor(T[m]); y = torch.tensor((Y[m, k] > 0).astype(np.float32)).unsqueeze(1)
        for _ in range(300):
            loss = torch.nn.functional.binary_cross_entropy_with_logits(lin(x), y)
            opt.zero_grad(); loss.backward(); opt.step()
        with torch.no_grad():
            out[:, k] = torch.sigmoid(lin(torch.tensor(Tte))).numpy()[:, 0]
    return out


def auc(y, p):
    y = np.asarray(y).astype(bool); p = np.asarray(p, dtype=np.float64)
    n1 = int(y.sum()); n0 = len(y) - n1
    if n1 == 0 or n0 == 0:
        return None
    order = p.argsort(kind="mergesort")
    ranks = np.empty(len(p)); ranks[order] = np.arange(1, len(p) + 1)
    # 같은 값은 평균 순위
    _, inv, cnt = np.unique(p, return_inverse=True, return_counts=True)
    sums = np.bincount(inv, weights=ranks)
    ranks = (sums / cnt)[inv]
    return float((ranks[y].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))


def evaluate_and_train(ev, seeds=3):
    """시간 순서대로 나눠 시험 → 성적 기록 → 전체 데이터로 최종 모델 학습"""
    S, T, Y, meta, _ = ev
    dates = np.array([m["date"] for m in meta])
    has_lbl = ~np.isnan(Y[:, 0])
    ud = np.unique(dates[has_lbl])
    metrics = {"n_events": int(len(meta)), "n_labeled": int(has_lbl.sum())}
    if len(ud) < 120 or has_lbl.sum() < 400:
        log("  ⚠️ 학습 이벤트가 너무 적음 — 시험 생략")
        metrics["note"] = "학습 데이터 부족"
        test_ok = False
    else:
        test_ok = True
    best_ep = 20
    if test_ok:
        n_test_d = max(40, int(len(ud) * 0.2))
        test_start = ud[-n_test_d]
        # 학습 끝과 시험 시작 사이 20거래일 비움 (D+20 정답이 시험 기간과 겹치지 않게)
        gap_start = ud[max(0, len(ud) - n_test_d - 20)]
        tr = has_lbl & (dates < gap_start)
        te = has_lbl & (dates >= test_start)
        trd = np.unique(dates[tr])
        val_start = trd[-max(20, int(len(trd) * 0.15))]
        va = tr & (dates >= val_start)
        tr2 = tr & (dates < val_start)
        sc = Scaler().fit(S[tr2], T[tr2])
        a, b = sc(S[tr2], T[tr2]); va_s, va_t = sc(S[va], T[va]); te_s, te_t = sc(S[te], T[te])
        nets, eps = [], []
        for sd in range(seeds):
            net, ep = train_net(a, b, Y[tr2], seed=sd, val=(va_s, va_t, Y[va]))
            nets.append(net); eps.append(ep)
        best_ep = int(np.median(eps))
        p, q, _ = predict(nets, te_s, te_t)
        p_lin = train_logistic(b, Y[tr2], te_t)
        Yte = Y[te]
        hz = {}
        for k, hh in enumerate(HORIZONS):
            m = ~np.isnan(Yte[:, k])
            if m.sum() < 30:
                continue
            yk = Yte[m, k]; pk = p[m, k]; up = yk > 0
            base = float(np.nanmean(Y[tr2][:, k] > 0))
            brier = float(np.mean((pk - up) ** 2)); brier_b = float(np.mean((base - up) ** 2))
            hi = pk >= np.quantile(pk, 0.8); lo = pk <= np.quantile(pk, 0.2)
            cover = float(np.mean((yk >= q[m, k, 0]) & (yk <= q[m, k, 2])))
            hz[f"d{hh}"] = {
                "n": int(m.sum()),
                "auc": round(auc(up, pk) or 0.5, 4),
                "auc_lin": round(auc(up, p_lin[m, k]) or 0.5, 4),
                "base_rate": round(base, 4),
                "test_up_rate": round(float(up.mean()), 4),
                "brier_skill": round(1 - brier / brier_b, 4) if brier_b > 0 else 0,
                "hit": round(float(np.mean((pk >= 0.5) == up)), 4),
                "top_ret": round(float(yk[hi].mean() * 100), 2),
                "bottom_ret": round(float(yk[lo].mean() * 100), 2),
                "avg_ret": round(float(yk.mean() * 100), 2),
                "coverage": round(cover, 4),
            }
        metrics.update({
            "n_train": int(tr2.sum()), "n_val": int(va.sum()), "n_test": int(te.sum()),
            "train_period": [str(int(dates[tr2].min())), str(int(dates[tr2].max()))],
            "test_period": [str(int(test_start)), str(int(dates[te].max()))],
            "horizons": hz, "epochs": best_ep,
        })
        for k, vv in hz.items():
            log(f"  🧪 {k}: AUC 딥러닝 {vv['auc']:.3f} / 단순모델 {vv['auc_lin']:.3f} · "
                f"상위20% 평균 {vv['top_ret']:+.2f}% vs 하위20% {vv['bottom_ret']:+.2f}% · n={vv['n']}")

    # 최종 모델: 정답 있는 이벤트 전부로 학습
    sc = Scaler().fit(S[has_lbl], T[has_lbl])
    a, b = sc(S[has_lbl], T[has_lbl])
    final = []
    for sd in range(seeds):
        net, _ = train_net(a, b, Y[has_lbl], seed=100 + sd, epochs=max(6, int(best_ep * 1.1)))
        final.append(net)
    # 유사 사례 검색용 임베딩
    _, _, emb = predict(final, a, b)
    lbl_meta = [m for m, ok in zip(meta, has_lbl) if ok]
    return final, sc, metrics, (emb, Y[has_lbl], lbl_meta)


# ═════════════════════════════════════════
# 4. 상승 원인 분석
# ═════════════════════════════════════════
def chart_signals(arr):
    """오늘(마지막 봉) 차트 신호 [(kind, label, detail, weight)]"""
    t = len(arr) - 1
    o, h, l, c, v = arr[t, 1], arr[t, 2], arr[t, 3], arr[t, 4], arr[t, 5]
    C = arr[:, 4]; H = arr[:, 2]; V = arr[:, 5]
    pc = C[t - 1]
    out = []
    if t >= 500 and C[t] >= H[:t].max():
        out.append(("high", f"{t // 250}년 신고가 돌파",
                    f"과거 {t}거래일 최고가 {H[:t].max():,.0f} 위 마감", 0.55))
    elif t >= 30 and C[t] >= H[max(0, t - 250):t].max():
        out.append(("high", "52주 신고가 돌파", f"직전 52주 고가 {H[max(0, t-250):t].max():,.0f} 위 마감", 0.5))
    elif t >= 21 and C[t] > H[t - 20:t].max():
        box = (H[t - 20:t].max() / arr[t - 20:t, 3].min() - 1) * 100
        out.append(("box", "20일 박스권 돌파", f"직전 20일 고가 {H[t-20:t].max():,.0f} 돌파 (박스 폭 {box:.0f}%)", 0.4))
    v20 = V[t - 20:t].mean()
    if v20 > 0 and v / v20 >= 3:
        out.append(("volume", "거래량 급증", f"20일 평균의 {v / v20:.1f}배", 0.3))
    if o >= pc * 1.03:
        out.append(("gap", "갭 상승 출발", f"시가 {(o / pc - 1) * 100:+.1f}%", 0.25))
    rng = h - l
    if rng > 0 and (c - o) / rng >= 0.7 and (c / pc - 1) >= 0.05:
        out.append(("candle", "장대양봉", f"몸통이 하루 범위의 {(c - o) / rng * 100:.0f}%", 0.2))
    if rng > 0 and (h - c) / rng >= 0.4:
        out.append(("wick", "긴 윗꼬리 (경계)", f"고가 대비 {(c / h - 1) * 100:.1f}% 밀려 마감", 0.1))
    if t >= 60:
        ma5, ma20, ma60 = C[t - 4:t + 1].mean(), C[t - 19:t + 1].mean(), C[t - 59:t + 1].mean()
        pma20 = C[t - 20:t].mean()
        if pc / pma20 - 1 <= -0.12:
            out.append(("rebound", "낙폭 과대 반등", f"전일 20일선 대비 {(pc / pma20 - 1) * 100:.1f}%", 0.35))
        if pc < C[t - 60:t].mean() <= c:
            out.append(("ma", "60일선 회복", f"60일선 {ma60:,.0f}", 0.2))
        if ma5 > ma20 > ma60:
            out.append(("align", "이평선 정배열", "5일 > 20일 > 60일", 0.15))
    up = 0
    for i in range(t, 1, -1):
        if C[i] > C[i - 1]:
            up += 1
        else:
            break
    if up >= 3:
        out.append(("streak", f"{up}일 연속 상승", "단기 과열 주의", 0.1))
    if c / pc - 1 >= 0.295:
        out.append(("limit", "상한가", "", 0.3))
    return out


def classify_news(titles):
    for t in titles:
        for kws, label, *_ in crawl.NEWS_MATERIAL_KEYWORDS:
            if any(k in t for k in kws):
                return label, t
    return None, None


def load_theme_rows(codes):
    """theme_stocks_all(크롤러가 매 실행 저장) → {code: [테마명]}, {테마명: [종목코드]}"""
    stock_themes, members = {}, {}
    try:
        q = ",".join(codes)
        rows = crawl.supabase_request("GET", "theme_stocks_all",
                                      params={"select": "theme_name,code", "code": f"in.({q})"}) or []
        names = sorted({r["theme_name"] for r in rows})
        for r in rows:
            stock_themes.setdefault(r["code"], []).append(r["theme_name"])
        for i in range(0, len(names), 20):
            part = ",".join('"' + n.replace('"', '') + '"' for n in names[i:i + 20])
            mrows = crawl.supabase_request("GET", "theme_stocks_all",
                                           params={"select": "theme_name,code", "theme_name": f"in.({part})",
                                                   "limit": "5000"}) or []
            for r in mrows:
                members.setdefault(r["theme_name"], set()).add(r["code"])
    except Exception as e:
        log(f"  ⚠️ 테마 데이터 조회 실패: {e}")
    return stock_themes, members


def analyze_causes(stock, arr, krx, idx_today, stock_themes, members, disclosures, news, flow):
    causes = []
    code = stock["code"]
    chg = stock["change_pct"]
    # ── 시황: 지수 ──
    mk = stock.get("market", "KOSPI")
    ir = idx_today.get(mk, 0.0)
    if ir >= 1.5:
        causes.append({"group": "시황", "kind": "market", "label": f"{'코스닥' if mk == 'KOSDAQ' else '코스피'} 강세",
                       "detail": f"지수 {ir:+.2f}% — 시장 전반이 함께 오름", "weight": round(min(0.8, ir / 4), 2)})
    elif ir <= -1.0:
        causes.append({"group": "시황", "kind": "against", "label": "약세장 역행",
                       "detail": f"지수 {ir:+.2f}%에도 {chg:+.1f}% — 개별 요인 가능성 높음", "weight": 0.15})
    # ── 시황: 섹터 ──
    sec = stock.get("display_sector") or ""
    sec_info = None
    if sec:
        peers = [d for d in krx.values() if d.get("display_sector") == sec and d["code"] != code
                 and d.get("market_cap", 0) >= UNIVERSE_MIN_CAP]
        if len(peers) >= 3:
            avg = sum(p["change_pct"] for p in peers) / len(peers)
            up3 = sum(1 for p in peers if p["change_pct"] >= 3)
            sec_info = {"name": sec, "avg_pct": round(avg, 2), "up3": up3, "count": len(peers)}
            if avg >= 2:
                causes.append({"group": "시황", "kind": "sector", "label": f"{sec} 섹터 동반 상승",
                               "detail": f"섹터 평균 {avg:+.2f}% · +3% 이상 {up3}/{len(peers)}종목",
                               "weight": round(min(0.8, avg / 5), 2)})
    # ── 시황: 테마 ──
    th = []
    for tn in stock_themes.get(code, []):
        mem = [m for m in members.get(tn, ()) if m != code and m in krx]
        if len(mem) < 2:
            continue
        chs = [krx[m]["change_pct"] for m in mem]
        th.append({"name": tn, "avg_pct": round(sum(chs) / len(chs), 2),
                   "up5": sum(1 for x in chs if x >= 5), "count": len(mem)})
    th.sort(key=lambda x: (x["up5"], x["avg_pct"]), reverse=True)
    if th and (th[0]["up5"] >= 2 or th[0]["avg_pct"] >= 3):
        b = th[0]
        causes.append({"group": "시황", "kind": "theme", "label": f"{b['name']} 테마 동반 상승",
                       "detail": f"테마 평균 {b['avg_pct']:+.2f}% · +5% 이상 {b['up5']}/{b['count']}종목",
                       "weight": round(min(1.0, b["avg_pct"] / 6 + b["up5"] * 0.1), 2)})
    # ── 시황: 공시 ──
    for dsc in (disclosures or [])[:3]:
        if dsc.get("days_ago", 9) <= 1:
            causes.append({"group": "시황", "kind": "disclosure", "label": f"공시: {dsc.get('type', '')}",
                           "detail": dsc.get("title", ""), "weight": 0.9})
            break
    # ── 시황: 뉴스 ──
    titles = [n["title"] for n in news]
    nlabel, ntitle = classify_news(titles)
    if nlabel:
        causes.append({"group": "시황", "kind": "news", "label": f"뉴스: {nlabel}", "detail": ntitle, "weight": 0.6})
    elif titles:
        plain = [t for t in titles if not any(p in t for p in crawl.NEWS_REACTION_PATTERNS)]
        if plain:
            causes.append({"group": "시황", "kind": "news", "label": "관련 뉴스", "detail": plain[0], "weight": 0.25})
    # ── 시황: 수급 ──
    if flow:
        fn, inn = flow.get("foreign_net", 0), flow.get("institution_net", 0)
        if fn >= 100 or inn >= 100:
            who = "외국인·기관" if fn >= 100 and inn >= 100 else ("외국인" if fn >= 100 else "기관")
            causes.append({"group": "시황", "kind": "flow", "label": f"{who} 순매수",
                           "detail": f"외국인 {fn:+,}억 · 기관 {inn:+,}억", "weight": 0.35})
    # ── 차트 ──
    tags = chart_signals(arr) if arr is not None and len(arr) > 70 else []
    n_bars = 0 if arr is None else len(arr)
    if n_bars < 20:
        causes.append({"group": "차트", "kind": "ipo", "label": "신규 상장 초기",
                       "detail": f"상장 {max(n_bars, 1)}거래일째 — 가격 기준점이 없어 변동성이 큼", "weight": 0.5})
    for kind, label, detail, w in tags:
        causes.append({"group": "차트", "kind": kind, "label": label, "detail": detail, "weight": w})

    causes.sort(key=lambda x: x["weight"], reverse=True)
    top = next((x for x in causes if x["kind"] not in ("wick", "streak", "against", "volume", "candle", "align", "limit")), None)
    type_map = {"disclosure": "개별 재료형", "news": "개별 재료형", "theme": "테마 동반형", "sector": "섹터 동반형",
                "market": "시장 동반형", "flow": "수급 주도형", "high": "기술적 돌파형", "box": "기술적 돌파형",
                "rebound": "낙폭 반등형", "gap": "기술적 돌파형", "ma": "기술적 돌파형", "ipo": "신규 상장형"}
    surge_type = type_map.get(top["kind"], "원인 불명확") if top else "원인 불명확"
    main = " + ".join(x["label"] for x in causes[:2]) if causes else "뚜렷한 원인 미확인"
    return causes, [x[1] for x in tags], th[:5], sec_info, surge_type, main


# ═════════════════════════════════════════
# 5. AI 해설 (Groq)
# ═════════════════════════════════════════
def groq_comments(rows):
    if not crawl.GROQ_API_KEY or not rows:
        return {}
    blocks = []
    for r in rows:
        p = r.get("pred") or {}
        ptxt = " / ".join(f"D+{k[1:]} 상승확률 {v['p_up']*100:.0f}% · 중앙값 {v['q50']:+.1f}%"
                          for k, v in p.items() if isinstance(v, dict) and "p_up" in v) or "예측 없음"
        sim = (r.get("similar_cases") or {}).get("summary") or {}
        blocks.append(
            f"[{r['name']} ({r['code']})] {r['change_pct']:+.2f}%, 거래대금 {r['trading_value']/1e8:,.0f}억, "
            f"유형 {r['surge_type']}\n"
            f"- 원인 후보: " + "; ".join(f"{c['group']}/{c['label']}({c['detail']})" for c in r["causes"][:6]) + "\n"
            f"- 모델 예측: {ptxt}\n"
            f"- 비슷한 과거 급등 {sim.get('n', 0)}건: D+5 평균 {sim.get('d5_avg', 0):+.1f}%, 상승 비율 {sim.get('d5_up', 0)*100:.0f}%"
        )
    prompt = f"""당신은 한국 주식시장 애널리스트입니다. 오늘({TODAY}) 5% 이상 오르고 거래대금 3,000억 이상인 종목들입니다.

{chr(10).join(blocks)}

[규칙]
1. 위 데이터에 적힌 숫자·사실만 쓰라. 없는 계약금액·실적·목표가·일정을 만들지 마라.
2. 원인은 시황(지수·섹터·테마·공시·뉴스·수급)과 차트(돌파·거래량 등)로 나눠 가장 유력한 것부터.
3. 모델 예측은 '확률'이라고 분명히 쓰고, 단정·매수 권유 표현 금지.
4. 종목마다 3~4문장.

JSON으로만 답하라: {{"stocks":[{{"code":"6자리","comment":"3~4문장"}}]}}"""
    try:
        r = requests.post("https://api.groq.com/openai/v1/chat/completions",
                          headers={"Authorization": f"Bearer {crawl.GROQ_API_KEY}", "Content-Type": "application/json"},
                          json={"model": crawl.GROQ_MODEL, "messages": [{"role": "user", "content": prompt}],
                                "temperature": 0.3, "max_tokens": 6000, "response_format": {"type": "json_object"}},
                          timeout=90)
        if r.status_code != 200:
            log(f"  ⚠️ Groq 오류 {r.status_code}: {r.text[:200]}")
            return {}
        data = json.loads(r.json()["choices"][0]["message"]["content"])
        return {str(s.get("code", "")).zfill(6): (s.get("comment") or "").strip() for s in data.get("stocks", [])}
    except Exception as e:
        log(f"  ⚠️ Groq 해설 실패: {e}")
        return {}


# ═════════════════════════════════════════
# 6. 성과 추적
# ═════════════════════════════════════════
def update_realized(cache, dry):
    since = (datetime.now(KST) - timedelta(days=50)).strftime("%Y-%m-%d")
    rows = crawl.supabase_request("GET", "surge_stocks", params={
        "select": "id,date,code,ret_d1,ret_d5,ret_d20", "date": f"gte.{since}", "ret_d20": "is.null",
        "limit": "1000"}) or []
    n = 0
    for r in rows:
        if r["date"] >= TODAY:
            continue
        arr = cache.get(r["code"])
        if arr is None:
            continue
        di = int(r["date"].replace("-", ""))
        pos = np.where(arr[:, 0] == di)[0]
        if not len(pos):
            continue
        i = int(pos[0]); c = arr[:, 4]
        patch = {}
        for hh in HORIZONS:
            key = f"ret_d{hh}"
            if r.get(key) is None and i + hh < len(c):
                patch[key] = round((c[i + hh] / c[i] - 1) * 100, 2)
        if patch:
            n += 1
            if not dry:
                crawl.supabase_request("PATCH", "surge_stocks", data=patch, params={"id": f"eq.{r['id']}"})
    log(f"  📊 지난 선정 종목 실제 수익률 {n}건 갱신")


# ═════════════════════════════════════════
# main
# ═════════════════════════════════════════
def main():
    global TODAY, TODAY_INT
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--universe", type=int, default=0, help="학습 종목 수 제한 (로컬 시험용)")
    ap.add_argument("--skip-groq", action="store_true")
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--out", default="", help="드라이런 결과(전체 행 + 성적)를 JSON 파일로 저장")
    ap.add_argument("--force", action="store_true", help="지수 일봉 날짜가 오늘과 달라도 실행")
    args = ap.parse_args()
    dry = args.dry_run or not HAS_SERVICE_KEY
    if dry:
        log("🧪 드라이런 — Supabase에 쓰지 않음")

    log("=" * 50)
    log(f"🚀 급등 종목 AI ({TODAY})")
    sector_map = crawl.fetch_naver_sector_map()
    krx = crawl.fetch_naver_market_data(sector_map)
    if not krx:
        log("❌ 시세 조회 실패"); return
    if not any(abs(d.get("change_pct", 0)) > 0 for d in list(krx.values())[:200]):
        log("🏖️ 휴장일 — 종료"); return

    # 오늘 급등 종목
    picks = [d for d in krx.values() if d["change_pct"] >= PICK_MIN_CHANGE and d["trading_value"] >= PICK_MIN_TV
             and not crawl.is_etf_etn(d["name"])]
    picks.sort(key=lambda d: d["trading_value"], reverse=True)
    picks = picks[:PICK_TOP]
    log(f"  🚀 오늘 급등 종목 {len(picks)}개: " + ", ".join(f"{p['name']}({p['change_pct']:+.1f}%)" for p in picks))

    # 일봉 (학습 종목 + 오늘 종목 + 지수)
    universe = [d for d in krx.values() if d.get("market_cap", 0) >= UNIVERSE_MIN_CAP and not crawl.is_etf_etn(d["name"])]
    universe.sort(key=lambda d: d["market_cap"], reverse=True)
    if args.universe:
        universe = universe[:args.universe]
    codes = sorted({d["code"] for d in universe} | {p["code"] for p in picks})
    markets = {c: krx[c]["market"] for c in codes if c in krx}
    cache = load_cache()
    cache = update_prices(cache, codes + ["KOSPI", "KOSDAQ"])
    save_cache(cache)
    # 거래일 = 코스피 차트의 마지막 날짜 (장 시작 전·휴장일엔 오늘과 다름)
    kospi = cache.get("KOSPI")
    if kospi is None:
        log("❌ 지수 차트 조회 실패"); return
    trade_int = int(kospi[-1, 0])
    if trade_int != TODAY_INT and not (args.force or dry):
        log(f"🏖️ 오늘({TODAY}) 지수 일봉 없음 — 휴장일로 보고 종료"); return
    TODAY_INT = trade_int
    TODAY = f"{str(trade_int)[:4]}-{str(trade_int)[4:6]}-{str(trade_int)[6:]}"
    log(f"  📅 기준 거래일 {TODAY}")
    idx_map = {"KOSPI": IndexSeries(cache.get("KOSPI")), "KOSDAQ": IndexSeries(cache.get("KOSDAQ"))}
    idx_today = {k: round(v.r(TODAY_INT) * 100, 2) for k, v in idx_map.items()}
    log(f"  📊 지수: 코스피 {idx_today['KOSPI']:+.2f}% · 코스닥 {idx_today['KOSDAQ']:+.2f}%")

    # 지난 선정 종목 실제 수익률
    update_realized(cache, dry)

    # 딥러닝 학습
    sub_cache = {c: cache[c] for c in codes if c in cache and c in {d["code"] for d in universe}}
    ev = find_events(sub_cache, markets, idx_map)
    model = None
    metrics = {}
    if ev is not None:
        t0 = time.time()
        nets, scaler, metrics, bank = evaluate_and_train(ev, seeds=args.seeds)
        metrics["train_seconds"] = round(time.time() - t0, 1)
        model = (nets, scaler, bank, ev[4])
        log(f"  🧠 학습 완료 ({metrics['train_seconds']}초)")
    version = f"cnn-gru-{TODAY}"
    metrics.update({"version": version, "universe": len(sub_cache), "today_count": len(picks),
                    "pick_rule": {"min_change": PICK_MIN_CHANGE, "min_tv_eok": PICK_MIN_TV // 10**8, "top": PICK_TOP},
                    "event_rule": {"min_ret": EV_MIN_RET * 100, "min_tv_eok": EV_MIN_TV // 10**8},
                    "features": {"seq_days": SEQ_LEN, "seq_channels": N_SEQ_CH, "tabular": TAB_NAMES}})

    if not picks:
        if not dry:
            crawl.supabase_request("POST", "surge_model_runs", data=[{"date": TODAY, "version": version, "metrics": metrics}])
        log("  ℹ️ 오늘 조건을 만족하는 종목 없음 — 종료")
        return

    # 원인 분석 재료
    pcodes = [p["code"] for p in picks]
    stock_themes, members = load_theme_rows(pcodes)
    try:
        dart = crawl.fetch_dart_disclosures(days_back=3)
    except Exception as e:
        log(f"  ⚠️ DART 조회 실패: {e}"); dart = {}

    gen_time = datetime.now(KST).strftime("%H:%M")
    rows = []
    for rank, p in enumerate(picks, 1):
        code = p["code"]
        arr = cache.get(code)
        if arr is not None and int(arr[-1, 0]) != TODAY_INT:
            log(f"  ⚠️ {p['name']} 오늘 일봉 없음 → 시세로 보충")
            pr = float(p["price"])
            arr = np.vstack([arr, [TODAY_INT, pr, pr, pr, pr, float(p.get("volume", 0))]])
        news = crawl.fetch_stock_news(p["name"], max_count=5)
        flow = crawl.fetch_investor_trend(code, p["price"])
        causes, ctags, th, sec_info, stype, main_cause = analyze_causes(
            p, arr, krx, idx_today, stock_themes, members, dart.get(code, []), news, flow)
        vol_ratio = 0
        if arr is not None and len(arr) > 21:
            v20 = arr[-21:-1, 5].mean()
            vol_ratio = round(arr[-1, 5] / v20, 2) if v20 > 0 else 0

        pred, similar = {}, {}
        if model and arr is not None and len(arr) > MIN_HIST:
            nets, scaler, (emb_bank, y_bank, meta_bank), heat = model
            t = len(arr) - 1
            kosdaq = p["market"] == "KOSDAQ"
            prior = 0
            c = arr[:, 4]; v = arr[:, 5]
            for i in range(t - 20, t):
                if c[i] / c[i - 1] - 1 >= EV_MIN_RET and c[i] * v[i] >= EV_MIN_TV:
                    prior += 1
            seq, tab = make_features(arr, t, idx_map["KOSDAQ" if kosdaq else "KOSPI"],
                                     max(heat.get(TODAY_INT, 0), len(picks)), prior, kosdaq)
            s_, t_ = scaler(seq[None], tab[None])
            pp, qq, ee = predict(nets, s_, t_)
            for k, hh in enumerate(HORIZONS):
                pred[f"d{hh}"] = {"p_up": round(float(pp[0, k]), 4),
                                  "q10": round(float(qq[0, k, 0]) * 100, 2),
                                  "q50": round(float(qq[0, k, 1]) * 100, 2),
                                  "q90": round(float(qq[0, k, 2]) * 100, 2)}
            # 비슷한 과거 사례 (같은 종목 최근 30일 이내는 제외)
            mu = emb_bank.mean(0); sd = emb_bank.std(0) + 1e-6
            e = (ee[0] - mu) / sd; e /= (np.linalg.norm(e) + 1e-9)
            B = (emb_bank - mu) / sd
            B /= (np.linalg.norm(B, axis=1, keepdims=True) + 1e-9)
            sims = B @ e
            order = np.argsort(-sims)
            cases = []
            for j in order:
                m = meta_bank[j]
                if m["code"] == code and m["date"] >= int((datetime.now(KST) - timedelta(days=45)).strftime("%Y%m%d")):
                    continue
                cases.append((j, float(sims[j])))
                if len(cases) >= 20:
                    break
            def agg(k):
                vals = [y_bank[j, k] for j, _ in cases if not np.isnan(y_bank[j, k])]
                return (round(float(np.mean(vals)) * 100, 2), round(float(np.mean(np.array(vals) > 0)), 3)) if vals else (0, 0)
            (a1, u1), (a5, u5), (a20, u20) = agg(0), agg(1), agg(2)
            names = {d["code"]: d["name"] for d in krx.values()}
            similar = {
                "summary": {"n": len(cases), "d1_avg": a1, "d1_up": u1, "d5_avg": a5, "d5_up": u5,
                            "d20_avg": a20, "d20_up": u20},
                "cases": [{"code": meta_bank[j]["code"], "name": names.get(meta_bank[j]["code"], meta_bank[j]["code"]),
                           "date": f"{str(meta_bank[j]['date'])[:4]}-{str(meta_bank[j]['date'])[4:6]}-{str(meta_bank[j]['date'])[6:]}",
                           "chg": meta_bank[j]["chg"], "sim": round(s, 3),
                           "d1": None if np.isnan(y_bank[j, 0]) else round(float(y_bank[j, 0]) * 100, 2),
                           "d5": None if np.isnan(y_bank[j, 1]) else round(float(y_bank[j, 1]) * 100, 2),
                           "d20": None if np.isnan(y_bank[j, 2]) else round(float(y_bank[j, 2]) * 100, 2)}
                          for j, s in cases[:6]],
            }

        ohlcv = []
        if arr is not None:
            for r_ in arr[-80:]:
                ds = str(int(r_[0]))
                ohlcv.append([f"{ds[:4]}-{ds[4:6]}-{ds[6:]}", r_[1], r_[2], r_[3], r_[4], int(r_[5])])
        rows.append({
            "date": TODAY, "rank": rank, "code": code, "name": p["name"], "market": p["market"],
            "display_sector": p.get("display_sector", ""), "price": p["price"], "change_pct": p["change_pct"],
            "trading_value": int(p["trading_value"]), "market_cap": int(p.get("market_cap", 0)),
            "vol_ratio": vol_ratio, "surge_type": stype, "main_cause": main_cause,
            "causes": causes, "chart_tags": ctags, "themes": th,
            "news": news[:5],
            "disclosures": [{"type": d.get("type", ""), "title": d.get("title", ""), "date": d.get("date", ""),
                             "url": d.get("url", "")} for d in dart.get(code, [])[:3]],
            "flow": flow or {},
            "market_ctx": {"index": idx_today, "sector": sec_info},
            "ohlcv": ohlcv, "pred": pred, "similar_cases": similar, "ai_comment": "",
            "model_version": version if pred else "", "generated_time": gen_time,
        })
        log(f"  #{rank} {p['name']} {p['change_pct']:+.2f}% · {stype} · {main_cause}"
            + (f" · D+5 상승확률 {pred['d5']['p_up']*100:.0f}%" if pred else ""))

    if not args.skip_groq:
        com = groq_comments(rows)
        for r in rows:
            r["ai_comment"] = com.get(r["code"], "")
        log(f"  🤖 AI 해설 {sum(1 for r in rows if r['ai_comment'])}/{len(rows)}종목")

    if dry and args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"metrics": metrics, "rows": rows}, f, ensure_ascii=False, default=float)
        log(f"  💾 드라이런 결과 저장: {args.out}")
    if dry:
        print(json.dumps({"metrics": metrics, "rows": [{k: v for k, v in r.items() if k != "ohlcv"} for r in rows]},
                         ensure_ascii=False, indent=1, default=float)[:20000])
        return
    crawl.supabase_request("DELETE", "surge_stocks", params={"date": f"eq.{TODAY}"})
    ok = crawl.supabase_request("POST", "surge_stocks", data=json.loads(json.dumps(rows, default=float)))
    log(f"  💾 급등 종목 {len(rows)}개 저장 {'✅' if ok else '❌'}")
    ok = crawl.supabase_request("POST", "surge_model_runs",
                                data=[{"date": TODAY, "version": version, "metrics": json.loads(json.dumps(metrics, default=float))}])
    log(f"  💾 모델 성적 저장 {'✅' if ok else '❌'}")
    # 보관: 급등 종목 1년, 모델 기록 120개
    cut = (datetime.now(KST) - timedelta(days=365)).strftime("%Y-%m-%d")
    crawl.supabase_request("DELETE", "surge_stocks", params={"date": f"lt.{cut}"})
    old = crawl.supabase_request("GET", "surge_model_runs", params={"select": "id", "order": "id.desc", "offset": "120", "limit": "500"}) or []
    for o in old:
        crawl.supabase_request("DELETE", "surge_model_runs", params={"id": f"eq.{o['id']}"})
    log("✅ 완료")


if __name__ == "__main__":
    main()
