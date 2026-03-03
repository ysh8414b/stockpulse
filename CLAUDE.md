# STOCKPULSE 프로젝트 컨텍스트

> **규칙**: 대화 중 코드 수정, 새로운 기능 추가, 버그 수정, 알려진 이슈 등 중요한 변경이 발생하면 이 파일을 즉시 업데이트할 것. 수정 이력 섹션에 날짜와 함께 기록.

## 프로젝트 구조
- `index.html` — React 18 SPA (프론트엔드 전체, CDN 기반)
- `crawl.py` — Python 크롤러 (데이터 수집/가공, GitHub Actions로 실행)
- `.github/workflows/crawl.yml` — 장중 5분 간격 + 장 마감 후 1회 실행
- 데이터 저장: Supabase (PostgreSQL)
- 차트: 외부 라이브러리 없이 SVG polyline 직접 렌더링

## 데이터 소스
- 네이버 금융 API (메인): 전종목 시세 (업종 정보 없음)
- 네이버 금융 PC 업종 페이지: 섹터 매핑 (code → display_sector)
- Yahoo Finance API: 시장 지수/환율 + 스파크라인 데이터
- 네이버 검색 API: 뉴스, 테마 관련 뉴스
- Groq AI (주 1회): 뉴스 기반 인기 테마 감지
- Groq AI (매 크롤링): 시장 브리핑 자동 생성 → `ai_summary` 테이블

## 주요 수정 이력

### 스파크라인 다운샘플링
- `crawl.py` MAX_POINTS = 70 (LTTB 알고리즘)
- 처음 30 → 50 → 70으로 변경

### 섹터 자동 분류 시스템 (수동 매핑 → 네이버 업종 기반)
- 기존 CODE_SECTOR_MAP 수동 매핑 (~60개) 삭제
- `fetch_naver_sector_map()`: 네이버 업종별 페이지에서 전종목 자동 분류 (2728개+)
- `NAVER_SECTOR_MAP`: 네이버 79개 업종 ID → 10개 디스플레이 섹터
- 10개 섹터: 반도체, 2차전지, 바이오, 자동차, IT/플랫폼, 금융, 소비재, 철강/소재, 에너지, 건설
- 캐시: `sector_map.json` (일 1회, 7일 유효)
- KRX API는 차단되어 사용 불가 → 네이버로 전환
- `_sub_classify_sector()`: KRX fallback 시 화학→소비재 보정용

### 테마 시스템
- 뉴스 키워드 매칭 기반 동적 선정 (매 크롤링마다 변동)
- 순위: 1차 뉴스 언급 빈도, 2차 평균 등락률
- 장 마감 후에도 뉴스 변동으로 테마 구성 바뀔 수 있음

### AI 분석 탭 → AI 브리핑 탭 전환 (2026-03-02)
- 기존: 브라우저에서 Anthropic API 직접 호출 (작동 안 됨 — API 키 없음 + CORS 차단)
- 변경: 크롤링 시 Groq AI로 시장 브리핑 생성 → Supabase `ai_summary` 저장 → 프론트에서 읽기만
- `generate_ai_summary()`: Groq llama-3.3-70b 모델, 지수/종목/섹터/테마/뉴스 데이터 입력
- 출력: `{summary, market_mood(bullish/bearish/neutral), date}`
- 탭 이름: "AI 분석" → "AI 브리핑"
- Supabase 테이블 `ai_summary` 필요 (id, summary, market_mood, date)

### 섹터 분석 탭 삭제 (2026-03-02)
- `TabSectors` 컴포넌트 및 탭 네비게이션에서 "섹터 분석" 항목 제거
- 시장 개요(TabOverview)의 섹터별 등락 카드(SectorCard)는 유지
- SectorStockList, SectorStockRow 컴포넌트도 유지 (시장 개요에서 사용)

### 호버 효과 + 링크 이동 (2026-03-02)
- `SectorStockRow` 컴포넌트: 섹터 종목 호버 시 이름 확대(14px, bold, 보라색) + 배경 하이라이트, 클릭 시 네이버 증권 이동
- `NewsRow` 컴포넌트: 시장개요 뉴스 호버 시 제목 확대(14px, bold, 파란색) + 배경 하이라이트, 클릭 시 뉴스 기사 링크 새 탭
- 시장 지수 카드 클릭 시 네이버 증권 지수/환율 페이지로 이동 (코스피, 코스닥, 다우, 나스닥, S&P500, USD/KRW)
- 섹터별 종목 클릭: `finance.naver.com/item/main.naver?code={code}` (PC 버전)
- `e.stopPropagation()`으로 섹터 카드 접기/펼치기와 충돌 방지

### 인기테마 뉴스 드롭다운 (2026-03-02)
- `ThemeNewsDropdown` 컴포넌트: 테마 뉴스 제목 호버 시 관련 최신뉴스 5개 드롭다운
- `ThemeItem` 래퍼 컴포넌트: 드롭다운 열릴 때 z-index:50으로 겹침 방지
- `_search_theme_news_api()`: 멀티 쿼리 검색 (테마+종목, 테마단독, 테마+관련주)
- `_is_similar_title()`: 제목 유사도 필터 (threshold 0.5) — 중복 뉴스 제거
- 키워드 필터링: 뉴스 제목에 테마 키워드가 포함된 것만 노출
- Supabase `themes` 테이블에 `news_list` (jsonb) 컬럼 추가 필요

