"""
STOCKPULSE 크롤러
한국투자증권 KIS API + 네이버 금융에서 뉴스/섹터종목 데이터를 수집하여 Supabase에 저장

사용법:
  pip install requests beautifulsoup4

  환경변수 설정:
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_KEY=your-service-role-key  (⚠️ service_role key 사용!)
    KIS_APP_KEY=발급받은_앱키
    KIS_APP_SECRET=발급받은_시크릿키

  python crawl.py
"""

import os
import re
import json
import time
from datetime import datetime, timedelta
from typing import Optional
from pathlib import Path

import requests
from bs4 import BeautifulSoup

# ─────────────────────────────────────────
# 설정
# ─────────────────────────────────────────
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://mmmpqmvwpuxqyxlxytsh.supabase.co")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")  # service_role key (GitHub Secrets에 저장)

# 한국투자증권 KIS API
KIS_APP_KEY = os.environ.get("KIS_APP_KEY", "")
KIS_APP_SECRET = os.environ.get("KIS_APP_SECRET", "")
KIS_BASE_URL = "https://openapi.koreainvestment.com:9443"
KIS_TOKEN_FILE = Path(__file__).parent / "kis_token.json"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7",
}

TODAY = datetime.now().strftime("%Y-%m-%d")

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}")


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


# ─────────────────────────────────────────
# KIS API 헬퍼
# ─────────────────────────────────────────
def kis_get_token():
    """KIS API access_token 발급 (캐싱: 24시간 유효)"""
    # 캐시된 토큰 확인
    if KIS_TOKEN_FILE.exists():
        try:
            cached = json.loads(KIS_TOKEN_FILE.read_text(encoding="utf-8"))
            expires = datetime.strptime(cached["expires"], "%Y-%m-%d %H:%M:%S")
            if datetime.now() < expires - timedelta(minutes=30):
                return cached["token"]
            log("  🔄 KIS 토큰 만료 임박, 재발급...")
        except Exception:
            pass

    # 새 토큰 발급
    url = f"{KIS_BASE_URL}/oauth2/tokenP"
    body = {
        "grant_type": "client_credentials",
        "appkey": KIS_APP_KEY,
        "appsecret": KIS_APP_SECRET,
    }
    resp = requests.post(url, json=body, timeout=10)
    data = resp.json()

    if "access_token" not in data:
        log(f"  ❌ KIS 토큰 발급 실패: {data}")
        return None

    token = data["access_token"]
    expires_str = data.get("access_token_token_expired", "")

    # 토큰 캐싱
    KIS_TOKEN_FILE.write_text(
        json.dumps({"token": token, "expires": expires_str}, ensure_ascii=False),
        encoding="utf-8",
    )
    log(f"  ✅ KIS 토큰 발급 완료 (만료: {expires_str})")
    return token


def kis_headers(tr_id):
    """KIS API 공통 헤더 생성"""
    token = kis_get_token()
    if not token:
        return None
    return {
        "content-type": "application/json; charset=utf-8",
        "authorization": f"Bearer {token}",
        "appkey": KIS_APP_KEY,
        "appsecret": KIS_APP_SECRET,
        "tr_id": tr_id,
    }


def kis_request(path, tr_id, params):
    """KIS API GET 요청 헬퍼"""
    headers = kis_headers(tr_id)
    if not headers:
        return None
    url = f"{KIS_BASE_URL}{path}"
    resp = requests.get(url, headers=headers, params=params, timeout=10)
    data = resp.json()
    if data.get("rt_cd") != "0":
        log(f"  ⚠️ KIS API 오류 ({tr_id}): {data.get('msg1', '')}")
        return None
    return data


def kis_trend(sign):
    """prdy_vrss_sign 값으로 trend 반환 (1:상한, 2:상승, 3:보합, 4:하한, 5:하락)"""
    return "down" if sign in ("4", "5") else ("flat" if sign == "3" else "up")


