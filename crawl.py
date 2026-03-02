"""
STOCKPULSE 크롤러
KRX(한국거래소) API + Yahoo Finance + 네이버 검색 API + Groq AI로 주식 데이터를 수집하여 Supabase에 저장

데이터 소스:
  - KRX: 전종목 시세 (코드, 이름, 업종, 가격, 등락률, 거래량, 시가총액) — 메인 데이터
  - Yahoo Finance: 시장 지수 + 스파크라인 차트 (코스피, 코스닥, 다우, 나스닥, S&P500, USD/KRW)
  - 네이버 검색 API: 뉴스, 테마별 관련 뉴스
  - 네이버 금융: 기업개요 (테마-종목 매핑 DB 구축)
  - Groq AI (주 1회): 뉴스 기반 인기 테마 감지 / 평소: 규칙 기반 키워드 매칭

사용법:
  pip install requests

  환경변수 설정:
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_KEY=your-service-role-key  (⚠️ service_role key 사용!)
    NAVER_CLIENT_ID=네이버 검색 API 클라이언트 ID
    NAVER_CLIENT_SECRET=네이버 검색 API 시크릿
    GROQ_API_KEY=Groq AI API 키 (주 1회 테마 감지용)

  python crawl.py
"""

import os
import re
import json
import html
import urllib.parse
from datetime import datetime, timedelta
from email.utils import parsedate_to_datetime

import requests

# ─────────────────────────────────────────
# 설정
# ─────────────────────────────────────────
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://mmmpqmvwpuxqyxlxytsh.supabase.co")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")  # service_role key (GitHub Secrets에 저장)

NAVER_CLIENT_ID = os.environ.get("NAVER_CLIENT_ID", "")
NAVER_CLIENT_SECRET = os.environ.get("NAVER_CLIENT_SECRET", "")
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")

YAHOO_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
}

TODAY = datetime.now().strftime("%Y-%m-%d")

import sys as _sys
if _sys.stdout.encoding and _sys.stdout.encoding.lower().replace("-","") != "utf8":
    _sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    _sys.stderr.reconfigure(encoding="utf-8", errors="replace")

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}")


# ─────────────────────────────────────────
# 섹터/테마 상수
# ─────────────────────────────────────────
SECTOR_ICONS = {
    "반도체":    "⚡",
    "2차전지":   "🔋",
    "바이오":    "🧬",
    "자동차":    "🚗",
    "IT/플랫폼": "💻",
    "금융":      "🏦",
    "소비재":    "🛒",
    "철강/소재": "⚙️",
    "에너지":    "⛽",
    "건설":      "🏗️",
}

# 네이버 업종 ID → 디스플레이 섹터 매핑
# (네이버 금융 sise_group_detail.naver?type=upjong&no=XX)
NAVER_SECTOR_MAP = {
    # 반도체
    278: "반도체",   # 반도체와반도체장비
    269: "반도체",   # 디스플레이장비및부품
    327: "반도체",   # 디스플레이패널
    # 바이오
    286: "바이오",   # 생물공학
    261: "바이오",   # 제약
    281: "바이오",   # 건강관리장비와용품
    262: "바이오",   # 생명과학도구및서비스
    288: "바이오",   # 건강관리기술
    316: "바이오",   # 건강관리업체및서비스
    # 자동차
    273: "자동차",   # 자동차
    270: "자동차",   # 자동차부품
    # IT/플랫폼
    267: "IT/플랫폼", # IT서비스
    287: "IT/플랫폼", # 소프트웨어
    293: "IT/플랫폼", # 컴퓨터와주변기기
    300: "IT/플랫폼", # 양방향미디어와서비스
    308: "IT/플랫폼", # 인터넷과카탈로그소매
    263: "IT/플랫폼", # 게임엔터테인먼트
    285: "IT/플랫폼", # 방송과엔터테인먼트
    292: "IT/플랫폼", # 핸드셋
    294: "IT/플랫폼", # 통신장비
    336: "IT/플랫폼", # 다각화된통신서비스
    333: "IT/플랫폼", # 무선통신서비스
    310: "IT/플랫폼", # 광고
    338: "IT/플랫폼", # 사무용전자제품
    314: "IT/플랫폼", # 출판
    # 금융
    301: "금융",     # 은행
    321: "금융",     # 증권
    330: "금융",     # 생명보험
    315: "금융",     # 손해보험
    319: "금융",     # 기타금융
    337: "금융",     # 카드
    280: "금융",     # 부동산
    277: "금융",     # 창업투자
    # 소비재
    266: "소비재",   # 화장품
    268: "소비재",   # 식품
    309: "소비재",   # 음료
    275: "소비재",   # 담배
    274: "소비재",   # 섬유,의류,신발,호화품
    297: "소비재",   # 가정용품
    298: "소비재",   # 가정용기기와용품
    303: "소비재",   # 가구
    302: "소비재",   # 식품과기본식료품소매
    264: "소비재",   # 백화점과일반상점
    328: "소비재",   # 전문소매
    339: "소비재",   # 다각화된소비자서비스
    317: "소비재",   # 호텔,레스토랑,레저
    271: "소비재",   # 레저용장비와제품
    332: "소비재",   # 문구류
    # 철강/소재
    272: "철강/소재", # 화학
    304: "철강/소재", # 철강
    322: "철강/소재", # 비철금속
    318: "철강/소재", # 종이와목재
    311: "철강/소재", # 포장재
    289: "철강/소재", # 건축자재
    320: "철강/소재", # 건축제품
    # 에너지
    313: "에너지",   # 석유와가스
    312: "에너지",   # 가스유틸리티
    325: "에너지",   # 전기유틸리티
    295: "에너지",   # 에너지장비및서비스
    # 건설
    279: "건설",     # 건설
    299: "건설",     # 기계
    291: "건설",     # 조선
    284: "건설",     # 우주항공과국방
    283: "건설",     # 전기제품
    306: "건설",     # 전기장비
    307: "건설",     # 전자제품
    282: "건설",     # 전자장비와기기
    296: "건설",     # 운송인프라
    329: "건설",     # 도로와철도운송
    326: "건설",     # 항공화물운송과물류
    305: "건설",     # 항공사
    323: "건설",     # 해운사
}

# KRX 업종 → 디스플레이 섹터 매핑 (KRX fallback용)
KRX_SECTOR_MAP = {
    # KOSPI 업종
    "전기전자":   "반도체",
    "의약품":     "바이오",
    "의료정밀":   "바이오",
    "운수장비":   "자동차",
    "서비스업":   "IT/플랫폼",
    "통신업":     "IT/플랫폼",
    "은행":       "금융",
    "증권":       "금융",
    "보험":       "금융",
    "기타금융":   "금융",
    "철강금속":   "철강/소재",
    "비금속광물": "철강/소재",
    "화학":       "철강/소재",
    "종이목재":   "철강/소재",
    "건설업":     "건설",
    "기계":       "건설",
    "음식료품":   "소비재",
    "유통업":     "소비재",
    "섬유의복":   "소비재",
    "전기가스업": "에너지",
    # KOSDAQ 업종
    "IT S/W & SVC":        "IT/플랫폼",
    "IT H/W":              "반도체",
    "제조 - 전기전자":      "반도체",
    "제조 - 화학":          "철강/소재",
    "제조 - 의료/정밀기기": "바이오",
    "제조 - 기계/장비":     "건설",
    "제조 - 금속":          "철강/소재",
    "제조 - 음식료/담배":   "소비재",
    "유통":                 "소비재",
    "오락/문화":            "IT/플랫폼",
    "금융":                 "금융",
}

# 2차전지 종목 (KRX에 별도 업종이 없어 코드로 직접 지정)
BATTERY_STOCK_CODES = {
    "373220",  # LG에너지솔루션
    "247540",  # 에코프로비엠
    "086520",  # 에코프로
    "003670",  # 포스코퓨처엠
    "066570",  # LG전자
    "051910",  # LG화학
    "112610",  # 씨에스윈드
    "298050",  # 엘앤에프
    "006260",  # LS
    "006400",  # 삼성SDI
}

# AI 종목명 별칭 (AI가 다른 이름으로 부를 수 있는 종목)
STOCK_NAME_ALIASES = {
    "현대차":              "현대자동차",
    "POSCO홀딩스":         "포스코홀딩스",
    "포스코케미칼":         "포스코퓨처엠",
    "HL만도":              "만도",
    "YG엔터":             "YG엔터테인먼트",
    "JYP":                "JYP Ent.",
    "JYP엔터테인먼트":     "JYP Ent.",
    "JYP엔터":            "JYP Ent.",
    "SK바이오팜":          "SK바이오팜",
    "SK이노베이션":        "SK이노베이션",
    "LG에너지":            "LG에너지솔루션",
    "삼성바이오":          "삼성바이오로직스",
    "한화에어로":          "한화에어로스페이스",
    "HD현대중공":          "HD현대중공업",
    "HD한국조선":          "HD한국조선해양",
    "현대차증권":          "현대차증권",
    "SM엔터":             "SM",
    "SM엔터테인먼트":      "SM",
    "에코프로BM":          "에코프로비엠",
    "두산에너빌":          "두산에너빌리티",
    "레인보우로보":         "레인보우로보틱스",
    "두산로보":            "두산로보틱스",
    "아모레":              "아모레퍼시픽",
    "LG생건":              "LG생활건강",
    "HD현대일렉":          "HD현대일렉트릭",
    "LS일렉":              "LS일렉트릭",
    "한화시스":            "한화시스템",
}

# 동적 종목코드 매핑 — main()에서 KRX 데이터로 자동 구축
KNOWN_STOCK_CODES = {}

# 테마 정의 (AI 미사용 시 fallback)
THEME_DEFINITIONS = [
    {"name": "반도체",   "search_query": "반도체 주식",
     "stocks": ["005930", "000660", "402340", "042700", "166090", "058470", "357780", "403870", "036930", "240810"]},
    {"name": "2차전지",  "search_query": "2차전지 배터리 주식",
     "stocks": ["373220", "247540", "086520", "003670", "051910", "298050", "112610", "006260"]},
    {"name": "AI",       "search_query": "AI 인공지능 주식",
     "stocks": ["005930", "000660", "035420", "017670", "030200", "036930"]},
    {"name": "바이오",   "search_query": "바이오 제약 주식",
     "stocks": ["068270", "207940", "000100", "128940", "196170", "141080", "145020", "302440"]},
    {"name": "전기차",   "search_query": "전기차 자율주행 주식",
     "stocks": ["005380", "000270", "373220", "018880", "012330"]},
    {"name": "방산",     "search_query": "방산 방위산업 주식",
     "stocks": ["012450", "079550", "047810", "000880", "064350"]},
    {"name": "금융",     "search_query": "금융 은행 주식",
     "stocks": ["105560", "055550", "086790", "316140", "032830", "000810"]},
    {"name": "게임",     "search_query": "게임 엔터 주식",
     "stocks": ["259960", "036570", "263750", "251270"]},
    {"name": "에너지",   "search_query": "에너지 전력 주식",
     "stocks": ["015760", "096770", "010950", "009830", "112610"]},
    {"name": "건설",     "search_query": "건설 부동산 주식",
     "stocks": ["000720", "047040", "006360", "375500", "028260"]},
]