### 이슈 종목 복합 점수 랭킹 (2026-03-02)
- 기존: 거래대금 상위 10개 단순 정렬
- 변경: 5가지 기준 종합 점수 랭킹 (TOP 15)
- 필터: 거래대금 1000억 이상
- 점수 비중: 등락률 절대값(25%) + 거래대금 순위(25%) + 인기테마 소속(20%) + 뉴스 언급(20%) + 상승섹터 소속(10%)
- `reason` 필드에 선정 사유 표시 (예: "인기테마 · 뉴스언급 · 급등")
- `main()` 호출 순서: themes/sectors/news 이후로 이동 (데이터 의존성)
- 함수 시그니처: `crawl_issue_stocks(krx_data, themes=None, sectors=None, news=None)`

### 이슈 종목 관련 뉴스 (2026-03-02)
- 기존: 클라이언트에서 일반 뉴스 제목에 종목명 포함 여부로 매칭 → 거의 매칭 안 됨
- 변경: `crawl_issue_stocks()`에서 종목별 관련 뉴스를 직접 수집하여 `related_news` JSON 필드에 저장
- `fetch_stock_news()`: 네이버 검색 API로 "{종목명} 주가" 쿼리, 종목당 최대 3건
- 2단계 매칭: 1) 기존 뉴스 목록에서 제목/요약 매칭 → 2) 부족하면 네이버 API 추가 검색
- Supabase `issue_stocks` 테이블에 `related_news` (text) 컬럼 추가 필요
- 프론트엔드: `related_news` JSON 파싱 우선 사용, fallback으로 클라이언트 매칭

### 테마 키워드 DB 관리 시스템 (2026-03-03)
- 기존: `NEWS_THEME_KEYWORDS` 딕셔너리에 키워드 하드코딩 → 수정 시 코드 변경 필요
- 변경: Supabase `theme_keywords` 테이블에서 추가 키워드를 읽어와 코드 키워드와 병합
- `load_theme_keywords_from_db()`: 크롤링 시 DB에서 `enabled=true`인 키워드 로딩 → `NEWS_THEME_KEYWORDS`에 병합
- `detect_themes_rule_based()` 시작 시 자동 호출
- 코드 키워드(기본) + DB 키워드(추가분) 병합 구조 → DB 실패 시 코드 키워드만으로 정상 작동
- Supabase `theme_keywords` 테이블 필요 (id, theme, keyword, enabled, memo, created_at)
- `setup_theme_keywords.sql` 파일에 테이블 생성 + 초기 데이터 SQL 포함

### 방산 테마 키워드 대폭 확장 (2026-03-03)
- 기존: 8개 (방산, 방위, 무기, 미사일, K방산, 한화에어로, LIG넥스원, K9)
- 변경: 38개 — 기업명(한화시스템, 현대로템, 한국항공우주, 한화디펜스, 풍산), 무기체계(KF-21, K2전차, 천무, FA-50, 잠수함, 이지스, 천궁, L-SAM), 지정학(우크라이나, 폴란드, NATO), 일반(국방, 군사, 군수, 전투기, 방위사업, 방사청, 요격, 스텔스, 정찰위성 등)
- 원인: 뉴스 매칭 키워드 부족으로 방산 테마가 상위 10위 안에 진입 못함 → 이슈 종목에서 방산주 누락

### 전체 테마 검색/탐색 기능 (2026-03-03)
- 기존: 인기 테마 TOP 10만 표시, 그 외 테마는 볼 수 없음
- 변경: `all_themes` 테이블에 전체 테마 데이터 저장 + 검색 UI 추가
- `build_all_themes_data()`: `theme_map`의 모든 테마를 KRX 데이터로 enrichment (뉴스 제외)
- 데이터: rank, name, change_pct, up/flat/down_count, leading_stocks, stock_count, trend, is_top, date
- Supabase `all_themes` 테이블 필요 (`setup_theme_keywords.sql`에 CREATE TABLE 포함)
- 프론트엔드: 검색 input + TOP 10 (기존) + 전체 테마 접기/펼치기 + AllThemeItem 컴포넌트
- 검색 모드: TOP 10 + 전체 테마 동시 필터링, 결과 없으면 Empty 메시지
- `main()`에서 `crawl_themes()` 직후 `build_all_themes_data()` 호출

## 알려진 이슈
- KRX API (`data.krx.co.kr`) 차단됨 — fallback으로만 사용
- 네이버 섹터 매핑 첫 실행 시 ~60초 소요 (79개 업종 페이지 순차 조회)
- 테마 순위가 장 마감 후에도 변동됨 (뉴스 갱신 때문)

## 개발 서버
- `python -m http.server 8000` (launch.json 설정됨)
