"""
STOCKPULSE 크롤러
네이버 금융에서 뉴스, 인기종목, 시장지수, 섹터 데이터를 크롤링하여 Supabase에 저장

사용법:
  pip install requests beautifulsoup4 supabase
  
  환경변수 설정:
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_KEY=your-service-role-key  (⚠️ service_role key 사용!)
  
  python crawl.py
"""

import os
import re
import json
import time
from datetime import datetime, timedelta
from typing import Optional

import requests
from bs4 import BeautifulSoup

# ─────────────────────────────────────────
# 설정
# ─────────────────────────────────────────
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://mmmpqmvwpuxqyxlxytsh.supabase.co")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")  # service_role key (GitHub Secrets에 저장)

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


def clear_today_data(table):
    """데이터 삭제 (중복 방지)"""
    if table in ("market_index", "sectors", "issue_stocks"):
        # 항상 최신 데이터만 유지 (전체 교체)
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
    """네이버 금융 인기 종목 크롤링 (거래대금 상위 + 상승률 상위)"""
    log("📈 이슈 종목 크롤링 시작...")

    stocks = []
    seen_codes = set()

    # 1) 거래대금 상위 종목
    # sise_quant_high.naver 컬럼 순서:
    # cols[0]=N, cols[1]=거래대금(억), cols[2]=종목명, cols[3]=현재가, cols[4]=전일비, cols[5]=등락률
    try:
        url = "https://finance.naver.com/sise/sise_quant_high.naver"
        resp = requests.get(url, headers=HEADERS, timeout=10)
        resp.encoding = "euc-kr"
        soup = BeautifulSoup(resp.text, "html.parser")

        rows = soup.select("table.type_2 tr")
        rank = 1

        for row in rows:
            cols = row.select("td")
            if len(cols) < 6:
                continue

            name_tag = cols[2].find("a")
            if not name_tag:
                continue

            name = name_tag.get_text(strip=True)
            href = name_tag.get("href", "")
            code_match = re.search(r"code=(\d{6})", href)
            code = code_match.group(1) if code_match else ""

            if not code or code in seen_codes:
                continue

            price = cols[3].get_text(strip=True).replace(",", "")
            change_pct_text = cols[5].get_text(strip=True)
            volume_raw = cols[1].get_text(strip=True)
            volume = format_trading_value(volume_raw)

            # 상승/하락 판별 (등락률의 +/- 부호로 판별)
            if change_pct_text.startswith("-"):
                trend = "down"
                change_pct = change_pct_text
            elif change_pct_text.startswith("+") and change_pct_text != "+0.00%":
                trend = "up"
                change_pct = change_pct_text
            else:
                pct_num = change_pct_text.replace("%", "").replace("+", "").replace("-", "").strip()
                if pct_num in ("0.00", "0", ""):
                    trend = "flat"
                    change_pct = "0.00%"
                else:
                    trend = "up"
                    change_pct = f"+{change_pct_text}" if not change_pct_text.startswith("+") else change_pct_text

            # 가격 포맷
            try:
                price_formatted = f"{int(price):,}"
            except:
                price_formatted = price

            # 태그 자동 분류
            tags = classify_stock_tags(name)

            seen_codes.add(code)
            stocks.append({
                "rank": rank,
                "name": name,
                "code": code,
                "price": price_formatted,
                "change_pct": change_pct,
                "volume": volume,
                "reason": f"거래대금 상위 {rank}위",
                "tags": tags,
                "trend": trend,
                "date": TODAY,
            })

            rank += 1
            if rank > 10:
                break

        log(f"  ✅ 거래대금 상위 {len(stocks)}개 수집 완료")

    except Exception as e:
        log(f"  ❌ 거래대금 상위 크롤링 실패: {e}")
    
    # 2) 상승률 상위에서 추가 (부족할 경우)
    if len(stocks) < 10:
        try:
            url2 = "https://finance.naver.com/sise/sise_rise.naver"
            resp2 = requests.get(url2, headers=HEADERS, timeout=10)
            resp2.encoding = "euc-kr"
            soup2 = BeautifulSoup(resp2.text, "html.parser")
            
            for row in soup2.select("table.type_2 tr"):
                cols = row.select("td")
                if len(cols) < 6:
                    continue
                name_tag = cols[1].find("a")
                if not name_tag:
                    continue
                
                name = name_tag.get_text(strip=True)
                href = name_tag.get("href", "")
                code_match = re.search(r"code=(\d{6})", href)
                code = code_match.group(1) if code_match else ""
                
                if not code or code in seen_codes:
                    continue
                
                price = cols[2].get_text(strip=True).replace(",", "")
                change_pct_text = cols[4].get_text(strip=True)
                volume = "-"
                
                try:
                    price_formatted = f"{int(price):,}"
                except:
                    price_formatted = price
                
                seen_codes.add(code)
                rank = len(stocks) + 1
                stocks.append({
                    "rank": rank,
                    "name": name,
                    "code": code,
                    "price": price_formatted,
                    "change_pct": change_pct_text if change_pct_text.startswith("+") else f"+{change_pct_text}",
                    "volume": volume,
                    "reason": f"상승률 상위",
                    "tags": classify_stock_tags(name),
                    "trend": "up",
                    "date": TODAY,
                })
                
                if len(stocks) >= 10:
                    break
            
            log(f"  ✅ 추가 수집 후 총 {len(stocks)}개")
        except Exception as e:
            log(f"  ⚠️ 상승률 추가 수집 실패: {e}")
    
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
    """네이버 금융 시장 지수 크롤링"""
    log("📊 시장 지수 크롤링 시작...")

    indices = []

    # 국내 지수
    # HTML 구조: <span id="KOSPI_change"><span class="nup/ndown"></span>131.28 +2.31%<span class="blind">상승</span></span>
    try:
        url = "https://finance.naver.com/sise/"
        resp = requests.get(url, headers=HEADERS, timeout=10)
        resp.encoding = "euc-kr"
        soup = BeautifulSoup(resp.text, "html.parser")

        for idx_name, prefix in [("코스피", "KOSPI"), ("코스닥", "KOSDAQ")]:
            val_el = soup.select_one(f"#{prefix}_now")
            change_el = soup.select_one(f"#{prefix}_change")
            if not val_el:
                continue

            val = val_el.get_text(strip=True)

            # 상승/하락 판별: ndown 클래스가 있으면 하락
            is_down = bool(change_el and change_el.select_one(".ndown"))
            trend = "down" if is_down else "up"

            change_amt = "0"
            change_pct = "0.00%"

            if change_el:
                # .blind 제거 후 텍스트 추출
                for blind in change_el.select(".blind"):
                    blind.decompose()
                raw = change_el.get_text(strip=True)
                # 정규식으로 숫자 추출: "131.28 +2.31%" or "6.71 -0.58%"
                nums = re.findall(r'[\d,.]+', raw)
                pct_match = re.search(r'([\d,.]+)\s*%', raw)

                if nums:
                    amt_val = nums[0]
                    change_amt = f"-{amt_val}" if is_down else f"+{amt_val}"
                if pct_match:
                    pct_val = pct_match.group(1)
                    change_pct = f"-{pct_val}%" if is_down else f"+{pct_val}%"

            indices.append({
                "name": idx_name,
                "value": val,
                "change_amount": change_amt,
                "change_pct": change_pct,
                "trend": trend,
            })

        log(f"  ✅ 국내 지수 {len(indices)}개 수집")

    except Exception as e:
        log(f"  ❌ 국내 지수 크롤링 실패: {e}")

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
    """네이버 금융 업종별 시세 크롤링"""
    log("🏭 섹터 데이터 크롤링 시작...")

    sectors = []

    # 섹터 매핑: 표시명 → (네이버 업종명 키워드 목록, 아이콘)
    sector_map = [
        ("반도체",    ["반도체와반도체장비", "반도체"],       "⚡"),
        ("2차전지",   ["전기장비", "전자장비와기기"],          "🔋"),
        ("바이오",    ["생물공학", "제약", "생명과학"],         "🧬"),
        ("자동차",    ["자동차", "자동차부품"],                "🚗"),
        ("IT/플랫폼", ["IT서비스", "소프트웨어"],              "💻"),
        ("금융",      ["은행", "증권", "기타금융"],            "🏦"),
        ("철강/소재", ["철강", "비철금속", "화학"],            "⚙️"),
        ("건설",      ["건설", "건축자재"],                    "🏗️"),
    ]

    try:
        url = "https://finance.naver.com/sise/sise_group.naver?type=upjong"
        resp = requests.get(url, headers=HEADERS, timeout=10)
        resp.encoding = "euc-kr"
        soup = BeautifulSoup(resp.text, "html.parser")

        rows = soup.select("table.type_1 tr")

        # 업종명 → 등락률 딕셔너리
        sector_data = {}
        for row in rows:
            cols = row.select("td")
            if len(cols) < 4:
                continue
            name_tag = cols[0].find("a")
            if not name_tag:
                continue
            upjong_name = name_tag.get_text(strip=True)
            change_pct = cols[1].get_text(strip=True) if len(cols) > 1 else "0%"
            sector_data[upjong_name] = change_pct

        # 사전 정의 섹터에 매핑
        for sname, keywords, icon in sector_map:
            pct = "0.00%"
            # 정확한 업종명 매칭 (첫 번째 매칭 사용)
            for kw in keywords:
                if kw in sector_data:
                    pct = sector_data[kw]
                    break

            # +/- 판별
            try:
                pct_num = float(pct.replace("%", "").replace("+", "").replace("-", ""))
                if pct_num == 0:
                    trend = "flat"
                    pct = "0.00%"
                elif "-" in pct:
                    trend = "down"
                    if not pct.startswith("-"):
                        pct = f"-{pct}"
                else:
                    trend = "up"
                    if not pct.startswith("+"):
                        pct = f"+{pct}"
            except:
                trend = "flat"
                pct = "0.00%"

            sectors.append({
                "name": sname,
                "change_pct": pct,
                "trend": trend,
                "stock_count": 10,
                "icon": icon,
                "top_stock": "",
                "description": "",
            })

        log(f"  ✅ 섹터 {len(sectors)}개 수집 완료")

    except Exception as e:
        log(f"  ❌ 섹터 크롤링 실패: {e}")
        for sname, keywords, icon in sector_map:
            sectors.append({
                "name": sname, "change_pct": "+0.00%", "trend": "up",
                "stock_count": 0, "icon": icon,
                "top_stock": "", "description": "데이터 수집 중",
            })

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