# ─────────────────────────────────────────
# Supabase 헬퍼
# ─────────────────────────────────────────
def supabase_request(method, table, data=None, params=None):
    """Supabase REST API 직접 호출 (라이브러리 없이도 작동)"""
    url = f"{SUPABASE_URL}/rest/v1/{table}"
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal",
    }
    if method == "GET":
        resp = requests.get(url, headers=headers, params=params)
    elif method == "POST":
        headers["Prefer"] = "return=representation"
        resp = requests.post(url, headers=headers, json=data)
    elif method == "DELETE":
        resp = requests.delete(url, headers=headers, params=params)
    elif method == "PATCH":
        resp = requests.patch(url, headers=headers, json=data, params=params)

    if resp.status_code >= 400:
        log(f"  ⚠️ Supabase 오류 ({table}): {resp.status_code} - {resp.text[:200]}")
        return None

    try:
        return resp.json() if resp.text else None
    except:
        return None


def clear_today_data(table):
    """데이터 삭제 (중복 방지)"""
    if table in ("market_index", "sectors", "issue_stocks", "themes"):
        supabase_request("DELETE", table, params={"id": "gt.0"})
    else:
        supabase_request("DELETE", table, params={"date": f"eq.{TODAY}"})



# ─────────────────────────────────────────
# 네이버 금융 API (메인 데이터 소스)
# ─────────────────────────────────────────
NAVER_STOCK_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
}





def _fetch_naver_stocks(market_type, page_size=100):
    """네이버 금융 API에서 시장별 전종목 시세 조회"""
    all_stocks = []
    page = 1
    while True:
        try:
            resp = requests.get(
                f"https://m.stock.naver.com/api/stocks/marketValue/{market_type}",
                params={"page": page, "pageSize": page_size},
                headers=NAVER_STOCK_HEADERS,
                timeout=15,
            )
            if resp.status_code != 200:
                log(f"  ⚠️ 네이버 {market_type} page {page}: HTTP {resp.status_code}")
                break

            data = resp.json()
            stocks = data.get("stocks", [])
            if not stocks:
                break

            all_stocks.extend(stocks)
            total = data.get("totalCount", 0)

            if page * page_size >= total:
                break
            page += 1

        except Exception as e:
            log(f"  ⚠️ 네이버 {market_type} page {page} 실패: {e}")
            break

    return all_stocks


def fetch_naver_market_data(sector_map=None):
    """네이버 금융 API에서 전종목 시세 데이터 조회 (KRX 대체)"""
    log("📋 네이버 금융 API 전종목 시세 조회 중...")
    if sector_map is None:
        sector_map = {}
    all_data = {}

    for market_type, market_name in [("KOSPI", "KOSPI"), ("KOSDAQ", "KOSDAQ")]:
        stocks = _fetch_naver_stocks(market_type)
        count = 0

        for item in stocks:
            code = item.get("itemCode", "").strip()
            name = item.get("stockName", "").strip()

            if not code or not name or len(code) != 6 or not code.isdigit():
                continue

            # 우선주/ETF 등 제외
            stock_end_type = item.get("stockEndType", "")
            if stock_end_type not in ("stock", ""):
                continue

            try:
                price = int(item.get("closePrice", "0").replace(",", ""))
                change_pct = float(item.get("fluctuationsRatio", "0").replace(",", ""))
                volume = int(item.get("accumulatedTradingVolume", "0").replace(",", ""))
                trading_value = int(item.get("accumulatedTradingValue", "0").replace(",", "")) * 1_000_000  # 백만원→원
                market_cap = int(item.get("marketValue", "0").replace(",", "")) * 100_000_000  # 억원→원
            except (ValueError, TypeError):
                continue

            # 업종 매핑 (네이버 섹터 매핑 활용)
            if code in BATTERY_STOCK_CODES:
                display_sector = "2차전지"
            else:
                display_sector = sector_map.get(code, "")

            all_data[code] = {
                "code": code,
                "name": name,
                "market": market_name,
                "display_sector": display_sector,
                "price": price,
                "change_pct": change_pct,
                "volume": volume,
                "trading_value": trading_value,
                "market_cap": market_cap,
            }
            count += 1

        log(f"  ✅ 네이버 {market_name}: {count}개 종목")

    log(f"  📊 총 {len(all_data)}개 종목 로드 완료")
    return all_data


# ─────────────────────────────────────────
# KRX 데이터 (Fallback)
# ─────────────────────────────────────────
def _fetch_krx_for_date(date_str, mkt_id, mkt_name):
    """특정 날짜의 KRX 전종목 시세 조회"""
    try:
        resp = requests.post(
            "http://data.krx.co.kr/comm/bldAttendant/getJsonData.cmd",
            data={
                "bld": "dbms/MDC/STAT/standard/MDCSTAT01501",
                "locale": "ko_KR",
                "mktId": mkt_id,
                "trdDd": date_str,
                "share": "1",
                "money": "1",
                "csvxls_isNo": "false",
            },
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "http://data.krx.co.kr/contents/MDC/MDI/mdiLoader/index.cmd?menuId=MDC0201020101",
            },
            timeout=15,
        )
        items = resp.json().get("OutBlock_1", [])
        return items
    except Exception as e:
        log(f"  ⚠️ KRX {mkt_name} ({date_str}) 조회 실패: {e}")
        return []


def fetch_krx_market_data():
    """KRX에서 전종목 시세 데이터 동적 조회 (코드+이름+업종+가격+거래량+시총)"""
    log("📋 KRX 전종목 시세 조회 중 (fallback)...")
    all_data = {}

    for days_back in range(5):
        dt = datetime.now() - timedelta(days=days_back)
        if dt.weekday() >= 5:
            continue
        date_str = dt.strftime("%Y%m%d")

        for mkt_id, mkt_name in [("STK", "KOSPI"), ("KSQ", "KOSDAQ")]:
            items = _fetch_krx_for_date(date_str, mkt_id, mkt_name)

            for item in items:
                code = item.get("ISU_SRT_CD", "").strip()
                name = item.get("ISU_ABBRV", "").strip()
                krx_sector = item.get("SECT_TP_NM", "").strip()

                if not code or not name or len(code) != 6 or not code.isdigit():
                    continue

                try:
                    price = int(item.get("TDD_CLSPRC", "0").replace(",", ""))
                    change_pct = float(item.get("FLUC_RT", "0").replace(",", ""))
                    volume = int(item.get("ACC_TRDVOL", "0").replace(",", ""))
                    trading_value = int(item.get("ACC_TRDVAL", "0").replace(",", ""))
                    market_cap = int(item.get("MKTCAP", "0").replace(",", ""))
                except (ValueError, TypeError):
                    continue

                if code in BATTERY_STOCK_CODES:
                    display_sector = "2차전지"
                else:
                    override = _sub_classify_sector(name, krx_sector)
                    if override:
                        display_sector = override
                    else:
                        display_sector = KRX_SECTOR_MAP.get(krx_sector, "")

                all_data[code] = {
                    "code": code,
                    "name": name,
                    "market": mkt_name,
                    "krx_sector": krx_sector,
                    "display_sector": display_sector,
                    "price": price,
                    "change_pct": change_pct,
                    "volume": volume,
                    "trading_value": trading_value,
                    "market_cap": market_cap,
                }

            if items:
                log(f"  ✅ KRX {mkt_name} ({date_str}): {len(items)}개 종목")

        if all_data:
            break
        else:
            log(f"  ⚠️ {date_str} 데이터 없음 - 이전 날짜 시도...")

    log(f"  📊 KRX 총 {len(all_data)}개 종목 로드 완료")
    return all_data


# ─────────────────────────────────────────
# KRX 섹터 매핑 (종목코드 → 업종)
# ─────────────────────────────────────────
SECTOR_MAP_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sector_map.json")

# 화학 업종 내 소비재 재분류 키워드 (종목명 기반)
CONSUMER_GOODS_KEYWORDS = [
    "아모레", "LG생활", "코스맥스", "한국콜마", "클리오", "잇츠한불",
    "애경", "콜마비앤에이치", "에이블씨엔씨", "토니모리", "네이처리퍼블릭",
    "삼양식품", "오뚜기", "농심", "CJ제일", "대상", "롯데웰",
    "동서", "삼립", "풀무원", "매일유업", "빙그레", "오리온",
    "롯데칠성", "하이트진로", "코웨이", "아모레G", "LG H&H",
]


def fetch_naver_sector_map():
    """네이버 금융 업종별 종목 페이지에서 종목코드 → 디스플레이 섹터 매핑 구축 (일 1회 캐시, 7일 유효)"""
    # 캐시 확인
    if os.path.exists(SECTOR_MAP_FILE):
        try:
            with open(SECTOR_MAP_FILE, "r", encoding="utf-8") as f:
                cached = json.load(f)
            cached_date = cached.get("date", "")
            if cached_date == TODAY and cached.get("map"):
                log(f"  📂 섹터 매핑 캐시 사용 ({len(cached['map'])}개 종목)")
                return cached["map"]
            days_old = (datetime.now() - datetime.strptime(cached_date, "%Y-%m-%d")).days if cached_date else 999
            if days_old <= 7 and cached.get("map"):
                stale_cache = cached["map"]
            else:
                stale_cache = None
        except Exception:
            stale_cache = None
    else:
        stale_cache = None

    log("  🏗️ 네이버 업종별 섹터 매핑 조회 중...")
    sector_map = {}  # code → display_sector

    for naver_id, display_sector in NAVER_SECTOR_MAP.items():
        try:
            resp = requests.get(
                f"https://finance.naver.com/sise/sise_group_detail.naver?type=upjong&no={naver_id}",
                headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"},
                timeout=10,
            )
            html = resp.content.decode("euc-kr", errors="replace")
            codes = re.findall(r'main\.naver\?code=(\d{6})', html)
            for code in codes:
                if code not in sector_map:
                    sector_map[code] = display_sector
        except Exception as e:
            log(f"  ⚠️ 네이버 업종 {naver_id} 조회 실패: {e}")
            continue

    if not sector_map:
        if stale_cache:
            log(f"  ⚠️ 섹터 조회 실패 - 이전 캐시 사용 ({len(stale_cache)}개)")
            return stale_cache
        log("  ❌ 섹터 매핑 조회 실패")
        return {}

    log(f"  ✅ 네이버 섹터 매핑 완료: {len(sector_map)}개 종목")

    # 캐시 저장
    try:
        with open(SECTOR_MAP_FILE, "w", encoding="utf-8") as f:
            json.dump({"date": TODAY, "map": sector_map}, f, ensure_ascii=False)
        log(f"  💾 섹터 매핑 캐시 저장")
    except Exception:
        pass

    return sector_map