def clear_today_data(table):
    """오늘 데이터 삭제 (중복 방지)"""
    if table in ("market_index", "sectors"):
        # 이 테이블들은 날짜 컬럼 없이 전체 교체
        supabase_request("DELETE", table, params={"id": "gt.0"})
    else:
        supabase_request("DELETE", table, params={"date": f"eq.{TODAY}"})


# ─────────────────────────────────────────
# 1. 네이버 금융 주요뉴스 크롤링
# ─────────────────────────────────────────
def crawl_news():
    """네이버 금융 주요뉴스 크롤링"""
    log("📰 뉴스 크롤링 시작...")
    
    news_list = []
    
    # 네이버 금융 주요뉴스 페이지
    url = "https://finance.naver.com/news/mainnews.naver"
    try:
        resp = requests.get(url, headers=HEADERS, timeout=10)
        resp.encoding = "euc-kr"
        soup = BeautifulSoup(resp.text, "html.parser")
        
        # 뉴스 목록 추출
        news_items = soup.select("dd.articleSubject a")
        news_summaries = soup.select("dd.articleSummary")
        
        for i, item in enumerate(news_items[:15]):  # 최대 15개
            title = item.get("title", "").strip() or item.get_text(strip=True)
            href = item.get("href", "")
            
            if not title:
                continue
            
            # 요약 추출
            summary = ""
            if i < len(news_summaries):
                summary_text = news_summaries[i].get_text(strip=True)
                # 언론사 부분 제거
                press_span = news_summaries[i].find("span", class_="press")
                press = press_span.get_text(strip=True) if press_span else ""
                summary = summary_text.replace(press, "").strip()
                # 너무 긴 경우 자르기
                if len(summary) > 200:
                    summary = summary[:200] + "..."
            
            # 언론사 추출
            source = ""
            if i < len(news_summaries):
                press_span = news_summaries[i].find("span", class_="press")
                if press_span:
                    source = press_span.get_text(strip=True)
            
            # 카테고리 자동 분류
            category = classify_news_category(title)
            
            # 감성 분석 (간단 키워드 기반)
            sentiment = analyze_sentiment(title)
            
            # 시간 계산
            time_ago = f"{i+1}시간 전" if i < 12 else "오늘"
            
            news_list.append({
                "title": title,
                "source": source or "네이버금융",
                "time_ago": time_ago,
                "category": category,
                "sentiment": sentiment,
                "summary": summary[:500] if summary else title,
                "url": f"https://finance.naver.com{href}" if href.startswith("/") else href,
                "date": TODAY,
            })
        
        log(f"  ✅ 뉴스 {len(news_list)}개 수집 완료")
        
    except Exception as e:
        log(f"  ❌ 뉴스 크롤링 실패: {e}")
    
    # 뉴스가 부족하면 실시간 속보에서 추가 수집
    if len(news_list) < 5:
        log("  📰 실시간 속보에서 추가 수집...")
        try:
            url2 = "https://finance.naver.com/news/news_list.naver?mode=LSS2D&section_id=101&section_id2=258"
            resp2 = requests.get(url2, headers=HEADERS, timeout=10)
            resp2.encoding = "euc-kr"
            soup2 = BeautifulSoup(resp2.text, "html.parser")
            
            for item in soup2.select("dd.articleSubject a")[:10]:
                title = item.get("title", "").strip() or item.get_text(strip=True)
                if title and not any(n["title"] == title for n in news_list):
                    news_list.append({
                        "title": title,
                        "source": "네이버금융",
                        "time_ago": "오늘",
                        "category": classify_news_category(title),
                        "sentiment": analyze_sentiment(title),
                        "summary": title,
                        "url": "",
                        "date": TODAY,
                    })
            
            log(f"  ✅ 추가 수집 후 총 {len(news_list)}개")
        except Exception as e:
            log(f"  ⚠️ 추가 수집 실패: {e}")
    
    return news_list


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


# ─────────────────────────────────────────
# 2. 인기/이슈 종목 크롤링
# ─────────────────────────────────────────
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

