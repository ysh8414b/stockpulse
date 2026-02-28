"""
STOCKPULSE 크롤러
Yahoo Finance API + 네이버 검색 API로 주식 데이터를 수집하여 Supabase에 저장

사용법:
  pip install requests

  환경변수 설정:
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_KEY=your-service-role-key  (⚠️ service_role key 사용!)
    NAVER_CLIENT_ID=네이버 검색 API 클라이언트 ID
    NAVER_CLIENT_SECRET=네이버 검색 API 시크릿

  python crawl.py
"""

import os
import re
import json
import urllib.parse
from datetime import datetime
from email.utils import parsedate_to_datetime

import requests

# ─────────────────────────────────────────
# 설정
# ─────────────────────────────────────────
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://mmmpqmvwpuxqyxlxytsh.supabase.co")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")  # service_role key (GitHub Secrets에 저장)

NAVER_CLIENT_ID = os.environ.get("NAVER_CLIENT_ID", "")
NAVER_CLIENT_SECRET = os.environ.get("NAVER_CLIENT_SECRET", "")

YAHOO_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
}

TODAY = datetime.now().strftime("%Y-%m-%d")

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}")


# ─────────────────────────────────────────
# 종목 마스터 데이터
# ─────────────────────────────────────────
STOCK_UNIVERSE = [
    # 반도체
    {"code": "005930", "name": "삼성전자",       "ticker": "005930.KS", "sector": "반도체",    "themes": ["반도체", "AI"]},
    {"code": "000660", "name": "SK하이닉스",     "ticker": "000660.KS", "sector": "반도체",    "themes": ["반도체", "AI", "HBM"]},
    {"code": "402340", "name": "SK스퀘어",       "ticker": "402340.KS", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "042700", "name": "한미반도체",     "ticker": "042700.KQ", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "166090", "name": "하나머티리얼즈", "ticker": "166090.KQ", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "058470", "name": "리노공업",       "ticker": "058470.KQ", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "357780", "name": "솔브레인",       "ticker": "357780.KQ", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "403870", "name": "HPSP",           "ticker": "403870.KQ", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "036930", "name": "주성엔지니어링", "ticker": "036930.KQ", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "240810", "name": "원익IPS",        "ticker": "240810.KQ", "sector": "반도체",    "themes": ["반도체"]},
    {"code": "006400", "name": "삼성SDI",        "ticker": "006400.KS", "sector": "반도체",    "themes": ["반도체", "2차전지"]},
    # 2차전지
    {"code": "373220", "name": "LG에너지솔루션", "ticker": "373220.KS", "sector": "2차전지",   "themes": ["2차전지", "전기차"]},
    {"code": "247540", "name": "에코프로비엠",   "ticker": "247540.KQ", "sector": "2차전지",   "themes": ["2차전지"]},
    {"code": "086520", "name": "에코프로",       "ticker": "086520.KQ", "sector": "2차전지",   "themes": ["2차전지"]},
    {"code": "003670", "name": "포스코퓨처엠",   "ticker": "003670.KS", "sector": "2차전지",   "themes": ["2차전지"]},
    {"code": "066570", "name": "LG전자",         "ticker": "066570.KS", "sector": "2차전지",   "themes": ["2차전지"]},
    {"code": "051910", "name": "LG화학",         "ticker": "051910.KS", "sector": "2차전지",   "themes": ["2차전지"]},
    {"code": "112610", "name": "씨에스윈드",     "ticker": "112610.KS", "sector": "2차전지",   "themes": ["2차전지", "에너지"]},
    {"code": "298050", "name": "엘앤에프",       "ticker": "298050.KQ", "sector": "2차전지",   "themes": ["2차전지"]},
    {"code": "006260", "name": "LS",             "ticker": "006260.KS", "sector": "2차전지",   "themes": ["2차전지", "전력"]},
    # 바이오
    {"code": "068270", "name": "셀트리온",       "ticker": "068270.KS", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "207940", "name": "삼성바이오로직스","ticker": "207940.KS", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "000100", "name": "유한양행",       "ticker": "000100.KS", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "128940", "name": "한미약품",       "ticker": "128940.KS", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "196170", "name": "알테오젠",       "ticker": "196170.KQ", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "141080", "name": "리가켐바이오",   "ticker": "141080.KQ", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "145020", "name": "휴젤",           "ticker": "145020.KQ", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "302440", "name": "SK바이오팜",     "ticker": "302440.KS", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "326030", "name": "SK바이오사이언스","ticker": "326030.KS", "sector": "바이오",    "themes": ["바이오"]},
    {"code": "950160", "name": "코오롱티슈진",   "ticker": "950160.KQ", "sector": "바이오",    "themes": ["바이오"]},
    # 자동차
    {"code": "005380", "name": "현대자동차",     "ticker": "005380.KS", "sector": "자동차",    "themes": ["자동차", "전기차"]},
    {"code": "000270", "name": "기아",           "ticker": "000270.KS", "sector": "자동차",    "themes": ["자동차", "전기차"]},
    {"code": "012330", "name": "현대모비스",     "ticker": "012330.KS", "sector": "자동차",    "themes": ["자동차"]},
    {"code": "018880", "name": "한온시스템",     "ticker": "018880.KS", "sector": "자동차",    "themes": ["자동차", "전기차"]},
    {"code": "204320", "name": "만도",           "ticker": "204320.KS", "sector": "자동차",    "themes": ["자동차"]},
    {"code": "011210", "name": "현대위아",       "ticker": "011210.KS", "sector": "자동차",    "themes": ["자동차"]},
    # IT/플랫폼
    {"code": "035420", "name": "네이버",         "ticker": "035420.KS", "sector": "IT/플랫폼", "themes": ["IT", "AI"]},
    {"code": "035720", "name": "카카오",         "ticker": "035720.KS", "sector": "IT/플랫폼", "themes": ["IT"]},
    {"code": "263750", "name": "펄어비스",       "ticker": "263750.KS", "sector": "IT/플랫폼", "themes": ["IT", "게임"]},
    {"code": "259960", "name": "크래프톤",       "ticker": "259960.KS", "sector": "IT/플랫폼", "themes": ["IT", "게임"]},
    {"code": "036570", "name": "엔씨소프트",     "ticker": "036570.KS", "sector": "IT/플랫폼", "themes": ["IT", "게임"]},
    {"code": "251270", "name": "넷마블",         "ticker": "251270.KS", "sector": "IT/플랫폼", "themes": ["IT", "게임"]},
    {"code": "323410", "name": "카카오뱅크",     "ticker": "323410.KS", "sector": "IT/플랫폼", "themes": ["IT", "금융"]},
    {"code": "377300", "name": "카카오페이",     "ticker": "377300.KS", "sector": "IT/플랫폼", "themes": ["IT", "금융"]},
    # 금융
    {"code": "105560", "name": "KB금융",         "ticker": "105560.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "055550", "name": "신한지주",       "ticker": "055550.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "086790", "name": "하나금융지주",   "ticker": "086790.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "316140", "name": "우리금융지주",   "ticker": "316140.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "032830", "name": "삼성생명",       "ticker": "032830.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "000810", "name": "삼성화재",       "ticker": "000810.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "024110", "name": "기업은행",       "ticker": "024110.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "138930", "name": "BNK금융지주",    "ticker": "138930.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "139130", "name": "DGB금융지주",    "ticker": "139130.KS", "sector": "금융",      "themes": ["금융"]},
    {"code": "175330", "name": "JB금융지주",     "ticker": "175330.KS", "sector": "금융",      "themes": ["금융"]},
    # 철강/소재
    {"code": "005490", "name": "포스코홀딩스",   "ticker": "005490.KS", "sector": "철강/소재",  "themes": ["철강"]},
    {"code": "004020", "name": "현대제철",       "ticker": "004020.KS", "sector": "철강/소재",  "themes": ["철강"]},
    {"code": "010130", "name": "고려아연",       "ticker": "010130.KS", "sector": "철강/소재",  "themes": ["철강"]},
    {"code": "096770", "name": "SK이노베이션",   "ticker": "096770.KS", "sector": "철강/소재",  "themes": ["에너지"]},
    {"code": "010950", "name": "S-Oil",          "ticker": "010950.KS", "sector": "철강/소재",  "themes": ["에너지"]},
    {"code": "011170", "name": "롯데케미칼",     "ticker": "011170.KS", "sector": "철강/소재",  "themes": ["화학"]},
    {"code": "006800", "name": "미래에셋증권",   "ticker": "006800.KS", "sector": "철강/소재",  "themes": ["화학"]},
    {"code": "009150", "name": "삼성전기",       "ticker": "009150.KS", "sector": "철강/소재",  "themes": ["전자부품"]},
    # 건설
    {"code": "000720", "name": "현대건설",       "ticker": "000720.KS", "sector": "건설",      "themes": ["건설"]},
    {"code": "047040", "name": "대우건설",       "ticker": "047040.KS", "sector": "건설",      "themes": ["건설"]},
    {"code": "006360", "name": "GS건설",         "ticker": "006360.KS", "sector": "건설",      "themes": ["건설"]},
    {"code": "375500", "name": "DL이앤씨",       "ticker": "375500.KS", "sector": "건설",      "themes": ["건설"]},
    {"code": "028260", "name": "삼성물산",       "ticker": "028260.KS", "sector": "건설",      "themes": ["건설", "지주"]},
    {"code": "009830", "name": "한화솔루션",     "ticker": "009830.KS", "sector": "건설",      "themes": ["건설", "에너지"]},
    # 방산/기타
    {"code": "012450", "name": "한화에어로스페이스","ticker": "012450.KS","sector": "방산",     "themes": ["방산"]},
    {"code": "079550", "name": "LIG넥스원",      "ticker": "079550.KS", "sector": "방산",      "themes": ["방산"]},
    {"code": "047810", "name": "한국항공우주",   "ticker": "047810.KS", "sector": "방산",      "themes": ["방산"]},
    {"code": "000880", "name": "한화",           "ticker": "000880.KS", "sector": "방산",      "themes": ["방산"]},
    {"code": "017670", "name": "SK텔레콤",       "ticker": "017670.KS", "sector": "통신",      "themes": ["통신", "AI"]},
    {"code": "030200", "name": "KT",             "ticker": "030200.KS", "sector": "통신",      "themes": ["통신", "AI"]},
    {"code": "032640", "name": "LG유플러스",     "ticker": "032640.KS", "sector": "통신",      "themes": ["통신"]},
    {"code": "015760", "name": "한국전력",       "ticker": "015760.KS", "sector": "에너지",    "themes": ["에너지", "전력"]},
    {"code": "034730", "name": "SK",             "ticker": "034730.KS", "sector": "지주",      "themes": ["지주"]},
    {"code": "003550", "name": "LG",             "ticker": "003550.KS", "sector": "지주",      "themes": ["지주"]},
    {"code": "051900", "name": "LG생활건강",     "ticker": "051900.KS", "sector": "소비재",    "themes": ["소비재"]},
    {"code": "090430", "name": "아모레퍼시픽",   "ticker": "090430.KS", "sector": "소비재",    "themes": ["소비재"]},
]

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
     "stocks": ["012450", "079550", "047810", "000880"]},
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
        # 항상 최신 데이터만 유지 (전체 교체)
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
# Yahoo Finance API 헬퍼
# ─────────────────────────────────────────
def fetch_yahoo_batch_quotes(tickers):
    """Yahoo Finance v7 batch quote API로 종목 데이터 일괄 조회"""
    result = {}
    CHUNK = 50
    for i in range(0, len(tickers), CHUNK):
        chunk = tickers[i:i+CHUNK]
        symbols = ",".join(chunk)
        url = f"https://query1.finance.yahoo.com/v7/finance/quote?symbols={symbols}"
        try:
            resp = requests.get(url, headers=YAHOO_HEADERS, timeout=15)
            data = resp.json()
            for quote in data.get("quoteResponse", {}).get("result", []):
                sym = quote.get("symbol", "")
                result[sym] = quote
        except Exception as e:
            log(f"  ⚠️ Yahoo batch quote 실패 (chunk {i//CHUNK+1}): {e}")
    return result


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
# 헬퍼 함수 (유지)
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
        if val >= 10000:  # 1조 이상
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
        "방산": ["한화에어로스페이스", "LIG넥스원", "한국항공우주"],
    }

    tags = []
    for tag, names in tag_map.items():
        if any(n in name for n in names):
            tags.append(tag)

    if not tags:
        tags = ["기타"]

    return tags[:3]  # 최대 3개


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

                # 언론사 추출 (originallink 도메인에서)
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
# 2. 이슈 종목 (Yahoo Finance 거래량 기반)
# ─────────────────────────────────────────
def crawl_issue_stocks(yahoo_quotes):
    """Yahoo Finance 데이터에서 거래량 상위 종목 추출"""
    log("📈 이슈 종목 크롤링 시작...")

    stock_data = []

    for stock in STOCK_UNIVERSE:
        ticker = stock["ticker"]
        quote = yahoo_quotes.get(ticker)
        if not quote:
            continue

        volume = quote.get("regularMarketVolume", 0) or 0
        price = quote.get("regularMarketPrice", 0) or 0
        change_pct = quote.get("regularMarketChangePercent", 0) or 0

        if volume == 0 or price == 0:
            continue
        if is_etf_etn(stock["name"]):
            continue

        # 거래대금 (억원)
        trading_value_eok = (price * volume) / 100_000_000

        stock_data.append({
            "stock": stock,
            "volume": volume,
            "price": price,
            "change_pct": change_pct,
            "trading_value_eok": trading_value_eok,
        })

    # 거래량 기준 정렬
    stock_data.sort(key=lambda x: x["volume"], reverse=True)

    stocks = []
    for rank_idx, sd in enumerate(stock_data[:10], 1):
        s = sd["stock"]
        cp = sd["change_pct"]

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
            price_formatted = f"{int(sd['price']):,}"
        except:
            price_formatted = str(sd["price"])

        volume_str = format_trading_value(str(int(sd["trading_value_eok"])))

        stocks.append({
            "rank": rank_idx,
            "name": s["name"],
            "code": s["code"],
            "price": price_formatted,
            "change_pct": pct_str,
            "volume": volume_str,
            "reason": f"거래량 상위 {rank_idx}위",
            "tags": classify_stock_tags(s["name"]),
            "trend": trend,
            "date": TODAY,
        })

    log(f"  ✅ 거래량 상위 {len(stocks)}개 수집 완료")
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
# 4. 섹터 데이터 (Yahoo 데이터 기반 계산)
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

