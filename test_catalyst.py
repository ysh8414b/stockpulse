"""재료 포착 TOP 10 로컬 드라이런

Supabase에 아무것도 쓰지 않고 콘솔에만 결과를 출력한다.
스코어링 튜닝용 — 크롤링 전체(테마 매핑/AI 브리핑 등)를 돌리지 않아 훨씬 빠르다.

사용법 (PowerShell):
    $env:DART_API_KEY="발급받은키"
    $env:NAVER_CLIENT_ID="..."      # 선택 (없으면 뉴스 없이 공시만으로 판정)
    $env:NAVER_CLIENT_SECRET="..."  # 선택
    python test_catalyst.py

사용법 (bash):
    DART_API_KEY=... python test_catalyst.py

옵션:
    --top N      출력 개수 (기본 10)
    --no-flow    투자자 수급 조회 생략 (더 빠름, 수급 점수 0)

필요 권한:
    daily_prices 읽기만 필요하며 anon 키로 충분하다.
    SUPABASE_KEY가 없으면 공개 anon 키로 자동 폴백한다.
"""

import os
import sys

# ── Supabase 읽기 전용 폴백: service_role 키가 없으면 공개 anon 키 사용 ──
ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1tbXBxbXZ3cHV4cXl4bHh5dHNoIiwicm9sZSI6ImFub24i"
    "LCJpYXQiOjE3NzE3NTI5ODQsImV4cCI6MjA4NzMyODk4NH0."
    "KsXLXL6g-WeodZ-wYOCJnZBkUWMZ-F06Tq4XBUQsKaA"
)
if not os.environ.get("SUPABASE_KEY"):
    os.environ["SUPABASE_KEY"] = ANON_KEY

import crawl  # noqa: E402  (환경변수 세팅 후 import해야 함)


def main():
    args = sys.argv[1:]
    top_n = 10
    if "--top" in args:
        try:
            top_n = int(args[args.index("--top") + 1])
        except (IndexError, ValueError):
            pass
    if "--no-flow" in args:
        crawl.fetch_investor_trend_multi = lambda code, fallback_price=0, days=5: None

    crawl.CATALYST_TOP_N = top_n

    print("=" * 78)
    print("재료 포착 TOP 10 — 드라이런 (Supabase 쓰기 없음)")
    print("=" * 78)
    print(f"  DART 인증키   : {'설정됨' if crawl.DART_API_KEY else '없음 → 뉴스만으로 판정 (신뢰도 상한 12점)'}")
    print(f"  네이버 검색 API: {'설정됨' if crawl.NAVER_CLIENT_ID else '없음 → 뉴스 수집 불가, 공시 보유 종목만 나옴'}")
    print()

    # 1) 전종목 시세 (네이버 공개 API — 키 불필요)
    sector_map = crawl.fetch_naver_sector_map()
    krx_data = crawl.fetch_naver_market_data(sector_map)
    if not krx_data:
        print("❌ 시세 조회 실패")
        return 1

    # 2) 환율 (달러 표기 계약금액 환산용)
    usdkrw = 1350.0
    try:
        price, _prev, _spark = crawl.fetch_yahoo_chart("USDKRW=X", "5m")
        if price:
            usdkrw = float(price)
    except Exception:
        pass
    print(f"  💱 USD/KRW {usdkrw:,.2f}")
    print()

    # 3) 재료 포착 산출 (themes/stock_themes 없이 — 태그만 단순해짐)
    result = crawl.crawl_catalyst_stocks(krx_data, themes=None, stock_themes=None, usdkrw=usdkrw)

    if not result:
        print()
        print("결과 없음. 확인할 것:")
        print("  - DART 인증키가 설정되어 있는지")
        print("  - 최근 5일 안에 영업일이 있었는지 (연휴면 재료성 공시가 없을 수 있음)")
        print("  - daily_prices 테이블에 데이터가 쌓여 있는지")
        return 0

    print()
    print("=" * 78)
    for r in result:
        amt = f"{r['catalyst_amount']:,.0f}억원" if r["catalyst_amount"] > 0 else "미공개"
        print(f"\n[{r['rank']}위] {r['name']} ({r['code']})  —  종합 {r['total_score']}/100")
        print(f"  섹터/시장  : {r['display_sector'] or '미분류'} · {r['market']} · 시총 {r['market_cap'] / 1e8:,.0f}억")
        print(f"  현재가     : {r['price']:,.0f}원   1일 {r['ret_1d']:+.2f}%  5일 {r['ret_5d']:+.2f}%  20일 {r['ret_20d']:+.2f}%")
        print(f"  거래대금   : {r['trading_value'] / 1e8:,.0f}억 (20일 평균 대비 {r['tv_ratio']:.2f}배)")
        print(f"  수급(5일)  : 외국인 {r['foreign_net_5d']:+,.0f}억 / 기관 {r['institution_net_5d']:+,.0f}억 / 개인 {r['individual_net_5d']:+,.0f}억")
        print(f"  재료       : [{r['catalyst_type']}] {r['catalyst_title']}")
        print(f"  출처       : {r['catalyst_source']} · {r['catalyst_date']}")
        print(f"  규모       : {amt}" + (f"  (원문 표현: '{r['catalyst_amount_src']}')" if r["catalyst_amount_src"] else ""))
        if r["catalyst_url"]:
            print(f"  원출처     : {r['catalyst_url']}")
        print(f"  점수 내역  : 뉴스질 {r['score_news']}/25 · 가치영향 {r['score_value']}/25 · "
              f"미반영 {r['score_unpriced']}/20 · 거래·수급 {r['score_flow']}/15 · 모멘텀 {r['score_momentum']}/15")

    print()
    print("=" * 78)
    print(f"총 {len(result)}종목 · Supabase에는 저장하지 않았습니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