def crawl_issue_stocks():
    """KIS API 거래량 순위 상위 종목 조회"""
    log("📈 이슈 종목 수집 시작 (KIS API)...")

    stocks = []

    try:
        data = kis_request(
            "/uapi/domestic-stock/v1/quotations/volume-rank",
            "FHPST01710000",
            {
                "FID_COND_MRKT_DIV_CODE": "J",
                "FID_COND_SCR_DIV_CODE": "20171",
                "FID_INPUT_ISCD": "0000",
                "FID_DIV_CLS_CODE": "0",
                "FID_BLNG_CLS_CODE": "0",
                "FID_TRGT_CLS_CODE": "111111111",
                "FID_TRGT_EXLS_CLS_CODE": "000000",
                "FID_INPUT_PRICE_1": "0",
                "FID_INPUT_PRICE_2": "0",
                "FID_VOL_CNT": "0",
                "FID_INPUT_DATE_1": "0",
            },
        )
        if not data or "output" not in data:
            log("  ⚠️ 거래량 순위 데이터 없음")
            return stocks

        for i, item in enumerate(data["output"][:10]):
            name = item.get("hts_kor_isnm", "").strip()
            code = item.get("mksc_shrn_iscd", "")
            price_raw = item.get("stck_prpr", "0")
            change_pct_val = item.get("prdy_ctrt", "0")
            volume_raw = item.get("acml_vol", "0")
            sign = item.get("prdy_vrss_sign", "3")

            if not name or not code:
                continue

            trend = kis_trend(sign)
            prefix = "-" if trend == "down" else "+"
            pct_clean = change_pct_val.lstrip("+-")

            # 가격 포맷
            try:
                price_formatted = f"{int(price_raw):,}"
            except ValueError:
                price_formatted = price_raw

            # 거래량 포맷
            volume = format_trading_value(str(int(int(volume_raw) * int(price_raw) / 100000000))) if volume_raw.isdigit() and price_raw.isdigit() else volume_raw

            stocks.append({
                "rank": i + 1,
                "name": name,
                "code": code,
                "price": price_formatted,
                "change_pct": f"{prefix}{pct_clean}%",
                "volume": volume,
                "reason": f"거래량 상위 {i + 1}위",
                "tags": classify_stock_tags(name),
                "trend": trend,
                "date": TODAY,
            })

        log(f"  ✅ 거래량 상위 {len(stocks)}개 수집 완료")

    except Exception as e:
        log(f"  ❌ 거래량 순위 조회 실패: {e}")

    return stocks


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