def crawl_sectors(yahoo_quotes):
    """Yahoo Finance 데이터에서 섹터별 등락률 계산"""
    log("🏭 섹터 데이터 크롤링 시작...")

    # 섹터별 통계 수집
    sector_stats = {}
    for stock in STOCK_UNIVERSE:
        sector = stock["sector"]
        if sector not in SECTOR_ICONS:
            continue

        quote = yahoo_quotes.get(stock["ticker"])
        if not quote:
            continue

        change_pct = quote.get("regularMarketChangePercent", 0) or 0

        if sector not in sector_stats:
            sector_stats[sector] = {"changes": [], "stocks": []}
        sector_stats[sector]["changes"].append(change_pct)
        sector_stats[sector]["stocks"].append(stock)

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
            q = yahoo_quotes.get(s["ticker"])
            if q:
                cp = q.get("regularMarketChangePercent", 0) or 0
                if cp > best_pct:
                    best_pct = cp
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
# 5. 섹터별 종목 (Yahoo 데이터 기반)
# ─────────────────────────────────────────
def crawl_sector_stocks(yahoo_quotes):
    """Yahoo Finance 데이터에서 섹터별 종목 목록 생성"""
    log("🏷️ 섹터별 종목 크롤링 시작...")

    target_sectors = list(SECTOR_ICONS.keys())
    all_stocks = []

    for sector_name in target_sectors:
        sector_universe = [s for s in STOCK_UNIVERSE if s["sector"] == sector_name]

        # Yahoo 데이터 매핑 후 시가총액 순 정렬
        enriched = []
        for stock in sector_universe:
            quote = yahoo_quotes.get(stock["ticker"])
            if not quote:
                continue
            price = quote.get("regularMarketPrice", 0) or 0
            change_pct = quote.get("regularMarketChangePercent", 0) or 0
            market_cap = quote.get("marketCap", 0) or 0
            enriched.append({
                "stock": stock,
                "price": price,
                "change_pct": change_pct,
                "market_cap": market_cap,
            })

        enriched.sort(key=lambda x: x["market_cap"], reverse=True)

        for rank_idx, e in enumerate(enriched[:10], 1):
            s = e["stock"]
            cp = e["change_pct"]

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
                price_formatted = f"{int(e['price']):,}"
            except:
                price_formatted = str(e["price"])

            all_stocks.append({
                "sector_name": sector_name,
                "stock_name": s["name"],
                "code": s["code"],
                "price": price_formatted,
                "change_pct": pct_str,
                "trend": trend,
                "rank": rank_idx,
            })

        log(f"  ✅ {sector_name}: {min(len(enriched), 10)}개 종목 수집")

    log(f"  ✅ 섹터별 종목 총 {len(all_stocks)}개 수집 완료")
    return all_stocks