def _sub_classify_sector(name, krx_sector):
    """화학 등 넓은 KRX 업종을 종목명 키워드로 세분화 (소비재 재분류)"""
    if krx_sector in ("화학", "제조 - 화학"):
        for kw in CONSUMER_GOODS_KEYWORDS:
            if kw in name:
                return "소비재"
    return None


def build_stock_code_map(krx_data):
    """데이터에서 종목명 → (코드, 시장) 매핑 구축 (AI 코드 보정용)"""
    mapping = {}
    for code, info in krx_data.items():
        mapping[info["name"]] = (code, info["market"])
    # 별칭 추가 (양방향: alias→real, real→alias)
    for alias, real_name in STOCK_NAME_ALIASES.items():
        if real_name in mapping and alias not in mapping:
            mapping[alias] = mapping[real_name]
        if alias in mapping and real_name not in mapping:
            mapping[real_name] = mapping[alias]
    return mapping


# ─────────────────────────────────────────
# Yahoo Finance (시장 지수 전용)
# ─────────────────────────────────────────
def fetch_yahoo_chart(symbol, interval="15m"):
    """Yahoo Finance v8 chart API로 단일 지수/환율 조회 + 당일 스파크라인 데이터"""
    encoded = urllib.parse.quote(symbol)
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{encoded}?interval={interval}&range=1d"
    resp = requests.get(url, headers=YAHOO_HEADERS, timeout=10)
    data = resp.json()
    result = data["chart"]["result"][0]
    meta = result["meta"]
    price = meta.get("regularMarketPrice", 0)
    prev = meta.get("previousClose", 0) or meta.get("chartPreviousClose", 0)

    # 스파크라인용 당일 15분봉 종가 데이터 추출
    quotes = result.get("indicators", {}).get("quote", [{}])[0]
    closes = [round(c, 2) for c in quotes.get("close", []) if c is not None]

    # 동일 가격 3봉 이상 연속 시 제외 (장 마감 후 평탄 구간 제거)
    filtered = []
    repeat_count = 0
    last_val = None
    for v in closes:
        if v == last_val:
            repeat_count += 1
            if repeat_count >= 3:
                continue
        else:
            repeat_count = 1
            last_val = v
        filtered.append(v)

    # 최대 70포인트로 다운샘플링 (LTTB - 차트 형태 보존)
    MAX_POINTS = 70
    if len(filtered) > MAX_POINTS:
        src = filtered
        n = len(src)
        sampled = [src[0]]  # 첫 점 유지
        bucket_size = (n - 2) / (MAX_POINTS - 2)
        prev_idx = 0
        for i in range(1, MAX_POINTS - 1):
            b_start = int((i - 1) * bucket_size) + 1
            b_end = int(i * bucket_size) + 1
            b_end = min(b_end, n)
            # 다음 버킷 평균
            nb_start = int(i * bucket_size) + 1
            nb_end = int((i + 1) * bucket_size) + 1
            nb_end = min(nb_end, n)
            avg_next = sum(src[nb_start:nb_end]) / max(1, nb_end - nb_start)
            # 현재 버킷에서 삼각형 면적 최대인 점 선택
            best_idx = b_start
            max_area = -1
            for j in range(b_start, b_end):
                area = abs((j - prev_idx) * (avg_next - src[prev_idx])
                           - (prev_idx - prev_idx) * (src[j] - src[prev_idx]))
                if area > max_area:
                    max_area = area
                    best_idx = j
            sampled.append(src[best_idx])
            prev_idx = best_idx
        sampled.append(src[-1])  # 마지막 점 유지
        filtered = sampled

    return price, prev, filtered


# ─────────────────────────────────────────
# 헬퍼 함수
# ─────────────────────────────────────────
def classify_news_category(title):
    """뉴스 제목으로 카테고리 분류"""
    categories = {
        "반도체": ["반도체", "삼성전자", "SK하이닉스", "HBM", "메모리", "파운드리", "칩"],
        "2차전지": ["2차전지", "배터리", "리튬", "양극재", "음극재", "에코프로", "LG에너지"],
        "바이오": ["바이오", "제약", "신약", "임상", "셀트리온", "삼성바이오"],
        "자동차": ["자동차", "현대차", "기아", "전기차", "EV", "자율주행"],
        "IT": ["네이버", "카카오", "AI", "인공지능", "플랫폼", "클라우드"],
        "금융": ["금리", "은행", "보험", "증권", "금융", "대출"],
        "시장": ["코스피", "코스닥", "지수", "증시", "주가", "시총", "외국인", "기관"],
        "글로벌": ["미국", "중국", "일본", "연준", "Fed", "환율", "달러", "나스닥", "다우"],
        "부동산": ["부동산", "아파트", "건설", "분양", "PF"],
        "에너지": ["원유", "가스", "석유", "에너지", "태양광", "풍력"],
    }

    for cat, keywords in categories.items():
        if any(kw in title for kw in keywords):
            return cat
    return "시장"


def analyze_sentiment(title):
    """간단한 키워드 기반 감성 분석"""
    positive_words = [
        "상승", "급등", "최고", "호조", "돌파", "순매수", "확대", "성장",
        "호실적", "수혜", "기대", "강세", "반등", "신고가", "흑자",
    ]
    negative_words = [
        "하락", "급락", "폭락", "우려", "위축", "매도", "적자", "감소",
        "약세", "리스크", "위기", "부진", "손실", "하회", "불안",
    ]

    pos = sum(1 for w in positive_words if w in title)
    neg = sum(1 for w in negative_words if w in title)

    if pos > neg:
        return "positive"
    elif neg > pos:
        return "negative"
    return "neutral"


def format_trading_value(raw_text):
    """거래대금 포맷 (억원 단위 → 읽기 쉬운 형태)"""
    try:
        val = float(raw_text.replace(",", "").replace(" ", "").strip())
        if val >= 10000:
            return f"{val/10000:.1f}조"
        else:
            return f"{int(val):,}억"
    except:
        return raw_text

def is_etf_etn(name):
    """ETF/ETN 종목 필터링"""
    skip = ["ETN", "ETF", "KODEX", "TIGER", "RISE", "KBSTAR", "SOL", "HANARO",
            "인버스", "레버리지", "액티브", "선물", "채권", "합성"]
    return any(kw in name for kw in skip)


def classify_stock_tags(name, display_sector="", theme_names=None):
    """종목 태그 분류 (섹터 기반 + 테마 소속)"""
    tags = []

    # 1) display_sector 활용 (네이버 업종 기반)
    if display_sector:
        tags.append(display_sector)

    # 2) 인기 테마 소속이면 테마명 추가
    if theme_names:
        for t in theme_names:
            if t not in tags:
                tags.append(t)

    # 3) 특수 태그 (종목명 기반, display_sector에 없는 분류)
    special_tags = {
        "AI": ["삼성전자", "SK하이닉스", "네이버", "카카오"],
        "방산": ["한화에어로스페이스", "LIG넥스원", "한국항공우주", "현대로템"],
    }
    for tag, names in special_tags.items():
        if tag not in tags and any(n in name for n in names):
            tags.append(tag)

    if not tags:
        tags = ["기타"]

    return tags[:3]


