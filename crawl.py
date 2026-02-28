"""
STOCKPULSE 크롤러
KRX(한국거래소) API + Yahoo Finance + 네이버 검색 API + Groq AI로 주식 데이터를 수집하여 Supabase에 저장

데이터 소스:
  - KRX: 전종목 시세 (코드, 이름, 업종, 가격, 등락률, 거래량, 시가총액) — 메인 데이터
  - Yahoo Finance: 시장 지수 (코스피, 코스닥, 다우, 나스닥, S&P500, USD/KRW)
  - 네이버 검색 API: 뉴스, 테마별 관련 뉴스
  - Groq AI (Llama 3.3 70B): 뉴스 기반 인기 테마 자동 감지

사용법:
  pip install requests

  환경변수 설정:
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_KEY=your-service-role-key  (⚠️ service_role key 사용!)
    NAVER_CLIENT_ID=네이버 검색 API 클라이언트 ID
    NAVER_CLIENT_SECRET=네이버 검색 API 시크릿
    GROQ_API_KEY=Groq AI API 키

  python crawl.py
"""

import os
import re
import json
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
    "철강/소재": "⚙️",
    "건설":      "🏗️",
}

# KRX 업종 → 디스플레이 섹터 매핑
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
    "건설업":     "건설",
    "기계":       "건설",
    # KOSDAQ 업종
    "IT S/W & SVC":        "IT/플랫폼",
    "IT H/W":              "반도체",
    "제조 - 전기전자":      "반도체",
    "제조 - 화학":          "철강/소재",
    "제조 - 의료/정밀기기": "바이오",
    "제조 - 기계/장비":     "건설",
    "제조 - 금속":          "철강/소재",
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


def get_existing_sparkline_data():
    """기존 market_index에서 sparkline_data 읽기"""
    rows = supabase_request("GET", "market_index", params={"select": "name,sparkline_data"})
    if not rows:
        return {}
    result = {}
    for row in rows:
        name = row.get("name", "")
        sd = row.get("sparkline_data") or {}
        if isinstance(sd, dict):
            result[name] = {"d": sd.get("d", ""), "v": sd.get("v", [])}
        elif isinstance(sd, list):
            result[name] = {"d": "", "v": sd}
        else:
            result[name] = {"d": "", "v": []}
    return result


# ─────────────────────────────────────────
# 네이버 금융 API (메인 데이터 소스)
# ─────────────────────────────────────────
NAVER_STOCK_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
}