# ─────────────────────────────────────────
# 6. 테마 (Yahoo + 네이버 검색 API 하이브리드)
# ─────────────────────────────────────────
def crawl_themes(yahoo_quotes):
    """테마별 성과 계산 + 네이버 검색 API로 관련 뉴스"""
    log("🔥 테마 크롤링 시작...")

    # code -> quote 룩업 테이블
    code_to_data = {}
    for stock in STOCK_UNIVERSE:
        quote = yahoo_quotes.get(stock["ticker"])
        if quote:
            code_to_data[stock["code"]] = {"quote": quote, "stock": stock}

    themes = []

    for theme_def in THEME_DEFINITIONS:
        theme_stocks = []
        changes = []

        for code in theme_def["stocks"]:
            if code in code_to_data:
                cd = code_to_data[code]
                q = cd["quote"]
                cp = q.get("regularMarketChangePercent", 0) or 0
                changes.append(cp)
                theme_stocks.append({
                    "name": cd["stock"]["name"],
                    "code": code,
                    "change_pct": cp,
                })

        # 테마 평균 등락률
        avg_change = sum(changes) / len(changes) if changes else 0.0

        up_count = sum(1 for c in changes if c > 0.005)
        down_count = sum(1 for c in changes if c < -0.005)
        flat_count = len(changes) - up_count - down_count

        if avg_change > 0.005:
            trend = "up"
            pct_str = f"+{avg_change:.2f}%"
        elif avg_change < -0.005:
            trend = "down"
            pct_str = f"{avg_change:.2f}%"
        else:
            trend = "flat"
            pct_str = "0.00%"

        # 주도주 (변동폭 큰 순)
        theme_stocks.sort(key=lambda x: abs(x["change_pct"]), reverse=True)
        leaders = []
        for ts in theme_stocks[:10]:
            cp = ts["change_pct"]
            pct_display = f"+{cp:.2f}%" if cp >= 0 else f"{cp:.2f}%"
            leaders.append(f"{ts['name']}:{ts['code']}:{pct_display}")

        # 관련 뉴스 (네이버 검색 API)
        news_title, news_url = _search_theme_news_api(theme_def["search_query"])

        themes.append({
            "rank": 0,
            "name": theme_def["name"],
            "change_pct": pct_str,
            "avg_3day_pct": "",
            "up_count": up_count,
            "flat_count": flat_count,
            "down_count": down_count,
            "leading_stocks": ", ".join(leaders),
            "related_news": news_title,
            "news_url": news_url,
            "trend": trend,
            "date": TODAY,
        })

    # 변동폭 큰 순으로 랭킹
    themes.sort(key=lambda t: abs(float(t["change_pct"].replace("%", "").replace("+", ""))), reverse=True)
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

    # Yahoo Finance 일괄 조회
    log("📡 Yahoo Finance 데이터 조회 중...")
    all_tickers = list(set(s["ticker"] for s in STOCK_UNIVERSE))
    yahoo_quotes = fetch_yahoo_batch_quotes(all_tickers)
    log(f"  ✅ {len(yahoo_quotes)}개 종목 데이터 수신")

    if not yahoo_quotes:
        log("  ❌ Yahoo Finance 데이터 수신 실패 - 종목/섹터/테마 데이터 없음")

    # 1. 뉴스 (네이버 검색 API)
    news = crawl_news()

    # 2. 이슈 종목 (Yahoo 데이터 기반)
    stocks = crawl_issue_stocks(yahoo_quotes)

    # 3. 시장 지수 (Yahoo Finance API)
    indices = crawl_market_index()

    # 4. 섹터 데이터 (Yahoo 데이터 기반)
    sectors = crawl_sectors(yahoo_quotes)

    # 5. 섹터별 종목 (Yahoo 데이터 기반)
    sector_stocks = crawl_sector_stocks(yahoo_quotes)

    # 6. 테마 (Yahoo + 네이버 검색 API)
    themes = crawl_themes(yahoo_quotes)

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

    # 지수 저장 (sparkline_data 포함 — 하루치 전체, 장 시작시 리셋)
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
                # 같은 날: 값이 변했을 때만 추가 (장 마감 후 차트 보존)
                if not prev_data or abs(current_value - prev_data[-1]) >= 0.01:
                    prev_data.append(current_value)
                idx_item["sparkline_data"] = {"d": TODAY, "v": prev_data[-MAX_SPARKLINE_POINTS:]}
            elif prev_data and abs(current_value - prev_data[-1]) < 0.01:
                # 날짜 다르지만 값 동일 = 장 안 열림 (주말/공휴일) → 기존 차트 유지
                idx_item["sparkline_data"] = {"d": prev_date, "v": prev_data}
            else:
                # 날짜 다르고 값 변동 = 새 거래일 → 리셋
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
