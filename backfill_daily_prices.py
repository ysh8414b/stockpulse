"""
daily_prices 백필 스크립트 (1회 실행용)

시총 3000억+ 종목에 대해 야후 파이낸스에서 최근 30거래일 일봉을 가져와
Supabase daily_prices 테이블에 INSERT한다.

전제:
  - setup_oversold.sql 을 미리 Supabase에 적용해 daily_prices 테이블이 생성되어 있어야 함
  - crawl.py와 동일한 환경변수(SUPABASE_URL, SUPABASE_KEY) 사용

실행:
  python backfill_daily_prices.py
"""

import os
import sys
import time
import urllib.parse
from datetime import datetime, timezone, timedelta

import requests

# crawl.py 유틸 재사용 (네이버 시세 + Supabase 호출 + ETF 필터)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crawl  # noqa: E402

YAHOO_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
}

MIN_MARKET_CAP = 300_000_000_000  # 시총 3000억 원
DAYS_RANGE = 40  # 영업일 20일 확보 위해 달력 40일 ≒ 28거래일 (여유분)


def fetch_yahoo_daily(code, market):
    """야후 파이낸스 chart API에서 일봉 데이터 조회

    Returns: [{"date": "YYYY-MM-DD", "close": float, "volume": int}, ...]
             실패 시 빈 리스트.
    """
    suffix = ".KS" if market == "KOSPI" else ".KQ"
    symbol = f"{code}{suffix}"
    encoded = urllib.parse.quote(symbol)
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{encoded}?interval=1d&range=2mo"

    try:
        resp = requests.get(url, headers=YAHOO_HEADERS, timeout=15)
        if resp.status_code != 200:
            return []
        data = resp.json()
        result = data.get("chart", {}).get("result")
        if not result:
            return []
        r0 = result[0]
        timestamps = r0.get("timestamp", []) or []
        quote = (r0.get("indicators", {}).get("quote") or [{}])[0]
        closes = quote.get("close", []) or []
        volumes = quote.get("volume", []) or []

        out = []
        for i, ts in enumerate(timestamps):
            c = closes[i] if i < len(closes) else None
            v = volumes[i] if i < len(volumes) else None
            if c is None:
                continue
            dt = datetime.fromtimestamp(ts, timezone(timedelta(hours=9)))
            out.append({
                "date": dt.strftime("%Y-%m-%d"),
                "close": float(c),
                "volume": int(v) if v is not None else 0,
            })
        return out
    except Exception as e:
        crawl.log(f"  ⚠️ Yahoo {symbol} 실패: {e}")
        return []


def main():
    crawl.log("=" * 50)
    crawl.log("📥 daily_prices 백필 시작")
    crawl.log("=" * 50)

    if not crawl.SUPABASE_KEY:
        crawl.log("❌ SUPABASE_KEY 환경변수가 설정되지 않았습니다!")
        return

    # 1) 네이버 섹터 매핑 → 전종목 시세 (시총 정보 포함)
    sector_map = crawl.fetch_naver_sector_map()
    krx_data = crawl.fetch_naver_market_data(sector_map)
    if not krx_data:
        crawl.log("⚠️ 네이버 실패 → KRX fallback")
        krx_data = crawl.fetch_krx_market_data()
    if not krx_data:
        crawl.log("❌ 시세 데이터 조회 실패")
        return

    # 2) 시총 3000억+ 필터 (ETF/ETN 제외)
    targets = [
        d for d in krx_data.values()
        if d.get("market_cap", 0) >= MIN_MARKET_CAP
        and not crawl.is_etf_etn(d["name"])
    ]
    crawl.log(f"  📋 백필 대상: {len(targets)}개 종목 (시총 3000억+)")

    # 3) 야후로 일봉 fetch → daily_prices에 INSERT
    cutoff_date = (datetime.now(timezone(timedelta(hours=9))) - timedelta(days=DAYS_RANGE)).strftime("%Y-%m-%d")
    batch = []
    BATCH_SIZE = 500
    ok_count = 0
    fail_count = 0

    for i, d in enumerate(targets, 1):
        code = d["code"]
        market = d.get("market", "KOSPI")
        market_cap = d.get("market_cap", 0)

        rows = fetch_yahoo_daily(code, market)
        if not rows:
            fail_count += 1
        else:
            for r in rows:
                if r["date"] < cutoff_date:
                    continue
                # 거래대금 ≒ close × volume (정확치 없음 → 대용 사용)
                trading_value = int(r["close"] * r["volume"])
                batch.append({
                    "code": code,
                    "date": r["date"],
                    "close": round(r["close"], 2),
                    "trading_value": trading_value,
                    "market_cap": market_cap,  # 백필 시점 기준 동일값
                })
            ok_count += 1

        if len(batch) >= BATCH_SIZE:
            crawl.supabase_request("POST", "daily_prices", data=batch)
            crawl.log(f"  💾 {i}/{len(targets)} 진행 (성공 {ok_count}, 실패 {fail_count}, 누적 {len(batch)}행)")
            batch = []

        # Rate limit 완화 (야후 무료 API)
        if i % 20 == 0:
            time.sleep(0.5)

    # 잔여 배치 flush
    if batch:
        crawl.supabase_request("POST", "daily_prices", data=batch)
        crawl.log(f"  💾 잔여 {len(batch)}행 저장")

    crawl.log("=" * 50)
    crawl.log(f"✅ 백필 완료 — 성공 {ok_count}개, 실패 {fail_count}개")
    crawl.log("=" * 50)


if __name__ == "__main__":
    main()