# 종목코드 → 업종 매핑 (주요 종목, 네이버 API에 업종 정보 없으므로 수동 매핑)
CODE_SECTOR_MAP = {
    # 반도체
    "005930": "전기전자", "000660": "전기전자", "402340": "전기전자",
    "042700": "전기전자", "166090": "전기전자", "058470": "전기전자",
    "357780": "전기전자", "403870": "전기전자", "036930": "전기전자",
    "240810": "전기전자", "267260": "전기전자", "010120": "전기전자",
    # 바이오
    "068270": "의약품", "207940": "의약품", "000100": "의약품",
    "128940": "의약품", "196170": "의약품", "141080": "의약품",
    "145020": "의약품", "302440": "의약품", "003460": "의약품",
    # 자동차
    "005380": "운수장비", "000270": "운수장비", "012330": "운수장비",
    "018880": "운수장비",
    # IT/플랫폼
    "035420": "서비스업", "035720": "서비스업", "259960": "서비스업",
    "036570": "서비스업", "263750": "서비스업", "251270": "서비스업",
    "017670": "서비스업", "030200": "서비스업",
    # 금융
    "105560": "은행", "055550": "은행", "086790": "은행",
    "316140": "은행", "032830": "증권", "000810": "증권",
    # 방산
    "012450": "기계", "079550": "기계", "047810": "기계",
    "000880": "기계", "064350": "기계", "272210": "기계",
    # 철강/소재
    "005490": "철강금속", "051910": "화학", "090430": "화학",
    "051900": "화학", "192820": "화학", "003230": "화학",
    # 건설
    "000720": "건설업", "047040": "건설업", "006360": "건설업",
    "375500": "건설업", "028260": "건설업",
    # 에너지
    "015760": "전기가스업", "096770": "전기가스업", "034020": "전기가스업",
    "052690": "전기가스업",
    # 조선
    "009540": "운수장비", "010140": "운수장비", "329180": "운수장비",
    "042660": "운수장비",
    # 엔터
    "352820": "서비스업", "041510": "서비스업", "035900": "서비스업",
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


def fetch_naver_market_data():
    """네이버 금융 API에서 전종목 시세 데이터 조회 (KRX 대체)"""
    log("📋 네이버 금융 API 전종목 시세 조회 중...")
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
                trading_value = int(item.get("accumulatedTradingValue", "0").replace(",", ""))
                market_cap = int(item.get("marketValue", "0").replace(",", "")) * 100_000_000  # 억원→원
            except (ValueError, TypeError):
                continue

            # 업종 매핑
            krx_sector = CODE_SECTOR_MAP.get(code, "")
            if code in BATTERY_STOCK_CODES:
                display_sector = "2차전지"
            else:
                display_sector = KRX_SECTOR_MAP.get(krx_sector, "")

            all_data[code] = {
                "code": code,
                "name": name,
                "market": market_name,
                "krx_sector": krx_sector,
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
def fetch_yahoo_chart(symbol):
    """Yahoo Finance v8 chart API로 단일 지수/환율 조회"""
    encoded = urllib.parse.quote(symbol)
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{encoded}?interval=1d&range=1d"
    resp = requests.get(url, headers=YAHOO_HEADERS, timeout=10)
    data = resp.json()
    meta = data["chart"]["result"][0]["meta"]
    price = meta.get("regularMarketPrice", 0)
    prev = meta.get("chartPreviousClose", 0) or meta.get("previousClose", 0)
    return price, prev


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


def classify_stock_tags(name):
    """종목명으로 태그 자동 분류"""
    tag_map = {
        "반도체": ["삼성전자", "SK하이닉스", "삼성SDI", "DB하이텍", "리노공업", "한미반도체", "HPSP", "주성엔지니어링"],
        "2차전지": ["LG에너지솔루션", "에코프로", "에코프로비엠", "포스코퓨처엠", "엘앤에프", "천보"],
        "바이오": ["셀트리온", "삼성바이오로직스", "유한양행", "한미약품", "알테오젠", "리가켐바이오"],
        "자동차": ["현대자동차", "현대차", "기아", "현대모비스", "만도"],
        "IT": ["네이버", "카카오", "카카오뱅크", "크래프톤", "엔씨소프트"],
        "금융": ["KB금융", "신한지주", "하나금융지주", "우리금융지주", "삼성생명", "삼성화재"],
        "철강": ["포스코홀딩스", "현대제철", "세아베스틸"],
        "건설": ["현대건설", "대우건설", "GS건설", "DL이앤씨"],
        "AI": ["삼성전자", "SK하이닉스", "네이버", "카카오"],
        "전기차": ["현대자동차", "현대차", "기아", "LG에너지솔루션"],
        "방산": ["한화에어로스페이스", "LIG넥스원", "한국항공우주", "현대로템"],
    }

    tags = []
    for tag, names in tag_map.items():
        if any(n in name for n in names):
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


def _search_theme_news_api(query):
    """Naver Search API로 테마 관련 뉴스 1건 검색"""
    if not NAVER_CLIENT_ID or not NAVER_CLIENT_SECRET:
        return "", ""
    try:
        url = "https://openapi.naver.com/v1/search/news.json"
        params = {"query": query, "display": 1, "sort": "date"}
        headers = {
            "X-Naver-Client-Id": NAVER_CLIENT_ID,
            "X-Naver-Client-Secret": NAVER_CLIENT_SECRET,
        }
        resp = requests.get(url, headers=headers, params=params, timeout=5)
        data = resp.json()
        items = data.get("items", [])
        if items:
            title = re.sub(r'<[^>]+>', '', items[0].get("title", "")).strip()
            link = items[0].get("link", "")
            return title, link
    except:
        pass
    return "", ""


# ─────────────────────────────────────────
# AI 테마 감지 (Groq / Llama 3.3 70B)
# ─────────────────────────────────────────
def detect_themes_with_ai(news_titles):
    """Groq API로 뉴스 분석 → 인기 테마 + 관련 종목 자동 감지 (전체 한국 주식 대상)"""
    if not GROQ_API_KEY:
        log("  ⚠️ GROQ_API_KEY 미설정 - 정적 테마 사용")
        return None

    if not news_titles:
        log("  ⚠️ 뉴스 데이터 없음 - 정적 테마 사용")
        return None

    news_text = "\n".join(f"- {t}" for t in news_titles[:30])

    prompt = f"""너는 국내 증시 테마 크롤러다.

## 목표:
아래 뉴스 헤드라인을 분석하여 현재 증시에서 가장 주목받는 테마 상위 10개를 선정한다.

## 오늘의 뉴스 헤드라인:
{news_text}

## 조건:
1. 각 테마마다 관련 종목 최대 10개 출력
2. 시가총액 3000억 원 이상 종목만 포함
3. 종목명은 한국거래소 상장 공식 명칭 그대로 작성
4. 종목코드(6자리) 반드시 포함
5. 코스피/코스닥 구분 포함
6. 우선주 제외 (예: 삼성전자우 제외)
7. ETF 제외
8. 비상장사 제외
9. 존재하지 않는 종목 생성 금지

## 출력 형식 (JSON):
{{
  "themes": [
    {{
      "name": "테마명",
      "search_query": "테마명 주식",
      "stocks": [
        {{"code": "005930", "name": "삼성전자", "market": "KOSPI"}},
        {{"code": "000660", "name": "SK하이닉스", "market": "KOSPI"}}
      ]
    }}
  ]
}}

## search_query 작성법:
- 네이버 뉴스 검색용 키워드. 테마명 + "주식" 형태로 작성
- 예시: "반도체 주식", "전기차 주식", "방산 주식", "AI 주식"

## 주요 종목코드 참고 (정확한 코드 사용 필수):
삼성전자=005930, SK하이닉스=000660, 삼성SDI=006400, LG에너지솔루션=373220,
현대자동차=005380, 기아=000270, 현대모비스=012330,
네이버=035420, 카카오=035720, 크래프톤=259960,
셀트리온=068270, 삼성바이오로직스=207940, 알테오젠=196170, 유한양행=000100,
한화에어로스페이스=012450, 현대로템=064350, LIG넥스원=079550, 한화시스템=272210, 한국항공우주=047810,
HD한국조선해양=009540, 삼성중공업=010140, HD현대중공업=329180, 한화오션=042660,
두산에너빌리티=034020, 한전기술=052690, 한국전력=015760,
두산로보틱스=454910, 레인보우로보틱스=277810,
에코프로비엠=247540, 에코프로=086520, 포스코퓨처엠=003670,
하이브=352820, SM=041510, JYP Ent.=035900,
아모레퍼시픽=090430, LG생활건강=051900, 코스맥스=192820,
포스코홀딩스=005490, LG화학=051910, 삼양식품=003230,
KB금융=105560, 신한지주=055550, HD현대일렉트릭=267260, LS일렉트릭=010120

## 핵심 규칙:
1. 종목은 해당 테마의 "핵심 수혜주"만 포함. 삼성전자·SK하이닉스 등 대형주를 모든 테마에 넣지 마라
2. 예: "방산" 테마 → 한화에어로스페이스, 현대로템, LIG넥스원 등만. 삼성전자는 방산 아님
3. 예: "전기차" 테마 → 현대차, 기아, LG에너지솔루션, 삼성SDI 등만. SK하이닉스는 전기차 아님
4. 예: "2차전지" 테마 → LG에너지솔루션, 에코프로, 포스코퓨처엠 등만. 삼성전자는 2차전지 아님
5. 추측 금지. 불확실하면 "확인 필요"라고 표시
6. 동일 종목이 여러 테마에 중복 배치되지 않도록 주의
7. 종목코드는 위 참고 리스트 또는 실제 존재하는 6자리 숫자 코드 사용
8. market은 "KOSPI" 또는 "KOSDAQ"
9. 뉴스에서 화제인 테마 우선, 정확히 10개"""

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

        # {"themes": [...]} 또는 [...] 형태 모두 처리
        if isinstance(parsed, dict):
            themes = None
            for key in parsed:
                if isinstance(parsed[key], list):
                    themes = parsed[key]
                    break
            if themes is None:
                themes = [parsed]
        else:
            themes = parsed

        # 검증 + KNOWN_STOCK_CODES(KRX 기반)로 코드 보정
        # 역방향 매핑 (코드→이름) 구축 for 추가 검증
        code_to_name = {}
        for kname, (kcode, kmkt) in KNOWN_STOCK_CODES.items():
            code_to_name[kcode] = (kname, kmkt)

        validated = []
        for theme in themes:
            if not isinstance(theme, dict) or "name" not in theme or "stocks" not in theme:
                continue
            valid_stocks = []
            for s in theme["stocks"]:
                if isinstance(s, dict) and s.get("code") and s.get("name"):
                    name = str(s["name"]).strip()
                    ai_code = str(s["code"]).zfill(6)
                    ai_market = str(s.get("market", "KOSPI")).upper()
                    if ai_market not in ("KOSPI", "KOSDAQ"):
                        ai_market = "KOSPI"
                    # KNOWN_STOCK_CODES(KRX에서 구축)로 정확한 코드 조회
                    if name in KNOWN_STOCK_CODES:
                        known_code, known_market = KNOWN_STOCK_CODES[name]
                        if known_code != ai_code:
                            log(f"     🔧 종목코드 보정: {name} {ai_code} → {known_code}")
                        code = known_code
                        market = known_market
                    else:
                        # 이름 매칭 실패 시 → AI가 준 코드로 KRX 역방향 조회
                        if ai_code in code_to_name:
                            real_name, real_market = code_to_name[ai_code]
                            if real_name != name:
                                log(f"     ⚠️ 종목명 불일치: AI={name}({ai_code}) → KRX={real_name}({ai_code})")
                                name = real_name  # KRX 이름으로 교체
                            code = ai_code
                            market = real_market
                        else:
                            log(f"     ❌ 미확인 종목 스킵: {name}({ai_code})")
                            continue  # KRX에 없는 코드는 스킵
                    valid_stocks.append({"code": code, "name": name, "market": market})
            if not theme.get("search_query"):
                theme["search_query"] = theme["name"] + " 주식"
            if valid_stocks:
                theme["stocks"] = valid_stocks[:10]  # 테마당 최대 10개
                validated.append(theme)

        if validated:
            total_stocks = sum(len(t["stocks"]) for t in validated)
            log(f"  🤖 AI 테마 감지 완료: {len(validated)}개 테마, {total_stocks}개 종목")
            for t in validated:
                names = ", ".join(s["name"] for s in t["stocks"][:3])
                log(f"     - {t['name']}: {names}...")
            return validated[:10]
        else:
            log("  ⚠️ AI 결과 검증 실패 - 정적 테마 사용")
            return None

    except Exception as e:
        log(f"  ⚠️ AI 테마 감지 실패: {e}")
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
                title = re.sub(r'<[^>]+>', '', item.get("title", "")).strip()
                if not title or title in seen_titles:
                    continue
                seen_titles.add(title)

                description = re.sub(r'<[^>]+>', '', item.get("description", "")).strip()

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


# ─────────────────────────────────────────
# 2. 이슈 종목 (KRX 거래대금 상위)
# ─────────────────────────────────────────
def crawl_issue_stocks(krx_data):
    """KRX 거래대금 상위 종목 추출"""
    log("📈 이슈 종목 크롤링 시작...")

    candidates = []
    for code, d in krx_data.items():
        if d["volume"] == 0 or d["price"] == 0:
            continue
        if is_etf_etn(d["name"]):
            continue
        candidates.append(d)

    # 거래대금 기준 정렬
    candidates.sort(key=lambda x: x["trading_value"], reverse=True)

    stocks = []
    for rank_idx, d in enumerate(candidates[:10], 1):
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

        # 거래대금을 억원 단위로
        trading_value_eok = d["trading_value"] / 100_000_000
        volume_str = format_trading_value(str(int(trading_value_eok)))

        stocks.append({
            "rank": rank_idx,
            "name": d["name"],
            "code": d["code"],
            "price": price_formatted,
            "change_pct": pct_str,
            "volume": volume_str,
            "reason": f"거래대금 상위 {rank_idx}위",
            "tags": classify_stock_tags(d["name"]),
            "trend": trend,
            "date": TODAY,
        })

    log(f"  ✅ 거래대금 상위 {len(stocks)}개 수집 완료")
    return stocks


# ─────────────────────────────────────────
# 3. 시장 지수 (Yahoo Finance API)
# ─────────────────────────────────────────
def crawl_market_index():
    """Yahoo Finance API로 시장 지수 + 환율 조회"""
    log("📊 시장 지수 크롤링 시작...")

    indices = []

    index_symbols = [
        ("코스피",   "^KS11"),
        ("코스닥",   "^KQ11"),
        ("다우존스", "^DJI"),
        ("나스닥",   "^IXIC"),
        ("S&P 500",  "^GSPC"),
        ("USD/KRW",  "USDKRW=X"),
    ]

    for name, symbol in index_symbols:
        try:
            price, prev = fetch_yahoo_chart(symbol)

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
                })
            else:
                indices.append({
                    "name": name,
                    "value": f"{price:,.2f}",
                    "change_amount": "0",
                    "change_pct": "0.00%",
                    "trend": "up",
                })
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
def crawl_themes(krx_data, news_titles=None):
    """AI가 선정한 테마의 종목을 KRX 데이터에서 조회하여 성과 계산"""
    log("🔥 테마 크롤링 시작...")

    ai_themes = detect_themes_with_ai(news_titles)

    if ai_themes:
        # ── AI 테마: KRX 데이터에서 직접 가격 조회 ──
        themes = []
        for theme_def in ai_themes:
            theme_stocks = []
            changes = []
            seen_codes = set()

            MIN_MARKET_CAP = 300_000_000_000  # 시가총액 3000억 원

            for s in theme_def["stocks"]:
                code = s["code"]
                if code in seen_codes:
                    continue
                seen_codes.add(code)

                d = krx_data.get(code)
                if not d:
                    continue

                # 시가총액 3000억 미만 필터링
                if d.get("market_cap", 0) < MIN_MARKET_CAP:
                    log(f"     ⏭️ 시총 미달 스킵: {d['name']}({code}) {d.get('market_cap',0)/1e8:.0f}억")
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

            # 네이버 뉴스 검색
            search_kw = theme_def.get("search_query", theme_def["name"] + " 주식")
            news_title, news_url = _search_theme_news_api(search_kw)

            themes.append({
                "rank": 0, "name": theme_def["name"], "change_pct": pct_str,
                "avg_3day_pct": "", "up_count": up_count, "flat_count": flat_count,
                "down_count": down_count, "leading_stocks": ", ".join(leaders),
                "related_news": news_title, "news_url": news_url,
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

            news_title, news_url = _search_theme_news_api(theme_def["search_query"])
            themes.append({
                "rank": 0, "name": theme_def["name"], "change_pct": pct_str,
                "avg_3day_pct": "", "up_count": up_count, "flat_count": flat_count,
                "down_count": down_count, "leading_stocks": ", ".join(leaders),
                "related_news": news_title, "news_url": news_url,
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

    # 1. 전종목 시세 조회 (네이버 금융 → KRX fallback)
    krx_data = fetch_naver_market_data()
    if not krx_data:
        log("  ⚠️ 네이버 금융 실패 - KRX fallback 시도...")
        krx_data = fetch_krx_market_data()
    if not krx_data:
        log("❌ 시세 데이터 조회 실패 - 크롤링 중단")
        return

    # 2. 종목코드 매핑 구축 (AI 테마 코드 보정용)
    global KNOWN_STOCK_CODES
    KNOWN_STOCK_CODES = build_stock_code_map(krx_data)
    log(f"  📋 종목코드 매핑: {len(KNOWN_STOCK_CODES)}개 종목")

    # 3. 뉴스 (네이버 검색 API)
    news = crawl_news()

    # 4. 이슈 종목 (KRX 거래대금 기반)
    stocks = crawl_issue_stocks(krx_data)

    # 5. 시장 지수 (Yahoo Finance API — 지수/환율만)
    indices = crawl_market_index()

    # 6. 섹터 데이터 (KRX 업종 기반)
    sectors = crawl_sectors(krx_data)

    # 7. 섹터별 종목 (KRX 시가총액 기반)
    sector_stocks = crawl_sector_stocks(krx_data)

    # 8. 테마 (AI + KRX + 네이버 검색 API)
    news_titles = [n["title"] for n in news]
    themes = crawl_themes(krx_data, news_titles)

    # ─── Supabase에 저장 ───
    log("")
    log("💾 Supabase에 데이터 저장 중...")

    # sparkline_data 읽기 (DELETE 전에!)
    existing_sparkline = get_existing_sparkline_data()

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

    # 지수 저장 (sparkline_data 포함)
    if indices:
        MAX_SPARKLINE_POINTS = 80
        for idx_item in indices:
            name = idx_item["name"]
            try:
                current_value = float(idx_item["value"].replace(",", ""))
            except (ValueError, AttributeError):
                current_value = 0
            existing = existing_sparkline.get(name, {"d": "", "v": []})
            prev_date = existing["d"]
            prev_data = existing["v"]
            if prev_date == TODAY:
                if not prev_data or abs(current_value - prev_data[-1]) >= 0.01:
                    prev_data.append(current_value)
                idx_item["sparkline_data"] = {"d": TODAY, "v": prev_data[-MAX_SPARKLINE_POINTS:]}
            elif prev_data and abs(current_value - prev_data[-1]) < 0.01:
                idx_item["sparkline_data"] = {"d": prev_date, "v": prev_data}
            else:
                idx_item["sparkline_data"] = {"d": TODAY, "v": [current_value]}
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

    log("")
    log("=" * 50)
    log("✅ 크롤링 완료!")
    log("=" * 50)


if __name__ == "__main__":
    main()