# ─────────────────────────────────────────
# 3. 시장 지수 크롤링
# ─────────────────────────────────────────
def crawl_market_index():
    """시장 지수 수집 (KIS API: 국내, Yahoo: 해외, 네이버: 환율)"""
    log("📊 시장 지수 수집 시작...")

    indices = []

    # 국내 지수 (KIS API)
    for idx_name, idx_code in [("코스피", "0001"), ("코스닥", "1001")]:
        try:
            data = kis_request(
                "/uapi/domestic-stock/v1/quotations/inquire-index-price",
                "FHPUP02100000",
                {"FID_COND_MRKT_DIV_CODE": "U", "FID_INPUT_ISCD": idx_code},
            )
            if not data or "output" not in data:
                log(f"  ⚠️ {idx_name} 데이터 없음")
                continue

            o = data["output"]
            value = o.get("bstp_nmix_prpr", "0")
            change_amt = o.get("bstp_nmix_prdy_vrss", "0")
            change_pct_val = o.get("bstp_nmix_prdy_ctrt", "0")
            sign = o.get("prdy_vrss_sign", "3")
            trend = kis_trend(sign)

            # 부호 포맷
            prefix = "-" if trend == "down" else "+"
            change_amt_clean = change_amt.lstrip("+-")
            change_pct_clean = change_pct_val.lstrip("+-")

            indices.append({
                "name": idx_name,
                "value": value,
                "change_amount": f"{prefix}{change_amt_clean}",
                "change_pct": f"{prefix}{change_pct_clean}%",
                "trend": trend,
            })
        except Exception as e:
            log(f"  ❌ {idx_name} KIS API 실패: {e}")

    log(f"  ✅ 국내 지수 {len(indices)}개 수집")

    # 해외 지수 (Yahoo Finance API - 네이버 월드 페이지 데이터 부정확하여 대체)
    world_indices = [
        ("다우존스", "%5EDJI"),
        ("나스닥", "%5EIXIC"),
        ("S&P 500", "%5EGSPC"),
    ]

    for name, symbol in world_indices:
        try:
            api_url = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?interval=1d&range=1d"
            resp2 = requests.get(api_url, headers={"User-Agent": HEADERS["User-Agent"]}, timeout=10)
            data = resp2.json()
            meta = data["chart"]["result"][0]["meta"]

            price = meta.get("regularMarketPrice", 0)
            prev = meta.get("chartPreviousClose", 0) or meta.get("previousClose", 0)

            if prev and prev > 0:
                change = round(price - prev, 2)
                pct = round((change / prev) * 100, 2)
                trend = "down" if change < 0 else "up"

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
            log(f"  ⚠️ {name} 조회 실패: {ex}")

    log(f"  ✅ 해외 지수 포함 총 {len(indices)}개")

    # 환율
    # HTML 구조: <div class="head_info point_dn"><span class="value">1,448.50</span><span class="change"> 2.50</span><span class="blind">하락</span></div>
    try:
        url3 = "https://finance.naver.com/marketindex/"
        resp3 = requests.get(url3, headers=HEADERS, timeout=10)
        resp3.encoding = "euc-kr"
        soup3 = BeautifulSoup(resp3.text, "html.parser")

        usd_area = soup3.select_one("#exchangeList .head.usd")
        if usd_area:
            val_el = usd_area.select_one(".value")
            change_el = usd_area.select_one(".change")
            head_info = usd_area.select_one(".head_info")

            usd_val = val_el.get_text(strip=True) if val_el else "0"
            change_val = change_el.get_text(strip=True) if change_el else "0"

            # 상승/하락: .head_info 클래스에 point_dn/point_up
            is_down = head_info and "point_dn" in " ".join(head_info.get("class", []))
            trend = "down" if is_down else "up"

            # 변동률 계산
            change_pct = ""
            try:
                val_num = float(usd_val.replace(",", ""))
                change_num = float(change_val.replace(",", ""))
                if val_num > 0:
                    pct = round(change_num / val_num * 100, 2)
                    change_pct = f"-{pct}%" if is_down else f"+{pct}%"
            except:
                change_pct = "0.00%"

            change_val_clean = change_val.strip().lstrip("+-")
            indices.append({
                "name": "USD/KRW",
                "value": usd_val,
                "change_amount": f"-{change_val_clean}" if is_down else f"+{change_val_clean}",
                "change_pct": change_pct,
                "trend": trend,
            })
            log(f"  ✅ 환율 수집 완료")

    except Exception as e:
        log(f"  ⚠️ 환율 크롤링 실패: {e}")

    return indices