def _calc_time_ago(pub_date_str):
    """Naver API pubDate (RFC 822) -> '~시간 전' 형태"""
    try:
        pub = parsedate_to_datetime(pub_date_str)
        now = datetime.now(pub.tzinfo)
        diff = now - pub
        hours = int(diff.total_seconds() // 3600)
        if hours < 1:
            minutes = max(1, int(diff.total_seconds() // 60))
            return f"{minutes}분 전"
        elif hours < 24:
            return f"{hours}시간 전"
        else:
            return f"{hours // 24}일 전"
    except:
        return "오늘"


def _is_similar_title(new_title, existing_titles, threshold=0.65):
    """제목 유사도 체크 — 2글자 단위(bigram) 겹침이 threshold 이상이면 유사"""
    def _bigrams(s):
        s = re.sub(r'[^\w]', '', s)
        return set(s[i:i+2] for i in range(len(s)-1)) if len(s) >= 2 else set()
    new_bg = _bigrams(new_title)
    if not new_bg:
        return False
    for t in existing_titles:
        old_bg = _bigrams(t)
        if not old_bg:
            continue
        overlap = len(new_bg & old_bg) / min(len(new_bg), len(old_bg))
        if overlap > threshold:
            return True
    return False


def _search_theme_news_api(query, theme_name=""):
    """Naver Search API로 테마 관련 뉴스 검색 (최대 5건, 다양성 확보)"""
    if not NAVER_CLIENT_ID or not NAVER_CLIENT_SECRET:
        return "", "", "[]"
    try:
        url = "https://openapi.naver.com/v1/search/news.json"
        headers = {
            "X-Naver-Client-Id": NAVER_CLIENT_ID,
            "X-Naver-Client-Secret": NAVER_CLIENT_SECRET,
        }
        core_kw = query.replace("주식", "").replace("관련", "").strip()

        # 다양한 쿼리로 검색 (테마명 주식 + 테마명 단독 + 테마명 관련주)
        queries = [query]
        if core_kw and core_kw != query:
            queries.append(core_kw)
        if core_kw:
            queries.append(f"{core_kw} 관련주")

        all_items = []
        seen_urls = set()
        for q in queries:
            resp = requests.get(url, headers=headers, params={"query": q, "display": 10, "sort": "date"}, timeout=5)
            for item in resp.json().get("items", []):
                link = item.get("link", "")
                if link not in seen_urls:
                    all_items.append(item)
                    seen_urls.add(link)

        if not all_items:
            return "", "", "[]"

        # 테마 관련 키워드 목록 (테마명 + 핵심 단어들)
        theme_kws = set()
        if theme_name:
            theme_kws.add(theme_name.replace(" ", "").lower())
            # "제약/바이오" → {"제약바이오", "제약", "바이오"}
            for part in re.split(r'[/·\s]', theme_name):
                if len(part) >= 2:
                    theme_kws.add(part.lower())
        if core_kw:
            theme_kws.add(core_kw.lower())
            for part in re.split(r'[/·\s]', core_kw):
                if len(part) >= 2:
                    theme_kws.add(part.lower())

        # 제목에 테마 키워드 포함된 뉴스만 선별 (언론사명 제외)
        relevant = []
        for item in all_items:
            title = html.unescape(re.sub(r'<[^>]+>', '', item.get("title", ""))).strip()
            if not title:
                continue
            # [데일리국제금융], (매일경제) 등 언론사명 제거 후 키워드 매칭
            title_for_match = re.sub(r'[\[\(【].*?[\]\)】]', '', title)
            title_lower = title_for_match.replace(" ", "").lower()
            if any(kw in title_lower for kw in theme_kws):
                relevant.append({"title": title, "url": item.get("link", "")})

        # 유사도 필터링하며 5개 선별
        cleaned = []
        used_titles = []
        for item in relevant:
            if _is_similar_title(item["title"], used_titles):
                continue
            cleaned.append(item)
            used_titles.append(item["title"])
            if len(cleaned) >= 5:
                break

        news_list = cleaned[:5]
        first_title = news_list[0]["title"] if news_list else ""
        first_url = news_list[0]["url"] if news_list else ""
        return first_title, first_url, json.dumps(news_list, ensure_ascii=False)
    except Exception as e:
        log(f"  ⚠️ 테마뉴스 검색 실패 ({query}): {e}")
    return "", "", "[]"


# ─────────────────────────────────────────
# 테마-종목 매핑 DB (기업개요 기반)
# ─────────────────────────────────────────
THEME_MAP_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "theme_stock_map.json")


def _fetch_company_overview(code):
    """네이버 금융 PC에서 기업개요 + 업종 크롤링"""
    try:
        headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
        resp = requests.get(
            f"https://finance.naver.com/item/main.naver?code={code}",
            headers=headers, timeout=10,
        )
        html = resp.text

        # 업종
        sector = ""
        sm = re.search(r'<a href="/sise/sise_group_detail\.naver[^"]*">([^<]+)</a>', html)
        if sm:
            sector = sm.group(1).strip()

        # 기업개요 텍스트
        overview = ""
        om = re.search(r'class="wrap_company"(.*?)</table>', html, re.DOTALL)
        if om:
            raw = re.sub(r'<[^>]+>', ' ', om.group(1))
            raw = re.sub(r'\s+', ' ', raw).strip()
            # "기업개요" ~ "출처" 사이만 추출
            start = raw.find("기업개요")
            end = raw.find("출처")
            if start >= 0:
                overview = raw[start + 4:end].strip() if end > start else raw[start + 4:start + 500].strip()

        return sector, overview
    except Exception:
        return "", ""


def build_theme_stock_map(krx_data):
    """네이버 업종 + 기업개요 키워드로 테마-종목 매핑 DB 구축 (AI 불필요)"""

    # 캐시 유효기간: 7일
    CACHE_MAX_DAYS = 7
    if os.path.exists(THEME_MAP_FILE):
        try:
            with open(THEME_MAP_FILE, "r", encoding="utf-8") as f:
                cached = json.load(f)
            cached_date = cached.get("date", "")
            cached_stocks = cached.get("stocks", {})
            if cached_date and cached_stocks:
                days_old = (datetime.strptime(TODAY, "%Y-%m-%d") - datetime.strptime(cached_date, "%Y-%m-%d")).days
                if days_old < CACHE_MAX_DAYS:
                    log(f"  📂 테마 매핑 DB 캐시 사용 ({days_old}일 전, {len(cached_stocks)}개 종목)")
                    return cached.get("theme_to_stocks", {}), cached_stocks
                else:
                    log(f"  🔄 테마 매핑 DB 캐시 만료 ({days_old}일 경과) - 재구축")
        except Exception:
            pass

    log("  🏗️ 테마-종목 매핑 DB 구축 시작 (업종+키워드 기반)...")

    # ── 네이버 업종명 → 테마 매핑 룰 (정확히 일치하는 업종명) ──
    SECTOR_TO_THEME = {
        # 반도체
        "반도체와반도체장비": "반도체",
        # 2차전지
        "전기제품": "2차전지",       # LG에너지솔루션, 삼성SDI, 에코프로비엠
        # 자동차
        "자동차": "자동차", "자동차부품": "자동차",
        # 방산
        "우주항공과국방": "방산",
        # 조선
        "조선": "조선",
        # 제약/바이오
        "제약": "제약/바이오", "생물공학": "제약/바이오",
        "생명과학도구및서비스": "제약/바이오",
        "건강관리업체및서비스": "제약/바이오",
        # 전력/에너지
        "전기유틸리티": "전력/에너지", "전기장비": "전력/에너지",
        "가스유틸리티": "전력/에너지", "에너지장비및서비스": "전력/에너지",
        # 금융
        "은행": "금융", "증권": "금융", "생명보험": "금융", "손해보험": "금융",
        "카드": "금융",
        # 건설
        "건설": "건설", "건축자재": "건설",
        # 통신
        "무선통신서비스": "통신", "다각화된통신서비스": "통신", "통신장비": "통신",
        # 철강/소재
        "철강": "철강/소재", "비철금속": "철강/소재", "화학": "화학",
        # IT/플랫폼
        "양방향미디어와서비스": "IT/플랫폼", "소프트웨어": "IT/플랫폼",
        "IT서비스": "IT/플랫폼",
        # 게임
        "게임엔터테인먼트": "게임",
        # 디스플레이
        "디스플레이패널": "디스플레이", "디스플레이장비": "디스플레이",
        # 화장품
        "화장품": "화장품",
        # 식품
        "식품": "식품",
        # 엔터
        "방송과엔터테인먼트": "엔터",
        # 전자/부품
        "전자장비와기기": "전자부품", "전자제품": "전자부품",
        # 항공/물류/해운
        "항공사": "항공", "항공화물운송과물류": "물류", "해운사": "해운",
        # 의료기기
        "건강관리장비와용품": "의료기기",
        # 패션
        "섬유,의류,신발,호화품": "패션",
        # 유통
        "백화점과일반상점": "유통", "인터넷과카탈로그소매": "유통",
        # 석유/가스
        "석유와가스": "석유/가스",
        # 기계 (로봇 등은 키워드로 추가 분류)
        "기계": "기계",
    }

    # ── 기업개요 키워드 → 테마 매핑 (업종 보완용) ──
    KEYWORD_TO_THEME = {
        # 2차전지 (화학 업종 내 2차전지 기업 분류)
        "2차전지": "2차전지", "배터리": "2차전지", "양극재": "2차전지", "음극재": "2차전지",
        "리튬": "2차전지", "전해질": "2차전지", "분리막": "2차전지", "양극소재": "2차전지",
        "이차전지": "2차전지", "전구체": "2차전지",
        # 전기차
        "전기차": "전기차", "전기자동차": "전기차",
        # AI (엄격: 핵심 AI 사업 키워드만)
        "HBM": "AI", "AI반도체": "AI", "생성형AI": "AI",
        "NPU": "AI", "딥러닝": "AI", "LLM": "AI",
        "AI서버": "AI", "AI데이터센터": "AI", "AI칩": "AI",
        # 로봇 (기계 업종 내 로봇 기업 분류)
        "로봇": "로봇", "로보틱스": "로봇", "코봇": "로봇", "자동화장비": "로봇",
        # 원전
        "원전": "원전", "원자력": "원전", "소형모듈원자로": "원전",
        # 수소
        "수소": "수소", "연료전지": "수소",
        # 태양광
        "태양광": "태양광", "태양전지": "태양광", "솔라셀": "태양광",
        # 드론
        "드론": "드론", "무인항공": "드론",
        # 조선 (키워드 보강)
        "선박": "조선", "LNG선": "조선",
        # 방산 (키워드 보강)
        "방산": "방산", "방위산업": "방산", "무기체계": "방산", "장갑차": "방산",
    }

    # 짧은 영문 키워드는 정규식으로 별도 처리 (단어 경계 매칭)
    import re as _re
    SHORT_KEYWORD_PATTERNS = [
        (_re.compile(r'(?<![A-Za-z])GPU(?![A-Za-z])'), "AI"),
        (_re.compile(r'(?<![A-Za-z])EV(?![A-Za-z])'), "전기차"),
        (_re.compile(r'(?<![A-Za-z])SMR(?![A-Za-z])'), "원전"),
        (_re.compile(r'(?<![A-Za-z])UAM(?![A-Za-z])'), "드론"),
    ]

    # 시총 3000억+ 종목 필터 (우선주 제외)
    MIN_MARKET_CAP = 300_000_000_000
    eligible = []
    for code, d in krx_data.items():
        if d.get("market_cap", 0) >= MIN_MARKET_CAP:
            if code[-1] in ("5", "7", "8", "9") and "우" in d["name"]:
                continue
            eligible.append((code, d["name"], d["market"]))
    eligible.sort(key=lambda x: krx_data[x[0]].get("market_cap", 0), reverse=True)

    log(f"  📋 대상 종목: {len(eligible)}개 (시총 3000억+)")

    # 기업개요 병렬 크롤링
    from concurrent.futures import ThreadPoolExecutor, as_completed

    stock_infos = {}
    done_count = [0]

    def _fetch_one(item):
        code, name, market = item
        sector, overview = _fetch_company_overview(code)
        return code, name, market, sector, overview

    log(f"  ⏳ 기업개요 병렬 크롤링 중 (스레드 20개)...")
    with ThreadPoolExecutor(max_workers=20) as executor:
        futures = {executor.submit(_fetch_one, item): item for item in eligible}
        for future in as_completed(futures):
            try:
                code, name, market, sector, overview = future.result()
                stock_infos[code] = {
                    "name": name, "market": market,
                    "sector": sector, "overview": overview[:500],
                }
                done_count[0] += 1
                if done_count[0] % 200 == 0:
                    log(f"     ... {done_count[0]}/{len(eligible)} 기업개요 수집")
            except Exception:
                pass

    log(f"  ✅ 기업개요 수집 완료: {len(stock_infos)}개")

    # ── 룰 기반 테마 분류 ──
    stock_themes = {}
    for code, info in stock_infos.items():
        themes = set()
        sector = info.get("sector", "")
        overview = info.get("overview", "")

        # 1) 업종명 매핑 (정확히 일치하는 항목)
        if sector in SECTOR_TO_THEME:
            themes.add(SECTOR_TO_THEME[sector])

        # 2) 기업개요 키워드 매핑 (공백 무시)
        overview_nospace = overview.replace(" ", "")
        for keyword, theme in KEYWORD_TO_THEME.items():
            if keyword in overview_nospace:
                themes.add(theme)

        # 3) 짧은 영문 키워드 정규식 매칭 (EV, GPU 등)
        for pattern, theme in SHORT_KEYWORD_PATTERNS:
            if pattern.search(overview):
                themes.add(theme)

        if themes:
            stock_themes[code] = list(themes)

    log(f"  ✅ 테마 분류 완료: {len(stock_themes)}개 종목 (룰 기반)")

    # 테마 → 종목 역매핑
    theme_to_stocks = {}
    for code, themes_list in stock_themes.items():
        info = stock_infos.get(code, {})
        for theme in themes_list:
            if theme not in theme_to_stocks:
                theme_to_stocks[theme] = []
            theme_to_stocks[theme].append({
                "code": code, "name": info.get("name", ""),
                "market": info.get("market", ""),
            })

    # JSON 저장
    cache_data = {
        "date": TODAY,
        "stocks": stock_themes,
        "theme_to_stocks": theme_to_stocks,
    }
    try:
        with open(THEME_MAP_FILE, "w", encoding="utf-8") as f:
            json.dump(cache_data, f, ensure_ascii=False, indent=2)
        log(f"  💾 테마 매핑 DB 저장: {THEME_MAP_FILE}")
    except Exception as e:
        log(f"  ⚠️ 매핑 DB 저장 실패: {e}")

    for theme, stocks in sorted(theme_to_stocks.items(), key=lambda x: -len(x[1]))[:15]:
        names = ", ".join(s["name"] for s in stocks[:5])
        log(f"     {theme}({len(stocks)}개): {names}...")

    return theme_to_stocks, stock_themes


# ─────────────────────────────────────────
# 규칙 기반 테마 감지 (뉴스 키워드 매칭)
# ─────────────────────────────────────────
# 뉴스 헤드라인 → 테마 매칭 키워드
NEWS_THEME_KEYWORDS = {
    "반도체": ["반도체", "HBM", "메모리", "파운드리", "삼성전자", "SK하이닉스", "DRAM", "낸드", "NAND", "D램"],
    "2차전지": ["2차전지", "배터리", "리튬", "양극재", "음극재", "에코프로", "LG에너지", "전고체"],
    "전기차": ["전기차", "EV", "테슬라", "자율주행", "전기자동차"],
    "자동차": ["자동차", "현대차", "기아", "완성차"],
    "방산": ["방산", "방위", "무기", "미사일", "K방산", "한화에어로", "LIG넥스원", "K9"],
    "조선": ["조선", "선박", "LNG선", "HD한국조선", "한화오션", "수주"],
    "AI": ["AI", "인공지능", "ChatGPT", "딥러닝", "생성형", "GPU", "엔비디아", "LLM", "챗봇"],
    "로봇": ["로봇", "휴머노이드", "로보틱스", "코봇"],
    "제약/바이오": ["바이오", "제약", "신약", "임상", "셀트리온", "삼성바이오", "FDA", "치료제"],
    "전력/에너지": ["전력", "변압기", "송전", "전력망", "그리드", "한전"],
    "금융": ["금융", "은행", "보험", "증권", "금리", "기준금리"],
    "건설": ["건설", "아파트", "부동산", "분양", "재건축", "재개발"],
    "통신": ["통신", "5G", "6G", "KT", "SKT", "LGU+"],
    "철강/소재": ["철강", "포스코", "비철금속", "알루미늄"],
    "화학": ["화학", "석유화학", "정밀화학"],
    "IT/플랫폼": ["네이버", "카카오", "플랫폼", "IT기업"],
    "게임": ["게임", "넥슨", "크래프톤", "엔씨소프트", "넷마블"],
    "디스플레이": ["디스플레이", "OLED", "LCD", "LG디스플레이", "패널"],
    "화장품": ["화장품", "뷰티", "K뷰티", "K-뷰티", "아모레"],
    "식품": ["식품", "음식", "음료", "CJ제일제당"],
    "엔터": ["엔터", "K-POP", "KPOP", "아이돌", "콘서트", "공연", "하이브", "SM"],
    "원전": ["원전", "원자력", "SMR", "소형모듈원자로", "핵발전"],
    "태양광": ["태양광", "태양전지", "솔라", "한화솔루션"],
    "수소": ["수소", "연료전지", "수소차", "수전해"],
    "드론": ["드론", "UAM", "무인항공", "도심항공"],
    "항공": ["항공", "대한항공", "아시아나", "저비용항공"],
    "물류": ["물류", "택배", "해운", "CJ대한통운"],
    "해운": ["해운", "HMM", "컨테이너선", "벌크선"],
    "의료기기": ["의료기기", "진단", "의료장비"],
    "패션": ["패션", "의류", "브랜드"],
    "유통": ["유통", "백화점", "이커머스", "쿠팡"],
    "전자부품": ["전자부품", "MLCC", "PCB", "커넥터"],
    "석유/가스": ["원유", "석유", "가스", "유가", "정유"],
}


def detect_themes_rule_based(news_titles, theme_map=None):
    """뉴스 헤드라인 키워드 매칭으로 핫 테마 선정 (AI 불필요)"""
    if not news_titles:
        log("  ⚠️ 뉴스 데이터 없음 - 정적 테마 사용")
        return None

    if not theme_map:
        log("  ⚠️ 매핑 DB 없음 - 정적 테마 사용")
        return None

    # 뉴스 헤드라인에서 테마별 언급 빈도 계산
    theme_scores = {}
    for title in news_titles:
        matched_themes = set()
        for theme, keywords in NEWS_THEME_KEYWORDS.items():
            for kw in keywords:
                if kw in title:
                    matched_themes.add(theme)
                    break
        for theme in matched_themes:
            theme_scores[theme] = theme_scores.get(theme, 0) + 1

    # theme_map에 존재하는 테마만 필터 (유사 이름 매칭 포함)
    valid_scores = {}
    for theme, score in theme_scores.items():
        if theme in theme_map:
            valid_scores[theme] = valid_scores.get(theme, 0) + score
        else:
            for map_key in theme_map:
                if theme in map_key or map_key in theme:
                    valid_scores[map_key] = valid_scores.get(map_key, 0) + score
                    break

    # 뉴스에 언급 안 된 테마도 종목 수 기반으로 최소 점수 부여 (10개 미만일 때 보충)
    if len(valid_scores) < 10:
        for map_key in theme_map:
            if map_key not in valid_scores:
                valid_scores[map_key] = 0

    # 1차: 뉴스 점수 순, 2차: 종목 수 순 (동점 시)
    sorted_themes = sorted(
        valid_scores.items(),
        key=lambda x: (x[1], len(theme_map.get(x[0], []))),
        reverse=True,
    )[:10]

    result = []
    for theme_name, score in sorted_themes:
        stocks = theme_map.get(theme_name, [])[:10]
        if len(stocks) >= 3:
            result.append({
                "name": theme_name,
                "search_query": theme_name + " 주식",
                "stocks": stocks,
            })

    if result:
        total_stocks = sum(len(t["stocks"]) for t in result)
        log(f"  🔍 규칙 기반 테마 감지: {len(result)}개 테마, {total_stocks}개 종목")
        for t in result:
            score = valid_scores.get(t["name"], 0)
            names = ", ".join(s["name"] for s in t["stocks"][:3])
            log(f"     - {t['name']} (뉴스 {score}건): {names}...")
        return result
    else:
        log("  ⚠️ 규칙 기반 매칭 실패")
        return None


# ─────────────────────────────────────────
# AI 테마 감지 (Groq / Llama 3.3 70B) — 주 1회
# ─────────────────────────────────────────
AI_THEME_CACHE_FILE = "ai_themes_cache.json"


def _should_run_ai_themes():
    """캐시 파일을 확인하여 AI 테마 감지를 실행할지 결정 (7일 경과 시 실행)"""
    if not GROQ_API_KEY:
        return False
    try:
        with open(AI_THEME_CACHE_FILE, "r", encoding="utf-8") as f:
            cache = json.load(f)
        cached_date = cache.get("date", "")
        if cached_date:
            from datetime import datetime as _dt
            diff = (_dt.strptime(TODAY, "%Y-%m-%d") - _dt.strptime(cached_date, "%Y-%m-%d")).days
            if diff < 7:
                log(f"  ℹ️ AI 테마 캐시 유효 ({cached_date}, {diff}일 경과) - 규칙 기반 사용")
                return False
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        pass
    return True


def _save_ai_theme_cache(theme_names):
    """AI 테마 결과를 캐시 파일에 저장"""
    try:
        with open(AI_THEME_CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({"date": TODAY, "themes": theme_names}, f, ensure_ascii=False)
        log(f"  💾 AI 테마 캐시 저장: {AI_THEME_CACHE_FILE}")
    except Exception as e:
        log(f"  ⚠️ AI 테마 캐시 저장 실패: {e}")


def detect_themes_with_ai(news_titles, theme_map=None):
    """Groq AI로 핫 테마 선정 → 매핑 DB에서 종목 조회 (주 1회)"""
    if not news_titles or not theme_map:
        return None

    available_themes = list(theme_map.keys())
    themes_list_text = ", ".join(available_themes)
    news_text = "\n".join(f"- {t}" for t in news_titles[:30])

    prompt = f"""너는 국내 증시 테마 분석가다.

## 목표:
아래 뉴스 헤드라인을 분석하여 현재 증시에서 가장 주목받는 테마 상위 10개를 선정하라.
종목은 선정하지 마라. 테마명만 선정하면 된다.

## 오늘의 뉴스 헤드라인:
{news_text}

## 사용 가능한 테마 목록:
{themes_list_text}

## 출력 형식 (JSON):
{{
  "themes": [
    {{"name": "테마명", "search_query": "테마명 주식"}},
    {{"name": "테마명2", "search_query": "테마명2 주식"}}
  ]
}}

## 규칙:
1. 위 테마 목록에서만 선택. 목록에 없는 테마는 사용 금지
2. 뉴스에서 가장 화제인 테마 우선
3. search_query는 네이버 뉴스 검색용 키워드 (테마명 + "주식")
4. 정확히 10개 선정
5. 뉴스와 무관한 테마를 넣지 마라"""

    try:
        resp = requests.post(
            "https://api.groq.com/openai/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {GROQ_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": "llama-3.3-70b-versatile",
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.3,
                "response_format": {"type": "json_object"},
            },
            timeout=30,
        )

        if resp.status_code != 200:
            log(f"  ⚠️ Groq API 오류: {resp.status_code} - {resp.text[:200]}")
            return None

        result = resp.json()
        content = result["choices"][0]["message"]["content"]
        parsed = json.loads(content)

        if isinstance(parsed, dict):
            raw_themes = None
            for key in parsed:
                if isinstance(parsed[key], list):
                    raw_themes = parsed[key]
                    break
            if raw_themes is None:
                raw_themes = [parsed]
        else:
            raw_themes = parsed

        validated = []
        for theme in raw_themes:
            if not isinstance(theme, dict) or "name" not in theme:
                continue
            theme_name = theme["name"].strip()
            search_query = theme.get("search_query", theme_name + " 주식")

            stocks = []
            if theme_name in theme_map:
                stocks = theme_map[theme_name][:10]
            else:
                for map_key in theme_map:
                    if theme_name in map_key or map_key in theme_name:
                        stocks = theme_map[map_key][:10]
                        break

            if len(stocks) >= 3:
                validated.append({
                    "name": theme_name,
                    "search_query": search_query,
                    "stocks": stocks[:10],
                })

        if validated:
            total_stocks = sum(len(t["stocks"]) for t in validated)
            log(f"  🤖 AI 테마 감지 완료: {len(validated)}개 테마, {total_stocks}개 종목")
            for t in validated:
                names = ", ".join(s["name"] for s in t["stocks"][:3])
                log(f"     - {t['name']}: {names}...")
            # 캐시 저장
            _save_ai_theme_cache([t["name"] for t in validated])
            return validated[:10]
        else:
            return None

    except Exception as e:
        log(f"  ⚠️ AI 테마 감지 실패: {e}")
        return None


def generate_ai_summary(indices, stocks, sectors, themes, news):
    """Groq AI로 시장 브리핑 생성 (매 크롤링 시 1회)"""
    if not GROQ_API_KEY:
        log("  ⚠️ GROQ_API_KEY 미설정 - AI 요약 건너뜀")
        return None

    # 컨텍스트 구성 (풍부한 데이터 제공)
    idx_text = "\n".join(
        f"- {m['name']}: {m['value']} ({m['change_pct']})" for m in (indices or [])
    )
    stk_text = "\n".join(
        f"- {s['name']}({s['code']}): {s['price']}원, {s['change_pct']}, 거래대금 {s.get('volume','N/A')}, 사유: {s.get('reason','N/A')}"
        for s in (stocks or [])[:10]
    )
    # 상승/하락 섹터 분리
    up_sectors = [s for s in (sectors or []) if s.get("trend") == "up"]
    down_sectors = [s for s in (sectors or []) if s.get("trend") == "down"]
    sec_text = "상승 섹터: " + ", ".join(f"{s['name']}({s['change_pct']})" for s in up_sectors)
    sec_text += "\n하락 섹터: " + ", ".join(f"{s['name']}({s['change_pct']})" for s in down_sectors)
    thm_text = "\n".join(
        f"- {t['name']}: {t['change_pct']}, 대장주: {t.get('leading_stocks','N/A')}"
        for t in (themes or [])[:5]
    )
    news_text = "\n".join(
        f"- {n['title']} ({n.get('source','')}, {n.get('time_ago','')})"
        for n in (news or [])[:15]
    )

    from datetime import datetime, timezone, timedelta
    kst = timezone(timedelta(hours=9))
    now_kst = datetime.now(kst)
    now_str = now_kst.strftime("%Y-%m-%d %H:%M")

    prompt = f"""너는 매크로 전략가다.
기준 시각: {now_str}

아래 시장 데이터를 기반으로 시장을 분석하되, 반드시 지정된 구조를 따라라.

## 시장 데이터:

[지수]
{idx_text}

[이슈 종목]
{stk_text}

[섹터]
{sec_text}

[인기 테마]
{thm_text}

[뉴스]
{news_text}

## 분석 구조 (6개 섹션, 반드시 이 순서와 번호를 따를 것):

1) 핵심 촉발 요인
- 오늘 시장을 움직이는 팩트 3가지를 뉴스 헤드라인에서 뽑아 서술
- 각 팩트가 시장에 미치는 영향을 구체적으로 연결
- 3~4문장

2) 자금 흐름 방향
- Risk-On(위험자산 선호) 또는 Risk-Off(위험자산 회피) 판단
- 판단 근거를 지수·환율·종목 데이터에서 뽑아 제시
- 2~3문장

3) 금리·달러·유가 영향 연결
- 환율(USD/KRW)과 글로벌 지수 흐름이 한국 시장에 미치는 영향
- 원인 → 결과를 화살표(→)로 연결
- 2~3문장

4) 섹터별 강약 구조
- ↗ 강세 섹터와 그 이유 (뉴스·테마와 연결)
- ↘ 약세 섹터와 그 이유 (뉴스·종목과 연결)
- 개별 종목을 섹터 전체와 혼동하지 말 것
- 3~4문장

5) 단기 시나리오 2개
- 상승 시나리오: 어떤 조건이 충족되면 반등 가능한지
- 하락 시나리오: 어떤 리스크가 현실화되면 추가 하락인지
- 각 1~2문장

6) 한 줄 결론
- 오늘 시장을 한 문장으로 요약 (핵심 키워드 포함)

## 절대 규칙:
- 한글과 숫자만 사용 (한자/일본어/중국어 금지)
- 감정적 표현 금지. 객관적·분석적 톤 유지
- 뉴스 단순 나열 금지. 반드시 '원인 → 자금 → 섹터 → 전략' 구조로 작성
- "~입니다" 존댓말 금지. "~다/~했다" 간결체 사용
- 같은 내용 반복 금지
- 섹션 간 논리적 모순 금지
- 근거 없는 추측 금지. 뉴스 데이터에서 근거를 찾을 것
- 숫자는 데이터 그대로 인용
- 총 1000~1500자 분량

## 나쁜 예시 (절대 금지):
❌ "상승 섹터로는 2차전지와 철강 섹터가 있습니다"
❌ "오늘 시장의 핵심은 리스크 오프 심리입니다"
→ 단순 나열, 수치만 읽기, 뻔한 서술

## 좋은 예시:
✅ "2차전지 섹터는 유럽 전기차 보조금 확대 뉴스에 LG에너지솔루션(+3.2%)을 필두로 반등했다"
✅ "원/달러 1,460원 돌파 → 외국인 자금 이탈 가속 → 코스피 하방 압력 확대"
✅ "상승 조건: 미중 무역협상 진전 시그널 + 외국인 순매수 전환"

## 출력 형식 (JSON):
{{
  "summary": "시장 브리핑 전문 (섹션 번호와 제목 포함, 줄바꿈으로 구분)",
  "market_mood": "bullish 또는 bearish 또는 neutral"
}}

market_mood 판단: 코스피·코스닥 모두 상승이면 bullish, 모두 하락이면 bearish, 혼조면 neutral"""

    try:
        resp = requests.post(
            "https://api.groq.com/openai/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {GROQ_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": "llama-3.3-70b-versatile",
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.4,
                "max_tokens": 2048,
                "response_format": {"type": "json_object"},
            },
            timeout=60,
        )

        if resp.status_code != 200:
            log(f"  ⚠️ Groq AI 요약 오류: {resp.status_code} - {resp.text[:200]}")
            return None

        result = resp.json()
        content = result["choices"][0]["message"]["content"]
        parsed = json.loads(content)

        summary = parsed.get("summary", "")
        mood = parsed.get("market_mood", "neutral")
        if mood not in ("bullish", "bearish", "neutral"):
            mood = "neutral"

        if summary:
            log(f"  🤖 AI 시장 브리핑 생성 완료 (mood: {mood}, {len(summary)}자)")
            generated_time = now_kst.strftime("%H:%M")
            return {"summary": summary, "market_mood": mood, "date": TODAY, "generated_time": generated_time}
        return None

    except Exception as e:
        log(f"  ⚠️ AI 요약 생성 실패: {e}")
        return None


# ─────────────────────────────────────────
# 1. 뉴스 수집 (네이버 검색 API)
# ─────────────────────────────────────────
def crawl_news():
    """네이버 검색 API로 증시 뉴스 수집"""
    log("📰 뉴스 크롤링 시작...")

    if not NAVER_CLIENT_ID or not NAVER_CLIENT_SECRET:
        log("  ⚠️ NAVER_CLIENT_ID/SECRET 미설정 - 뉴스 수집 건너뜀")
        return []

    news_list = []
    seen_titles = set()
    queries = ["증시", "주식시장", "코스피"]

    for query in queries:
        if len(news_list) >= 15:
            break
        try:
            url = "https://openapi.naver.com/v1/search/news.json"
            params = {"query": query, "display": 15, "sort": "date"}
            headers = {
                "X-Naver-Client-Id": NAVER_CLIENT_ID,
                "X-Naver-Client-Secret": NAVER_CLIENT_SECRET,
            }
            resp = requests.get(url, headers=headers, params=params, timeout=10)
            data = resp.json()

            for item in data.get("items", []):
                title = html.unescape(re.sub(r'<[^>]+>', '', item.get("title", ""))).strip()
                if not title or title in seen_titles:
                    continue
                seen_titles.add(title)

                description = html.unescape(re.sub(r'<[^>]+>', '', item.get("description", ""))).strip()

                source_name = "뉴스"
                try:
                    domain = urllib.parse.urlparse(item.get("originallink", "")).netloc
                    source_name = domain.replace("www.", "").split(".")[0]
                except:
                    pass

                time_ago = _calc_time_ago(item.get("pubDate", ""))

                news_list.append({
                    "title": title,
                    "source": source_name or "뉴스",
                    "time_ago": time_ago,
                    "category": classify_news_category(title),
                    "sentiment": analyze_sentiment(title),
                    "summary": description[:500] if description else title,
                    "url": item.get("link", ""),
                    "date": TODAY,
                })

                if len(news_list) >= 15:
                    break
        except Exception as e:
            log(f"  ⚠️ 뉴스 검색 실패 ({query}): {e}")

    log(f"  ✅ 뉴스 {len(news_list)}개 수집 완료")
    return news_list


def fetch_stock_news(stock_name, max_count=3):
    """특정 종목의 관련 뉴스를 네이버 검색 API로 조회"""
    if not NAVER_CLIENT_ID or not NAVER_CLIENT_SECRET:
        return []
    try:
        url = "https://openapi.naver.com/v1/search/news.json"
        params = {"query": f"{stock_name} 주가", "display": 5, "sort": "date"}
        headers = {
            "X-Naver-Client-Id": NAVER_CLIENT_ID,
            "X-Naver-Client-Secret": NAVER_CLIENT_SECRET,
        }
        resp = requests.get(url, headers=headers, params=params, timeout=5)
        data = resp.json()
        results = []
        for item in data.get("items", []):
            title = html.unescape(re.sub(r'<[^>]+>', '', item.get("title", ""))).strip()
            if not title:
                continue
            source_name = "뉴스"
            try:
                domain = urllib.parse.urlparse(item.get("originallink", "")).netloc
                source_name = domain.replace("www.", "").split(".")[0]
            except:
                pass
            results.append({
                "title": title,
                "source": source_name or "뉴스",
                "time_ago": _calc_time_ago(item.get("pubDate", "")),
                "url": item.get("link", ""),
            })
            if len(results) >= max_count:
                break
        return results
    except Exception as e:
        log(f"  ⚠️ {stock_name} 관련 뉴스 조회 실패: {e}")
        return []


# ─────────────────────────────────────────
# 2. 이슈 종목 (KRX 거래대금 상위)
# ─────────────────────────────────────────
def crawl_issue_stocks(krx_data, themes=None, sectors=None, news=None):
    """복합 점수 기반 이슈 종목 선정 (거래대금+등락률+테마+뉴스+섹터)"""
    log("📈 이슈 종목 크롤링 시작...")

    # ── 1단계: 후보 필터링 (거래대금 1000억 이상, ETF 제외) ──
    MIN_TRADING_VALUE = 100_000_000_000  # 1000억 원
    LIMIT_PCT = 29.5  # 상한가/하한가 기준 (±29.5% 이상)
    candidates = []
    for code, d in krx_data.items():
        if d["volume"] == 0 or d["price"] == 0:
            continue
        if is_etf_etn(d["name"]):
            continue
        if d["trading_value"] >= MIN_TRADING_VALUE:
            candidates.append(d)

    if not candidates:
        # fallback: 거래대금 상위 50개
        all_stocks = [d for d in krx_data.values() if d["volume"] > 0 and d["price"] > 0 and not is_etf_etn(d["name"])]
        all_stocks.sort(key=lambda x: x["trading_value"], reverse=True)
        candidates = all_stocks[:50]

    limit_count = sum(1 for d in candidates if abs(d["change_pct"]) >= LIMIT_PCT)
    log(f"  📋 후보 종목: {len(candidates)}개 (거래대금 1000억+, 상한가/하한가 {limit_count}개)")

    # ── 2단계: 보조 데이터 구축 ──
    # 인기 테마 소속 종목 코드 → 테마명 매핑
    theme_stock_codes = set()
    stock_theme_names = {}  # code → [테마명, ...]
    if themes:
        for t in themes:
            tname = t.get("name", "")
            ls = t.get("leading_stocks", "")
            for part in ls.split(","):
                parts = part.strip().split(":")
                if len(parts) >= 2 and parts[1].strip().isdigit():
                    code = parts[1].strip()
                    theme_stock_codes.add(code)
                    if code not in stock_theme_names:
                        stock_theme_names[code] = []
                    if tname and tname not in stock_theme_names[code]:
                        stock_theme_names[code].append(tname)

    # 상승 섹터 이름 세트
    rising_sectors = set()
    if sectors:
        for s in sectors:
            if s.get("trend") == "up":
                rising_sectors.add(s.get("name", ""))

    # 뉴스 제목에서 종목명 언급 횟수
    news_mention_count = {}
    if news:
        news_titles = " ".join(n.get("title", "") for n in news)
        for d in candidates:
            name = d["name"]
            # 2글자 이상 종목명만 매칭 (오탐 방지)
            if len(name) >= 2 and name in news_titles:
                news_mention_count[d["code"]] = news_titles.count(name)

    # ── 3단계: 종합 점수 계산 ──
    # 거래대금 순위 점수 (정규화)
    candidates.sort(key=lambda x: x["trading_value"], reverse=True)
    max_tv_rank = len(candidates)
    tv_rank_map = {d["code"]: i for i, d in enumerate(candidates)}

    # 등락률 절대값 순위
    candidates_by_change = sorted(candidates, key=lambda x: abs(x["change_pct"]), reverse=True)
    change_rank_map = {d["code"]: i for i, d in enumerate(candidates_by_change)}

    scored = []
    for d in candidates:
        code = d["code"]
        n = max_tv_rank if max_tv_rank > 0 else 1

        # 거래대금 점수 (25점) — 순위가 높을수록 점수 높음
        tv_score = (1 - tv_rank_map[code] / n) * 25

        # 등락률 점수 (25점) — 절대값 순위
        change_score = (1 - change_rank_map[code] / n) * 25

        # 인기 테마 소속 (20점) — 소속이면 20점
        theme_score = 20 if code in theme_stock_codes else 0

        # 뉴스 언급 (20점) — 언급 횟수에 따라
        mentions = news_mention_count.get(code, 0)
        news_score = min(mentions * 10, 20)  # 1회=10점, 2회+=20점

        # 상승 섹터 소속 (10점)
        sector_score = 10 if d.get("display_sector", "") in rising_sectors else 0

        total = tv_score + change_score + theme_score + news_score + sector_score

        # 선정 사유 생성
        reasons = []
        cp = d["change_pct"]
        if abs(cp) >= LIMIT_PCT:
            reasons.append("상한가" if cp > 0 else "하한가")
        if theme_score > 0:
            reasons.append("인기테마")
        if news_score > 0:
            reasons.append("뉴스언급")
        if abs(cp) < LIMIT_PCT and change_score >= 20:
            reasons.append("급등" if cp > 0 else "급락")
        if tv_score >= 20:
            reasons.append("거래폭발")
        if sector_score > 0:
            reasons.append("상승섹터")
        reason_str = " · ".join(reasons) if reasons else "거래대금 상위"

        scored.append((total, d, reason_str))

    # ── 4단계: 랭킹 ──
    scored.sort(key=lambda x: x[0], reverse=True)

    stocks = []
    for rank_idx, (score, d, reason_str) in enumerate(scored[:15], 1):
        cp = d["change_pct"]
        if cp > 0.005:
            trend, pct_str = "up", f"+{cp:.2f}%"
        elif cp < -0.005:
            trend, pct_str = "down", f"{cp:.2f}%"
        else:
            trend, pct_str = "flat", "0.00%"

        try:
            price_formatted = f"{d['price']:,}"
        except:
            price_formatted = str(d["price"])

        trading_value_eok = d["trading_value"] / 100_000_000
        volume_str = format_trading_value(str(int(trading_value_eok)))

        stocks.append({
            "rank": rank_idx,
            "name": d["name"],
            "code": d["code"],
            "price": price_formatted,
            "change_pct": pct_str,
            "volume": volume_str,
            "reason": reason_str,
            "tags": classify_stock_tags(d["name"], d.get("display_sector", ""), stock_theme_names.get(d["code"])),
            "trend": trend,
            "date": TODAY,
        })

    # ── 5단계: 종목별 관련 뉴스 수집 ──
    log("  📰 종목별 관련 뉴스 수집 중...")
    for s in stocks:
        name = s["name"]
        matched = []

        # 1) 기존 뉴스 목록에서 매칭 (제목 또는 요약에 종목명 포함)
        if news:
            for n in news:
                title_text = n.get("title", "")
                summary_text = n.get("summary", "")
                if len(name) >= 2 and name in (title_text + " " + summary_text):
                    matched.append({
                        "title": n["title"],
                        "source": n.get("source", "뉴스"),
                        "time_ago": n.get("time_ago", ""),
                        "url": n.get("url", ""),
                    })
                    if len(matched) >= 3:
                        break

        # 2) 부족하면 네이버 뉴스 API로 종목 전용 검색
        if len(matched) < 3:
            extra = fetch_stock_news(name, 3 - len(matched))
            matched.extend(extra)

        s["related_news"] = json.dumps(matched[:5], ensure_ascii=False)

    log(f"  ✅ 이슈 종목 {len(stocks)}개 선정 (복합 점수 기반)")
    for s in stocks[:5]:
        news_cnt = len(json.loads(s["related_news"])) if s.get("related_news") else 0
        log(f"     {s['rank']}. {s['name']} ({s['change_pct']}) — {s['reason']} [뉴스 {news_cnt}건]")
    return stocks


# ─────────────────────────────────────────
# 3. 시장 지수 (Yahoo Finance API)
# ─────────────────────────────────────────
def crawl_market_index():
    """Yahoo Finance API로 시장 지수 + 환율 조회"""
    log("📊 시장 지수 크롤링 시작...")

    indices = []

    index_symbols = [
        ("코스피",   "^KS11",    "5m"),
        ("코스닥",   "^KQ11",    "5m"),
        ("다우존스", "^DJI",     "5m"),
        ("나스닥",   "^IXIC",    "5m"),
        ("S&P 500",  "^GSPC",    "5m"),
        ("USD/KRW",  "USDKRW=X", "5m"),
    ]

    for name, symbol, interval in index_symbols:
        try:
            price, prev, sparkline = fetch_yahoo_chart(symbol, interval)

            if prev and prev > 0:
                change = round(price - prev, 2)
                pct = round((change / prev) * 100, 2)
                trend = "down" if change < 0 else ("flat" if change == 0 else "up")

                indices.append({
                    "name": name,
                    "value": f"{price:,.2f}",
                    "change_amount": f"{change:+,.2f}",
                    "change_pct": f"{pct:+.2f}%",
                    "trend": trend,
                    "sparkline_data": {"v": sparkline},
                })
            else:
                indices.append({
                    "name": name,
                    "value": f"{price:,.2f}",
                    "change_amount": "0",
                    "change_pct": "0.00%",
                    "trend": "up",
                    "sparkline_data": {"v": sparkline},
                })
            log(f"  ✅ {name}: {price:,.2f} (스파크라인 {len(sparkline)}포인트)")
        except Exception as ex:
            log(f"  ⚠️ {name} ({symbol}) 조회 실패: {ex}")

    log(f"  ✅ 시장 지수 {len(indices)}개 수집 완료")
    return indices


# ─────────────────────────────────────────
# 4. 섹터 데이터 (KRX 업종 기반)
# ─────────────────────────────────────────
def crawl_sectors(krx_data):
    """KRX 데이터에서 섹터별 등락률 계산"""
    log("🏭 섹터 데이터 크롤링 시작...")

    sector_stats = {}
    for code, d in krx_data.items():
        sector = d["display_sector"]
        if not sector or sector not in SECTOR_ICONS:
            continue
        if d["price"] == 0 or is_etf_etn(d["name"]):
            continue

        if sector not in sector_stats:
            sector_stats[sector] = {"changes": [], "stocks": []}
        sector_stats[sector]["changes"].append(d["change_pct"])
        sector_stats[sector]["stocks"].append(d)

    sectors = []
    for sname, icon in SECTOR_ICONS.items():
        stats = sector_stats.get(sname, {"changes": [], "stocks": []})

        if stats["changes"]:
            avg_pct = sum(stats["changes"]) / len(stats["changes"])
        else:
            avg_pct = 0.0

        if avg_pct > 0.005:
            trend = "up"
            pct_str = f"+{avg_pct:.2f}%"
        elif avg_pct < -0.005:
            trend = "down"
            pct_str = f"{avg_pct:.2f}%"
        else:
            trend = "flat"
            pct_str = "0.00%"

        # 상승률 최고 종목
        top_stock = ""
        best_pct = -999
        for s in stats["stocks"]:
            if s["change_pct"] > best_pct:
                best_pct = s["change_pct"]
                top_stock = s["name"]

        sectors.append({
            "name": sname,
            "change_pct": pct_str,
            "trend": trend,
            "stock_count": len(stats["changes"]),
            "icon": icon,
            "top_stock": top_stock,
            "description": "",
        })

    log(f"  ✅ 섹터 {len(sectors)}개 수집 완료")
    return sectors


# ─────────────────────────────────────────
# 5. 섹터별 종목 (KRX 시가총액 기반)
# ─────────────────────────────────────────
def crawl_sector_stocks(krx_data):
    """KRX 데이터에서 섹터별 종목 목록 생성 (시가총액 상위)"""
    log("🏷️ 섹터별 종목 크롤링 시작...")

    # 섹터별 그룹핑
    sector_groups = {}
    for code, d in krx_data.items():
        sector = d["display_sector"]
        if not sector or sector not in SECTOR_ICONS:
            continue
        if d["price"] == 0 or is_etf_etn(d["name"]):
            continue
        if sector not in sector_groups:
            sector_groups[sector] = []
        sector_groups[sector].append(d)

    all_stocks = []
    for sector_name in SECTOR_ICONS.keys():
        stocks_in_sector = sector_groups.get(sector_name, [])
        # 시가총액 순 정렬
        stocks_in_sector.sort(key=lambda x: x["market_cap"], reverse=True)

        for rank_idx, d in enumerate(stocks_in_sector[:10], 1):
            cp = d["change_pct"]

            if cp > 0.005:
                trend = "up"
                pct_str = f"+{cp:.2f}%"
            elif cp < -0.005:
                trend = "down"
                pct_str = f"{cp:.2f}%"
            else:
                trend = "flat"
                pct_str = "0.00%"

            try:
                price_formatted = f"{d['price']:,}"
            except:
                price_formatted = str(d["price"])

            all_stocks.append({
                "sector_name": sector_name,
                "stock_name": d["name"],
                "code": d["code"],
                "price": price_formatted,
                "change_pct": pct_str,
                "trend": trend,
                "rank": rank_idx,
            })

        log(f"  ✅ {sector_name}: {min(len(stocks_in_sector), 10)}개 종목 수집")

    log(f"  ✅ 섹터별 종목 총 {len(all_stocks)}개 수집 완료")
    return all_stocks


# ─────────────────────────────────────────
# 6. 테마 (AI 동적 감지 + KRX + 네이버 검색 API)
# ─────────────────────────────────────────
def crawl_themes(krx_data, news_titles=None, theme_map=None):
    """AI가 선정한 테마의 종목을 KRX 데이터에서 조회하여 성과 계산"""
    log("🔥 테마 크롤링 시작...")

    # 주 1회: Groq AI로 테마 감지 / 나머지: 규칙 기반 키워드 매칭
    if _should_run_ai_themes():
        log("  🤖 AI 테마 감지 실행 (주 1회)")
        ai_themes = detect_themes_with_ai(news_titles, theme_map)
        if not ai_themes:
            log("  ↩️ AI 실패 → 규칙 기반 폴백")
            ai_themes = detect_themes_rule_based(news_titles, theme_map)
    else:
        ai_themes = detect_themes_rule_based(news_titles, theme_map)

    if ai_themes:
        # ── AI 테마: KRX 데이터에서 직접 가격 조회 ──
        # (종목은 매핑 DB에서 시총 3000억+ 필터 적용 완료)
        themes = []
        for theme_def in ai_themes:
            theme_stocks = []
            changes = []
            seen_codes = set()

            for s in theme_def["stocks"]:
                code = s["code"]
                if code in seen_codes:
                    continue
                seen_codes.add(code)

                d = krx_data.get(code)
                if not d:
                    continue

                cp = d["change_pct"]
                changes.append(cp)
                theme_stocks.append({"name": d["name"], "code": code, "change_pct": cp})

            if len(theme_stocks) < 3:
                log(f"  ⏭️ 종목 부족으로 테마 스킵: {theme_def['name']} ({len(theme_stocks)}개)")
                continue

            avg_change = sum(changes) / len(changes) if changes else 0.0
            up_count = sum(1 for c in changes if c > 0.005)
            down_count = sum(1 for c in changes if c < -0.005)
            flat_count = len(changes) - up_count - down_count

            if avg_change > 0.005:
                trend, pct_str = "up", f"+{avg_change:.2f}%"
            elif avg_change < -0.005:
                trend, pct_str = "down", f"{avg_change:.2f}%"
            else:
                trend, pct_str = "flat", "0.00%"

            theme_stocks.sort(key=lambda x: abs(x["change_pct"]), reverse=True)
            leaders = []
            for ts in theme_stocks[:10]:
                cp = ts["change_pct"]
                pct_display = f"+{cp:.2f}%" if cp >= 0 else f"{cp:.2f}%"
                leaders.append(f"{ts['name']}:{ts['code']}:{pct_display}")

            # 네이버 뉴스 검색
            search_kw = theme_def.get("search_query", theme_def["name"] + " 주식")
            news_title, news_url, news_list_json = _search_theme_news_api(search_kw, theme_def["name"])

            themes.append({
                "rank": 0, "name": theme_def["name"], "change_pct": pct_str,
                "avg_3day_pct": "", "up_count": up_count, "flat_count": flat_count,
                "down_count": down_count, "leading_stocks": ", ".join(leaders),
                "related_news": news_title, "news_url": news_url,
                "news_list": news_list_json,
                "trend": trend, "date": TODAY,
            })

    else:
        # ── Fallback: 정적 THEME_DEFINITIONS (KRX 데이터 기반) ──
        log("  📋 정적 테마 정의 사용")
        themes = []
        for theme_def in THEME_DEFINITIONS:
            theme_stocks = []
            changes = []
            for code in theme_def["stocks"]:
                d = krx_data.get(code)
                if not d:
                    continue
                cp = d["change_pct"]
                changes.append(cp)
                theme_stocks.append({"name": d["name"], "code": code, "change_pct": cp})

            avg_change = sum(changes) / len(changes) if changes else 0.0
            up_count = sum(1 for c in changes if c > 0.005)
            down_count = sum(1 for c in changes if c < -0.005)
            flat_count = len(changes) - up_count - down_count

            if avg_change > 0.005:
                trend, pct_str = "up", f"+{avg_change:.2f}%"
            elif avg_change < -0.005:
                trend, pct_str = "down", f"{avg_change:.2f}%"
            else:
                trend, pct_str = "flat", "0.00%"

            theme_stocks.sort(key=lambda x: abs(x["change_pct"]), reverse=True)
            leaders = []
            for ts in theme_stocks[:10]:
                cp = ts["change_pct"]
                pct_display = f"+{cp:.2f}%" if cp >= 0 else f"{cp:.2f}%"
                leaders.append(f"{ts['name']}:{ts['code']}:{pct_display}")

            news_title, news_url, news_list_json = _search_theme_news_api(theme_def["search_query"], theme_def["name"])
            themes.append({
                "rank": 0, "name": theme_def["name"], "change_pct": pct_str,
                "avg_3day_pct": "", "up_count": up_count, "flat_count": flat_count,
                "down_count": down_count, "leading_stocks": ", ".join(leaders),
                "related_news": news_title, "news_url": news_url,
                "news_list": news_list_json,
                "trend": trend, "date": TODAY,
            })

    # 등락률 높은 순으로 랭킹 (상승 테마 우선)
    themes.sort(key=lambda t: float(t["change_pct"].replace("%", "").replace("+", "")), reverse=True)
    for i, t in enumerate(themes, 1):
        t["rank"] = i

    log(f"  ✅ 테마 {len(themes)}개 수집 완료")
    return themes


# ─────────────────────────────────────────
# 메인 실행
# ─────────────────────────────────────────
def main():
    log("=" * 50)
    log("🚀 STOCKPULSE 크롤러 시작")
    log(f"📅 날짜: {TODAY}")
    log("=" * 50)

    if not SUPABASE_KEY:
        log("❌ SUPABASE_KEY 환경변수가 설정되지 않았습니다!")
        log("  export SUPABASE_KEY='your-service-role-key'")
        return

    # 1. 섹터 매핑 조회 (네이버 업종별 종목, 일 1회 캐시)
    sector_map = fetch_naver_sector_map()
    log(f"  📋 섹터 매핑: {len(sector_map)}개 종목")

    # 2. 전종목 시세 조회 (네이버 금융 → KRX fallback)
    krx_data = fetch_naver_market_data(sector_map)
    if not krx_data:
        log("  ⚠️ 네이버 금융 실패 - KRX fallback 시도...")
        krx_data = fetch_krx_market_data()
    if not krx_data:
        log("❌ 시세 데이터 조회 실패 - 크롤링 중단")
        return

    # 3. 종목코드 매핑 구축 (AI 테마 코드 보정용)
    global KNOWN_STOCK_CODES
    KNOWN_STOCK_CODES = build_stock_code_map(krx_data)
    log(f"  📋 종목코드 매핑: {len(KNOWN_STOCK_CODES)}개 종목")

    # 4. 뉴스 (네이버 검색 API)
    news = crawl_news()

    # 5. 시장 지수 (Yahoo Finance API — 지수/환율만)
    indices = crawl_market_index()

    # 6. 섹터 데이터 (KRX 업종 기반)
    sectors = crawl_sectors(krx_data)

    # 7. 섹터별 종목 (KRX 시가총액 기반)
    sector_stocks = crawl_sector_stocks(krx_data)

    # 8. 테마-종목 매핑 DB 구축 (기업개요 기반, 하루 1회 캐싱)
    theme_map, stock_themes = build_theme_stock_map(krx_data)

    # 9. 테마 (AI 핫테마 선정 + 매핑 DB 종목 조회)
    news_titles = [n["title"] for n in news]
    themes = crawl_themes(krx_data, news_titles, theme_map)

    # 10. 이슈 종목 (복합 점수 랭킹: 등락률+거래대금+테마+뉴스+섹터)
    stocks = crawl_issue_stocks(krx_data, themes, sectors, news)

    # 11. AI 시장 브리핑 (Groq)
    ai_summary = generate_ai_summary(indices, stocks, sectors, themes, news)

    # ─── Supabase에 저장 ───
    log("")
    log("💾 Supabase에 데이터 저장 중...")

    # 기존 데이터 정리
    clear_today_data("news")
    clear_today_data("issue_stocks")
    clear_today_data("market_index")
    clear_today_data("sectors")
    clear_today_data("themes")
    supabase_request("DELETE", "sector_stocks", params={"id": "gt.0"})

    # 뉴스 저장
    if news:
        result = supabase_request("POST", "news", data=news)
        log(f"  📰 뉴스 {len(news)}개 저장 {'✅' if result else '❌'}")

    # 종목 저장
    if stocks:
        result = supabase_request("POST", "issue_stocks", data=stocks)
        log(f"  📈 종목 {len(stocks)}개 저장 {'✅' if result else '❌'}")

    # 지수 저장 (sparkline_data는 Yahoo Finance API에서 직접 가져옴)
    if indices:
        result = supabase_request("POST", "market_index", data=indices)
        log(f"  📊 지수 {len(indices)}개 저장 (sparkline 포함) {'✅' if result else '❌'}")

    # 섹터 저장
    if sectors:
        result = supabase_request("POST", "sectors", data=sectors)
        log(f"  🏭 섹터 {len(sectors)}개 저장 {'✅' if result else '❌'}")

    # 섹터별 종목 저장
    if sector_stocks:
        result = supabase_request("POST", "sector_stocks", data=sector_stocks)
        log(f"  🏷️ 섹터 종목 {len(sector_stocks)}개 저장 {'✅' if result else '❌'}")

    # 테마 저장
    if themes:
        result = supabase_request("POST", "themes", data=themes)
        log(f"  🔥 테마 {len(themes)}개 저장 {'✅' if result else '❌'}")

    # AI 요약 저장 (성공 시에만 기존 데이터 교체 — 실패 시 기존 유지)
    if ai_summary:
        clear_today_data("ai_summary")
        result = supabase_request("POST", "ai_summary", data=[ai_summary])
        log(f"  🤖 AI 요약 저장 {'✅' if result else '❌'}")
    else:
        log("  ℹ️ AI 요약 생성 실패 — 기존 데이터 유지")

    log("")
    log("=" * 50)
    log("✅ 크롤링 완료!")
    log("=" * 50)


if __name__ == "__main__":
    main()
