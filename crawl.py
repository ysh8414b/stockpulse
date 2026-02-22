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
def crawl_issue_stocks():
    """네이버 금융 인기 종목 크롤링 (거래량 상위 + 상승률 상위)"""
    log("📈 이슈 종목 크롤링 시작...")
    
    stocks = []
    seen_codes = set()
    
    # 1) 거래량 상위 종목
    try:
        url = "https://finance.naver.com/sise/sise_quant.naver"
        resp = requests.get(url, headers=HEADERS, timeout=10)
        resp.encoding = "euc-kr"
        soup = BeautifulSoup(resp.text, "html.parser")
        
        rows = soup.select("table.type_2 tr")
        rank = 1
        
        for row in rows:
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
            change_text = cols[3].get_text(strip=True).replace(",", "")
            change_pct_text = cols[4].get_text(strip=True)
            volume = cols[5].get_text(strip=True)
            
            # 상승/하락 판별
            img = cols[3].find("img")
            if img:
                alt = img.get("alt", "")
                if "상승" in alt:
                    trend = "up"
                    change_pct = f"+{change_pct_text}"
                elif "하락" in alt:
                    trend = "down"
                    change_pct = f"-{change_pct_text}"
                else:
                    trend = "up"
                    change_pct = change_pct_text
            else:
                # 텍스트로 판별
                trend = "down" if "-" in change_text else "up"
                change_pct = change_pct_text
            
            if not change_pct.startswith(("+", "-")):
                change_pct = f"+{change_pct}" if trend == "up" else f"-{change_pct}"
            
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
                "reason": f"거래량 상위 {rank}위",
                "tags": tags,
                "trend": trend,
                "date": TODAY,
            })
            
            rank += 1
            if rank > 10:
                break
        
        log(f"  ✅ 이슈 종목 {len(stocks)}개 수집 완료")
        
    except Exception as e:
        log(f"  ❌ 이슈 종목 크롤링 실패: {e}")
    
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
                volume = cols[5].get_text(strip=True) if len(cols) > 5 else "0"
                
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
                    "change_pct": f"+{change_pct_text}",
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
    try:
        url = "https://finance.naver.com/sise/"
        resp = requests.get(url, headers=HEADERS, timeout=10)
        resp.encoding = "euc-kr"
        soup = BeautifulSoup(resp.text, "html.parser")
        
        # 코스피
        kospi_val = soup.select_one("#KOSPI_now")
        kospi_change = soup.select_one("#KOSPI_change")
        if kospi_val:
            val = kospi_val.get_text(strip=True)
            change_text = kospi_change.get_text(strip=True) if kospi_change else "0"
            # 변동량과 변동률 분리
            parts = change_text.split()
            change_amt = parts[0] if parts else "0"
            change_pct_raw = parts[1] if len(parts) > 1 else "0%"
            
            # 상승/하락 판별
            kospi_img = soup.select_one("#KOSPI_change img")
            if kospi_img and "하락" in kospi_img.get("alt", ""):
                trend = "down"
                change_amt = f"-{change_amt.lstrip('-')}"
                change_pct = f"-{change_pct_raw.strip('%')}%"
            else:
                trend = "up"
                change_amt = f"+{change_amt.lstrip('+')}"
                change_pct = f"+{change_pct_raw.strip('%')}%"
            
            indices.append({
                "name": "코스피",
                "value": val,
                "change_amount": change_amt,
                "change_pct": change_pct,
                "trend": trend,
            })
        
        # 코스닥
        kosdaq_val = soup.select_one("#KOSDAQ_now")
        kosdaq_change = soup.select_one("#KOSDAQ_change")
        if kosdaq_val:
            val = kosdaq_val.get_text(strip=True)
            change_text = kosdaq_change.get_text(strip=True) if kosdaq_change else "0"
            parts = change_text.split()
            change_amt = parts[0] if parts else "0"
            change_pct_raw = parts[1] if len(parts) > 1 else "0%"
            
            kosdaq_img = soup.select_one("#KOSDAQ_change img")
            if kosdaq_img and "하락" in kosdaq_img.get("alt", ""):
                trend = "down"
                change_amt = f"-{change_amt.lstrip('-')}"
                change_pct = f"-{change_pct_raw.strip('%')}%"
            else:
                trend = "up"
                change_amt = f"+{change_amt.lstrip('+')}"
                change_pct = f"+{change_pct_raw.strip('%')}%"
            
            indices.append({
                "name": "코스닥",
                "value": val,
                "change_amount": change_amt,
                "change_pct": change_pct,
                "trend": trend,
            })
        
        log(f"  ✅ 국내 지수 {len(indices)}개 수집")
        
    except Exception as e:
        log(f"  ❌ 국내 지수 크롤링 실패: {e}")
    
    # 해외 지수 (네이버 금융 월드 지수)
    try:
        url2 = "https://finance.naver.com/world/"
        resp2 = requests.get(url2, headers=HEADERS, timeout=10)
        resp2.encoding = "euc-kr"
        soup2 = BeautifulSoup(resp2.text, "html.parser")
        
        world_indices = {
            "다우존스": "DJI@DJI",
            "나스닥": "NAS@IXIC",
            "S&P 500": "SPI@SPX",
        }
        
        for name, code in world_indices.items():
            try:
                item = soup2.select_one(f"a[href*='{code}']")
                if item:
                    parent = item.find_parent("tr") or item.find_parent("div")
                    if parent:
                        texts = parent.get_text(" ", strip=True)
                        # 간단한 파싱 시도
                        nums = re.findall(r'[\d,]+\.?\d*', texts)
                        if nums:
                            indices.append({
                                "name": name,
                                "value": nums[0],
                                "change_amount": nums[1] if len(nums) > 1 else "0",
                                "change_pct": f"{nums[2]}%" if len(nums) > 2 else "0%",
                                "trend": "up",  # 기본값
                            })
            except:
                pass
        
        log(f"  ✅ 해외 지수 포함 총 {len(indices)}개")
        
    except Exception as e:
        log(f"  ⚠️ 해외 지수 크롤링 실패: {e}")
    
    # 환율
    try:
        url3 = "https://finance.naver.com/marketindex/"
        resp3 = requests.get(url3, headers=HEADERS, timeout=10)
        resp3.encoding = "euc-kr"
        soup3 = BeautifulSoup(resp3.text, "html.parser")
        
        usd_area = soup3.select_one(".market1 .usd")
        if usd_area:
            val = usd_area.select_one(".value")
            change = usd_area.select_one(".change")
            if val:
                usd_val = val.get_text(strip=True)
                change_val = change.get_text(strip=True) if change else "0"
                
                # 상승/하락
                is_down = "하락" in usd_area.get_text()
                indices.append({
                    "name": "USD/KRW",
                    "value": usd_val,
                    "change_amount": f"-{change_val}" if is_down else f"+{change_val}",
                    "change_pct": "",
                    "trend": "down" if is_down else "up",
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
    
    # 섹터 매핑 (네이버 금융 업종 코드)
    sector_map = {
        "반도체": {"code": "261", "icon": "⚡"},
        "2차전지": {"code": "247", "icon": "🔋"},
        "바이오": {"code": "227", "icon": "🧬"},
        "자동차": {"code": "202", "icon": "🚗"},
        "IT/플랫폼": {"code": "230", "icon": "💻"},
        "금융": {"code": "301", "icon": "🏦"},
        "철강/소재": {"code": "206", "icon": "⚙️"},
        "건설": {"code": "207", "icon": "🏗️"},
    }
    
    try:
        # 네이버 금융 업종별 시세
        url = "https://finance.naver.com/sise/sise_group.naver?type=upjong"
        resp = requests.get(url, headers=HEADERS, timeout=10)
        resp.encoding = "euc-kr"
        soup = BeautifulSoup(resp.text, "html.parser")
        
        rows = soup.select("table.type_1 tr")
        
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
        for sname, sinfo in sector_map.items():
            # 네이버 업종명과 매칭 시도
            pct = "0.00%"
            for upjong, val in sector_data.items():
                if any(keyword in upjong for keyword in sname.split("/")):
                    pct = val
                    break
            
            # +/- 판별
            try:
                pct_num = float(pct.replace("%", "").replace("+", "").replace("-", ""))
                trend = "down" if "-" in pct or pct_num < 0 else "up"
                if not pct.startswith(("+", "-")):
                    pct = f"+{pct}" if trend == "up" else f"-{pct}"
            except:
                trend = "up"
                pct = "+0.00%"
            
            sectors.append({
                "name": sname,
                "change_pct": pct,
                "trend": trend,
                "stock_count": 10,  # 기본값
                "icon": sinfo["icon"],
                "top_stock": "",
                "description": "",
            })
        
        log(f"  ✅ 섹터 {len(sectors)}개 수집 완료")
        
    except Exception as e:
        log(f"  ❌ 섹터 크롤링 실패: {e}")
        # 실패 시 기본값
        for sname, sinfo in sector_map.items():
            sectors.append({
                "name": sname, "change_pct": "+0.00%", "trend": "up",
                "stock_count": 0, "icon": sinfo["icon"],
                "top_stock": "", "description": "데이터 수집 중",
            })
    
    return sectors


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
    
    # ─── Supabase에 저장 ───
    log("")
    log("💾 Supabase에 데이터 저장 중...")
    
    # 기존 데이터 정리
    clear_today_data("news")
    clear_today_data("issue_stocks")
    clear_today_data("market_index")
    clear_today_data("sectors")
    
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
    
    log("")
    log("=" * 50)
    log("✅ 크롤링 완료!")
    log("=" * 50)


if __name__ == "__main__":
    main()