# ─────────────────────────────────────────
# 4. 섹터 데이터 크롤링
# ─────────────────────────────────────────
def crawl_sectors():
    """KIS API 업종별 시세 조회"""
    log("🏭 섹터 데이터 수집 시작 (KIS API)...")

    sectors = []

    # 섹터 매핑: 표시명 → (KIS 업종코드, 아이콘)
    sector_map = [
        ("반도체",    "0013", "⚡"),   # 전기전자
        ("2차전지",   "0013", "🔋"),   # 전기전자 (동일 업종)
        ("바이오",    "0009", "🧬"),   # 의약품
        ("자동차",    "0015", "🚗"),   # 운수장비
        ("IT/플랫폼", "0026", "💻"),   # 서비스업
        ("금융",      "0021", "🏦"),   # 금융업
        ("철강/소재", "0011", "⚙️"),   # 철강금속
        ("건설",      "0018", "🏗️"),   # 건설업
    ]

    seen_codes = set()

    for sname, idx_code, icon in sector_map:
        # 같은 업종코드(예: 반도체/2차전지 둘 다 0013)는 한 번만 조회
        if idx_code in seen_codes:
            # 이전 결과 복사
            prev = next((s for s in sectors if s.get("_code") == idx_code), None)
            if prev:
                sectors.append({
                    "name": sname,
                    "change_pct": prev["change_pct"],
                    "trend": prev["trend"],
                    "stock_count": 10,
                    "icon": icon,
                    "top_stock": "",
                    "description": "",
                })
            continue

        seen_codes.add(idx_code)

        try:
            data = kis_request(
                "/uapi/domestic-stock/v1/quotations/inquire-index-price",
                "FHPUP02100000",
                {"FID_COND_MRKT_DIV_CODE": "U", "FID_INPUT_ISCD": idx_code},
            )
            if not data or "output" not in data:
                sectors.append({
                    "name": sname, "change_pct": "0.00%", "trend": "flat",
                    "stock_count": 10, "icon": icon, "top_stock": "", "description": "",
                })
                continue

            o = data["output"]
            change_pct_val = o.get("bstp_nmix_prdy_ctrt", "0")
            sign = o.get("prdy_vrss_sign", "3")
            trend = kis_trend(sign)

            prefix = "-" if trend == "down" else ("" if trend == "flat" else "+")
            pct_clean = change_pct_val.lstrip("+-")
            pct = f"{prefix}{pct_clean}%" if trend != "flat" else "0.00%"

            sectors.append({
                "name": sname,
                "change_pct": pct,
                "trend": trend,
                "stock_count": 10,
                "icon": icon,
                "top_stock": "",
                "description": "",
                "_code": idx_code,  # 중복 조회 방지용 (Supabase 저장 시 제거)
            })

        except Exception as e:
            log(f"  ❌ {sname} 업종 조회 실패: {e}")
            sectors.append({
                "name": sname, "change_pct": "0.00%", "trend": "flat",
                "stock_count": 10, "icon": icon, "top_stock": "", "description": "데이터 수집 중",
            })

        time.sleep(0.1)  # API 속도 제한 대비

    # _code 필드 제거 (Supabase에 저장하지 않음)
    for s in sectors:
        s.pop("_code", None)

    log(f"  ✅ 섹터 {len(sectors)}개 수집 완료")
    return sectors


# ─────────────────────────────────────────
# 5. 섹터별 종목 크롤링
# ─────────────────────────────────────────
def crawl_sector_stocks():
    """네이버 금융 업종 상세 페이지에서 각 섹터의 상위 종목 크롤링"""
    log("🏷️ 섹터별 종목 크롤링 시작...")

    # 섹터명 → 네이버 업종 코드 매핑
    sector_codes = {
        "반도체": 278,
        "2차전지": 306,    # 전기장비
        "바이오": 286,     # 생물공학
        "자동차": 273,
        "IT/플랫폼": 267,  # IT서비스
        "금융": 301,       # 은행
        "철강/소재": 304,  # 철강
        "건설": 279,
    }

    all_stocks = []

    for sector_name, sector_no in sector_codes.items():
        try:
            url = f"https://finance.naver.com/sise/sise_group_detail.naver?type=upjong&no={sector_no}"
            resp = requests.get(url, headers=HEADERS, timeout=10)
            resp.encoding = "euc-kr"
            soup = BeautifulSoup(resp.text, "html.parser")

            table = soup.select_one("table.type_5")
            if not table:
                log(f"  ⚠️ {sector_name}: 테이블 없음")
                continue

            rank = 0
            for row in table.select("tr"):
                cols = row.select("td")
                if len(cols) < 6:
                    continue

                name_tag = cols[0].find("a")
                if not name_tag:
                    continue

                stock_name = name_tag.get_text(strip=True)
                href = name_tag.get("href", "")
                code_match = re.search(r"code=(\d{6})", href)
                code = code_match.group(1) if code_match else ""

                if not code:
                    continue

                rank += 1
                if rank > 10:
                    break

                price = cols[1].get_text(strip=True).replace(",", "")
                change_pct_text = cols[3].get_text(strip=True)

                # 상승/하락 판별
                pct_check = change_pct_text.replace("%", "").replace("+", "").replace("-", "").strip()
                is_zero = (pct_check == "0.00" or pct_check == "0" or pct_check == "")

                if is_zero:
                    trend = "flat"
                else:
                    img = cols[2].find("img")
                    if img:
                        alt = img.get("alt", "")
                        is_down = "하락" in alt
                    else:
                        is_down = "-" in change_pct_text
                    trend = "down" if is_down else "up"

                # 가격 포맷
                try:
                    price_formatted = f"{int(price):,}"
                except:
                    price_formatted = price

                # 등락률 부호
                pct_clean = change_pct_text.replace("%", "").replace("+", "").replace("-", "").strip()
                if trend == "flat" or not pct_clean:
                    change_pct = "0.00%"
                elif trend == "down":
                    change_pct = f"-{pct_clean}%"
                else:
                    change_pct = f"+{pct_clean}%"

                all_stocks.append({
                    "sector_name": sector_name,
                    "stock_name": stock_name,
                    "code": code,
                    "price": price_formatted,
                    "change_pct": change_pct,
                    "trend": trend,
                    "rank": rank,
                })

            log(f"  ✅ {sector_name}: {rank}개 종목 수집")
            time.sleep(0.5)

        except Exception as e:
            log(f"  ❌ {sector_name} 크롤링 실패: {e}")

    log(f"  ✅ 섹터별 종목 총 {len(all_stocks)}개 수집 완료")
    return all_stocks


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

    if not KIS_APP_KEY or not KIS_APP_SECRET:
        log("❌ KIS API 키가 설정되지 않았습니다!")
        log("  export KIS_APP_KEY='발급받은_앱키'")
        log("  export KIS_APP_SECRET='발급받은_시크릿키'")
        return
    
    # 1. 뉴스 크롤링
    news = crawl_news()
    time.sleep(1)
    
    # 2. 이슈 종목 크롤링
    stocks = crawl_issue_stocks()
    time.sleep(1)
    
    # 3. 시장 지수 크롤링
    indices = crawl_market_index()
    time.sleep(1)
    
    # 4. 섹터 데이터 크롤링
    sectors = crawl_sectors()
    time.sleep(1)

    # 5. 섹터별 종목 크롤링
    sector_stocks = crawl_sector_stocks()

    # ─── Supabase에 저장 ───
    log("")
    log("💾 Supabase에 데이터 저장 중...")

    # 기존 데이터 정리
    clear_today_data("news")
    clear_today_data("issue_stocks")
    clear_today_data("market_index")
    clear_today_data("sectors")
    supabase_request("DELETE", "sector_stocks", params={"id": "gt.0"})

    # 뉴스 저장
    if news:
        result = supabase_request("POST", "news", data=news)
        log(f"  📰 뉴스 {len(news)}개 저장 {'✅' if result else '❌'}")

    # 종목 저장
    if stocks:
        result = supabase_request("POST", "issue_stocks", data=stocks)
        log(f"  📈 종목 {len(stocks)}개 저장 {'✅' if result else '❌'}")

    # 지수 저장
    if indices:
        result = supabase_request("POST", "market_index", data=indices)
        log(f"  📊 지수 {len(indices)}개 저장 {'✅' if result else '❌'}")

    # 섹터 저장
    if sectors:
        result = supabase_request("POST", "sectors", data=sectors)
        log(f"  🏭 섹터 {len(sectors)}개 저장 {'✅' if result else '❌'}")

    # 섹터별 종목 저장
    if sector_stocks:
        result = supabase_request("POST", "sector_stocks", data=sector_stocks)
        log(f"  🏷️ 섹터 종목 {len(sector_stocks)}개 저장 {'✅' if result else '❌'}")
    
    log("")
    log("=" * 50)
    log("✅ 크롤링 완료!")
    log("=" * 50)


if __name__ == "__main__":
    main()
