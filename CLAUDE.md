# STOCKPULSE 프로젝트 컨텍스트

> **규칙**: 대화 중 코드 수정, 새로운 기능 추가, 버그 수정, 알려진 이슈 등 중요한 변경이 발생하면 이 파일을 즉시 업데이트할 것. 수정 이력 섹션에 날짜와 함께 기록.

## 프로젝트 구조
- `index.html` — React 18 SPA (메인 대시보드, CDN 기반)
- `analysis.html` — 일간 종목 리포트 (AI 3축 분석, 날짜별 탐색)
- `theme_detail.html` — 테마 종목 상세 (전체 종목 리스트, 정렬, 네이버 링크)
- `chat.html` — 실시간 익명 토론방 (Supabase Realtime, WebSocket)
- `board.html` — 자유게시판 (익명 글/댓글, 비밀번호 기반 삭제)
- `theme_calendar.html` — 테마 캘린더 (매일 인기 테마 TOP 3 캘린더 뷰, 날짜별 TOP 10 상세)
- `archive.html` — AI 브리핑 아카이브 (캘린더 기반 과거 브리핑 탐색)
- `guide.html` — 투자 정보 가이드 (독창적 교육 콘텐츠)
- `about.html` — 서비스 소개 + 연락처
- `privacy.html` — 개인정보처리방침
- `terms.html` — 이용약관
- `orders.html` — 자동 리스트 생성기 (발주서 → 부착리스트 엑셀 + 적재이미지 + 출고장 + 냉동재고 + 📤 냉동 출고 + 💰 판매가, 비밀번호 없이 접근)
- `style.css` — 공통 CSS (다크/라이트 테마, 반응형)
- `shared.js` — 공통 JS (Supabase 설정, db() 함수, 테마 유틸)
- `sitemap.xml` — SEO용 사이트맵
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
- 순위: 뉴스 언급 빈도(50%) + 평균 등락률(50%) 복합 점수 (2026-03-06 변경)
  - 기존: 뉴스 언급만으로 순위 → 등락률 1위 테마도 뉴스 부족하면 TOP 10 누락
  - 변경: 뉴스 정규화(50점) + 등락률 정규화(50점) 합산 → 급등 테마도 TOP 10 진입 가능
- 장 마감 후에도 뉴스 변동으로 테마 구성 바뀔 수 있음

### AI 분석 탭 → AI 브리핑 탭 전환 (2026-03-02)
- 기존: 브라우저에서 Anthropic API 직접 호출 (작동 안 됨 — API 키 없음 + CORS 차단)
- 변경: 크롤링 시 Groq AI로 시장 브리핑 생성 → Supabase `ai_summary` 저장 → 프론트에서 읽기만
- `generate_ai_summary()`: Groq llama-3.3-70b 모델, 지수/종목/섹터/테마/뉴스 데이터 입력
- 출력: `{summary, market_mood(bullish/bearish/neutral), date}`
- 탭 이름: "AI 분석" → "AI 브리핑"
- Supabase 테이블 `ai_summary` 필요 (id, summary, market_mood, date)

### AI 브리핑 고도화 (2026-03-04)
- 기존: 6개 섹션, 단순 요약 수준 (수치 맥락 없음, 인과관계 단선적, 전략 부재)
- 변경: 7개 섹션, 헤지펀드 CIO 보고 수준 분석으로 업그레이드
- `generate_ai_summary()`에 `krx_data` 파라미터 추가 → 시장 breadth 지표 계산
- 시장 체력 지표: 상승/하락 종목 수, AD비율, 등락분포, 총 거래대금, 거래대금 TOP5, 시총 TOP10 등락률, KOSPI/KOSDAQ 평균
- 7개 섹션: 1)핵심 촉발+1차→2차→3차 파급 → 2)환율·금리·유가·선물 연쇄 → 3)수급 주체 분석(외인·기관·개인) → 4)패닉 단계 진단+시장 체력 → 5)섹터·테마 자금 흐름 → 6)매매 전략+리스크 관리 → 7)반등 조건·추가 하락 트리거·결론
- 핵심 원칙: 모든 인과관계 3단계 이상 연쇄 필수, 과거 사례 비교 필수, "관망" 등 애매한 표현 금지
- max_tokens: 2048 → 4096, 글자 수 가이드: 2000~3000자
- 프론트엔드: secIcons/secColors에 파급/촉발/선물/수급/외인/기관/패닉/진단/매매/리스크/반등/하락 등 30+ 키워드 매핑

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
- **상한가/하한가 보너스 (2026-03-06)**: 시총 3000억+ 상한가/하한가 종목에 +15점 보너스. 잡주 유입 방지하면서 대형 상한가 종목은 자연스럽게 진입
- `main()` 호출 순서: themes/sectors/news 이후로 이동 (데이터 의존성)
- 함수 시그니처: `crawl_issue_stocks(krx_data, themes=None, sectors=None, news=None)`

### 이슈 종목 투자자 수급 데이터 (2026-03-06)
- `fetch_investor_trend(code, price)`: 네이버 API (`/api/stock/{code}/trend`) 종목별 투자자 순매수 조회
- 데이터: 외국인/기관/개인 순매수금액(억원), 외국인 보유비율(%)
- `crawl_issue_stocks()` 6단계에서 TOP 15 종목에 대해 수집 → Supabase에 저장
- `issue_stocks` 테이블에 `foreign_net`, `institution_net`, `individual_net`, `foreign_ratio` 컬럼 추가 필요
- index.html: 수급 점수에 외국인 순매수(+2점), 기관 순매수(+1점) 반영 + 상세 카드에 외국인/기관/개인 금액 표시
- analysis.html: issue_stocks에서 투자자 데이터 merge 후 종목 카드에 표시
- `generate_stock_analysis()` AI 프롬프트에 실제 외국인/기관 데이터 제공 (추정→실데이터)

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

### AI 브리핑 아카이브 + 멀티페이지 구조 (2026-03-05)
- 기존: `index.html` 단일 SPA, ai_summary 매일 덮어쓰기(clear_today_data)
- 변경: 멀티페이지 구조 + ai_summary 과거 데이터 보존(1년)
- **crawl.py 변경**: `clear_today_data("ai_summary")` → `date+generated_time` 기준 교체 (과거 보존)
- **365일 cleanup**: close 모드 실행 시 365일 초과 데이터 자동 삭제
- **CSS/JS 분리**: `style.css` (공통 CSS), `shared.js` (Supabase 설정+db함수+테마 유틸)
- **archive.html**: 캘린더 UI로 과거 AI 브리핑 탐색, 날짜별 무드 도트, 하루 최대 3개 브리핑
- **guide.html**: 시장 지표/섹터/테마/AI 브리핑 활용법 + 투자 용어 사전 (AdSense용 독창적 콘텐츠)
- **about.html**: 서비스 소개, 기능 카드, 데이터 소스, 기술 스택, 연락처
- **privacy.html**: 개인정보처리방침 (AdSense 필수)
- **terms.html**: 이용약관 + 투자 면책 조항
- **sitemap.xml**: SEO용 (6개 페이지)
- index.html 푸터에 모든 페이지 링크 추가
- TabAI 하단에 "과거 AI 브리핑 아카이브" 링크 추가

### 이슈 종목 상세 강화 + 일간 종목 리포트 (2026-03-05)
- index.html TabStocks: 종목 클릭 시 3축 분석 카드 추가 (재료/수급/모멘텀)
  - 재료: 관련 뉴스 수 + 테마 소속 + 뉴스언급 사유 → strong/moderate/weak
  - 수급: 거래폭발 + 인기테마 + 순위 → strong/moderate/weak
  - 모멘텀: 등락률 + 상한가/급등/급락 → strong/moderate/weak
  - IIFE 패턴으로 JSX 내 로컬 변수 계산
  - 네이버 증권 상세 링크 버튼 추가
- crawl.py `generate_stock_analysis()`: 이슈 종목 TOP 5 AI 심층 분석 생성
  - Groq API (llama-3.3-70b), close 모드(15:35)에서만 호출
  - 3축(재료·수급·모멘텀) 프레임워크 분석 + 한줄 결론
  - Supabase `stock_analysis` 테이블 (date, market_context, stocks JSONB)
  - 90일 초과 데이터 자동 정리
- analysis.html: 일간 종목 리포트 페이지 (신규)
  - 날짜 네비게이터 (90일간 탐색)
  - 종목 카드: 3축 등급 뱃지 + AI 분석 본문 + 한줄 결론
  - 시장 맥락 카드, 면책 고지
- sitemap.xml에 analysis.html 추가
- about.html에 "일간 종목 리포트" 기능 카드 추가
- index.html TabStocks 하단에 "상세 종목 리포트 보기" 링크, 푸터에 "종목 리포트" 링크 추가

### 테마 심층 분석 (2026-03-07)
- 인기 테마 TOP 10 클릭 시 AI 심층 분석 드롭다운 표시
- crawl.py `generate_theme_analysis()`: close 모드(15:35)에서 Groq AI로 생성
  - 4축 분석: 촉발 요인 / 근본 배경 / 수혜·리스크 종목 / 투자자 대응
  - 테마당 1000~2000자, outlook(positive/neutral/negative)
  - TOP 10 테마 전체를 하나의 API 콜로 처리
- Supabase `theme_analysis` 테이블 (date, theme_name, analysis, outlook) — UNIQUE(date, theme_name)
- 90일 초과 데이터 자동 정리 (stock_analysis와 동일)
- index.html: ThemeItem에 `anOpen` state, 클릭-확장 UI (이슈 종목 상세와 동일 패턴)
  - outlook 뱃지 (🟢긍정/🔴부정/⚪중립)
  - 분석 없으면 기존과 동일하게 동작 (graceful degradation)
  - `thmAn` state: `{theme_name: analysis_obj}` map으로 O(1) 조회

### 일간 종목 리포트 심층 분석 강화 (2026-03-07)
- 기존: 종목당 200-400자 단일 `analysis` 텍스트, 축별 2-3문장 수준
- 변경: 3축 각각 독립 필드로 분리, 축별 300-500자 (종목당 총 900-1500자)
- **crawl.py JSON 구조 변경**:
  - `analysis` (단일) → `catalyst_analysis`, `supply_analysis`, `momentum_analysis` (3축 분리)
  - `catalyst_lifecycle` 추가: short(1~3일)/mid(1~4주)/long(1개월+)
  - `risk_note` 추가: 핵심 리스크 한 줄
  - `verdict`: 50자 → 100자, 조건부 시나리오 포함
  - `market_context`: 80자 → 200자
  - `max_tokens`: 4096 → 8192, timeout: 60s → 90s
- **프롬프트 심화**: 파급 경로 2~3단계, 과거 유사 사례 비교, 수급 주체별 의도 추정, 과열/과매도 판단
- **analysis.html UI 리디자인**:
  - `AxisSection` 컴포넌트: 왼쪽 컬러 보더(등급색) + 아이콘 + 분석 텍스트
  - `LifecycleBadge` 컴포넌트: 재료 수명 표시 (단기/중기/장기)
  - 핵심 판단 + 리스크 노트 카드로 분리 표시
  - 하위 호환: `catalyst_analysis` 없으면 기존 `analysis` fallback 표시

### 테마 종목 상세 페이지 (2026-03-08)
- 기존: 테마 클릭 시 상위 10개 종목(leading_stocks)만 표시
- 변경: "전체 N종목 보기 →" 버튼 → `theme_detail.html`로 이동하여 전체 종목 확인
- **crawl.py**: `save_theme_all_stocks(krx_data, theme_map)` 함수 추가
  - theme_map의 모든 테마 × 모든 종목을 `theme_stocks_all` 테이블에 개별 행으로 저장
  - 복합 점수(등락률+거래대금) 기준 rank 부여
  - 500개씩 배치 저장 (대량 데이터 처리)
- **theme_detail.html**: 신규 페이지
  - URL: `theme_detail.html?theme=테마명`
  - 테마명 + 종목 수 + 평균 등락률 + 상승/보합/하락 수 헤더
  - 정렬: 복합점수순(기본), 등락률순, 거래대금순
  - 종목 클릭 → 네이버 증권 이동
  - 반응형: 모바일(600px 미만)에서 현재가/거래대금 컬럼 통합
- **index.html**: ThemeItem에 `stockCount` prop 추가 (allThm에서 stock_count 매핑)
  - stock_count > 10인 테마에만 버튼 표시
  - AllThemeItem에도 동일 버튼 추가
- **Supabase 테이블 필요**: `theme_stocks_all` (theme_name, code, name, price, change_pct, change_amount, trading_value, trend, rank, date)

### 뉴스 설명 클릭 시 기사 원문 이동 (2026-03-08)
- TabNews: 뉴스 설명(summary) 클릭 시 `window.open()`으로 뉴스 원문 새 탭 열기
- 호버 시 테두리/배경 파란색 하이라이트 + "기사 원문 보기 →" 텍스트 표시

### 실시간 익명 토론방 (2026-03-08)
- **chat.html**: 신규 페이지 — Supabase Realtime 기반 익명 채팅
- 닉네임 입력(2~10자, localStorage 저장) → 채팅방 입장
- Supabase JS v2 클라이언트 CDN (`@supabase/supabase-js@2`) 사용 — Realtime WebSocket
- `postgres_changes` INSERT 이벤트 구독으로 실시간 메시지 수신
- Presence 기능으로 접속자 수 표시
- 메시지 버블 UI: 내 메시지(오른쪽, 그라데이션) / 상대 메시지(왼쪽)
- 닉네임별 고유 색상 (해시 기반 12색 매핑)
- 날짜 구분선, 시간 표시, 글자 수 제한(300자)
- 스팸 방지: 1.5초 쿨다운
- 반응형: 모바일 대응
- **Supabase 테이블 필요**: `chat_messages` (id bigserial, nickname text, message text, created_at timestamptz)
- **Supabase 설정 필요**: RLS 정책(anon read/insert), Realtime 활성화
- index.html 푸터에 "실시간 토론방" 링크 추가
- sitemap.xml에 chat.html 추가

### 자유게시판 (2026-03-08)
- **board.html**: 신규 페이지 — 익명 자유게시판
- 닉네임 + 비밀번호로 익명 글 작성 (계정 없음)
- 비밀번호: Web Crypto API SHA-256 해싱 → Supabase에 해시값만 저장
- 삭제: 글쓴이(비밀번호 검증) 또는 관리자만 가능 — Supabase RPC 함수(`SECURITY DEFINER`)로 서버사이드 검증
- 댓글 시스템: 글별 댓글 작성/삭제 (동일 비밀번호 방식)
- `comment_count` 자동 업데이트 (PostgreSQL 트리거)
- 뷰(`board_posts_public`, `board_comments_public`): password_hash 컬럼 숨김
- 페이지네이션: 20개/페이지
- React SPA: list(목록) → detail(상세) → write(글쓰기) view states
- 반응형: 모바일에서 날짜 컬럼 숨김 + 메타 정보 인라인 표시
- **Supabase 테이블 필요**: `board_posts`, `board_comments` (setup_board.sql 참조)
- **Supabase RPC 필요**: `delete_board_post`, `delete_board_comment` (setup_board.sql 참조)
- index.html 네비게이션에 "게시판" 링크, 푸터에 "자유게시판" 링크 추가
- sitemap.xml에 board.html 추가

### 닉네임 제한(차단) 시스템 (2026-03-08)
- 관리자 페이지에서 특정 닉네임 사용을 차단할 수 있는 기능
- **Supabase 테이블**: `banned_nicknames` (id, nickname, reason, created_at) — UNIQUE INDEX on LOWER(nickname)
- **RPC 함수**: `list_banned_nicknames`, `add_banned_nickname`, `remove_banned_nickname` (관리자 전용)
- **서버사이드 검사**: `insert_board_post`, `insert_board_comment` RPC에 차단 닉네임 체크 추가 → `banned_nickname` 예외 발생
- **admin.html**: `BannedNicknames` 컴포넌트 — 차단 닉네임 추가/삭제/목록 관리 UI (🚫 닉네임 제한 관리 섹션)
- **chat.html**: 입장 시 + 저장된 닉네임 자동 로그인 시 `banned_nicknames` 테이블 조회하여 차단 여부 확인
- **board.html**: 글 작성/댓글 작성 시 `banned_nickname` 에러 핸들링 추가 → "사용이 제한된 닉네임입니다" 메시지
- 대소문자 구분 없이 차단 (LOWER() 비교)
- RLS: anon SELECT 허용 (클라이언트에서 조회 가능)

### 자유게시판 조회수 기능 (2026-03-09)
- `board_posts` 테이블에 `view_count INT DEFAULT 0` 컬럼 추가
- `board_posts_public` 뷰에 `view_count` 포함하도록 재생성
- `increment_view_count(p_id BIGINT)` RPC 함수: SECURITY DEFINER, 글 열 때 +1
- board.html PostDetail: useEffect에서 postId 변경 시 1회 RPC 호출
- 목록 뷰: 👁 아이콘 + 조회수 컬럼 (모바일에서는 숨김)
- 상세 뷰: 닉네임/날짜 옆에 조회수 표시

### 자유게시판 글쓰기 서식 기능 (2026-03-09)
- BBCode 스타일 태그로 텍스트 서식 지원 (게시글 작성/수정만, 댓글은 미적용)
- `FormatToolbar` 컴포넌트: B(굵게), 크기(12/14/16/18/20/24px 드롭다운), 색상(8색 팔레트)
- `FormattedText` 컴포넌트: BBCode 파싱 + 링크 파싱, 중첩 태그 지원, XSS 안전 (React elements 변환)
- 지원 태그: `[b]굵게[/b]`, `[size=N]크기[/size]`, `[color=#hex]색상[/color]`
- WriteForm: textarea 위에 FormatToolbar 배치, ref로 선택 영역에 태그 삽입
- PostDetail 수정 모드: 동일하게 FormatToolbar 배치
- PostDetail 읽기 모드: `LinkedText` → `FormattedText`로 교체

### AI 브리핑 뉴스-지수 충돌 방지 (2026-03-10)
- 기존: Groq AI가 뉴스 서사에 끌려가 실제 지수 방향과 반대되는 브리핑 생성 (코스피 +5% 급등인데 "역대급 낙폭" 분석)
- 원인: 과거 폭락 뉴스가 대량으로 남아있을 때 AI가 지수 데이터 대신 뉴스 톤을 따름
- **수정 1 - 시장 팩트 블록**: 프롬프트 최상단에 `★★★ 오늘 시장 팩트 ★★★` 섹션 추가
  - 코스피/코스닥 지수 + 방향(상승/하락/보합) 명시
  - breadth 기반 매수/매도 우위 표시
  - "뉴스와 지수 데이터가 충돌하면 지수 데이터를 따르라" 지시
- **수정 2 - 절대 규칙 강화**: "오늘 시장 방향은 지수 데이터로 판단하라" 최우선 규칙 + 뉴스 시점 구분 규칙 추가
- **수정 3 - mood 검증**: 생성 후 코스피 등락률과 AI mood 비교, ±2% 이상 괴리 시 mood 강제 보정
  - 코스피 +2% 이상 → bullish 아니면 보정
  - 코스피 -2% 이상 → bearish 아니면 보정

### AI 브리핑 주말 스킵 (2026-03-14)
- 토요일/일요일에는 AI 브리핑(Groq 호출), 종목 분석, 테마 분석 모두 스킵
- `kst_start.weekday() >= 5` 체크로 `ai_mode`를 `None`으로 설정

### 테마 캘린더 (2026-04-12)
- 기존: 인기 테마는 당일 데이터만 존재 (매 크롤링마다 clear_today_data)
- 변경: 테마 히스토리를 별도 테이블에 보존하여 캘린더 뷰 제공
- **crawl.py**: 테마 저장 직후 `theme_history` 테이블에 TOP 10 저장 (DELETE+INSERT 패턴, 과거 보존)
  - leading_stocks는 상위 3개만 저장 (용량 절약)
  - close 모드에서 365일 초과 데이터 자동 정리
- **Supabase `theme_history` 테이블 필요**: id(bigserial), date(text), rank(int), name(text), change_pct(text), trend(text), leading_stocks(text), up_count(int), down_count(int), flat_count(int)
  - 인덱스: (date, rank) 복합 인덱스, RLS anon SELECT 허용
- **theme_calendar.html**: 신규 페이지 (archive.html 패턴)
  - 캘린더 셀에 TOP 3 테마 뱃지 표시 (trend별 색상: 상승 초록, 하락 빨강, 보합 회색)
  - 날짜 클릭 시 해당일 TOP 10 테마 상세 (순위/테마명/등락률/대장주/상승하락수)
  - 테마명 클릭 → theme_detail.html 이동, 대장주 클릭 → 네이버 증권
  - 캘린더 그리드 380px (archive보다 넓음, 뱃지 텍스트 가독성)
- index.html: 인기 테마 TOP 10 헤더에 "📅 테마 캘린더 →" 링크, 푸터에 추가
- sitemap.xml에 theme_calendar.html 추가

### Google Analytics 4 도입 (2026-04-26)
- 기존: 트래픽 분석 도구 없음 (AdSense 광고 노출 통계만 존재)
- 변경: GA4 측정 ID `G-3G7NQ8B69G` 추적 코드를 11개 공개 페이지 `<head>`에 삽입
- 대상 파일: index, analysis, theme_detail, chat, board, theme_calendar, archive, guide, about, privacy, terms
- 제외: admin.html (관리자 자기 자신 트래픽이 통계를 왜곡하므로 의도적 제외)
- 삽입 위치: `<meta viewport>` 직후 (가능한 빨리 로드)
- privacy.html 갱신: "분석 쿠키" 항목 + "Google Analytics 관련 고지" 섹션(수집 정보 범위, 옵트아웃 안내) 추가, 최종 수정일 2026-04-26으로 갱신
- 확인 위치: GA4 → 보고서 → 실시간 / 참여도 / 획득 (일반 보고서는 24~48시간 후 누적 시작)

### AdSense "가치 없는 콘텐츠" 거절 대응 (2026-04-27)
- 거절 사유: 정책 위반 — "가치가 별로 없는 콘텐츠 (Low value content)". 익명 UGC + 자동 생성 콘텐츠 비중 높음, 오리지널 콘텐츠 부족이 원인으로 추정.
- **광고 코드 정리 (대상 페이지에서 `adsbygoogle.js` 스크립트 제거)**:
  - 익명 UGC: `chat.html`, `board.html` (모더레이션 없는 익명 게시판/채팅 → AdSense 정책 위험)
  - 자동 생성: `analysis.html`, `archive.html`, `theme_detail.html`, `theme_calendar.html` (AI 생성 + 크롤링 데이터)
  - 관리자: `admin.html` (본인만 봄)
  - 광고 유지 페이지(콘텐츠 풍부): `index.html`, `guide.html`, `about.html`, `terms.html`, `privacy.html` + 신규 가이드 5종
- **noindex 처리**: `chat.html`, `board.html`의 `<meta name="robots">`를 `noindex,nofollow`로 변경. sitemap.xml에서도 제거.
- **오리지널 콘텐츠 5종 신규 작성** (각 약 3000~4500자, AdSense 가치 입증용):
  - `guide-sectors.html`: 섹터 로테이션 심층 (경기 사이클 4단계, 10대 섹터 매크로 민감도, 매크로 변수별 영향)
  - `guide-themes.html`: 테마주 5원칙 (생애주기 4단계, 대장주 우선·손절·분할매수·뉴스 사이클·섹터 분리)
  - `guide-indicators.html`: PER/PBR/ROE 실전 (지표별 한계, 코리아 디스카운트, 듀퐁 분석, 5가지 함정)
  - `guide-supply.html`: 외국인·기관·개인 수급 (주체별 특성, 환율-외국인 연동, 기관 5주체 분리, 프로그램 매매)
  - `guide-ai-briefing.html`: AI 브리핑 활용 (7개 섹션 의미, 무드 해석, 5가지 한계, 다른 지표와 결합)
- **guide.html**: 상단에 "📚 심층 가이드" 카드 그리드(5개 sub-page 링크) 추가
- **상호 링크**: 각 sub-page 하단에 다른 sub-page로의 "→" 네비게이션 + 헤더에 "← 투자 가이드" back 링크
- **sitemap.xml**: chat/board 제거, guide-* 5개 추가 (priority 0.8), guide.html priority 0.7→0.9
- **Google Analytics**: 5개 신규 페이지 모두 GA4 추적 코드(`G-3G7NQ8B69G`) 포함
- **재신청 전 체크**: 모든 sub-page 정상 로드, 광고 노출, 면책 고지(투자 추천 아님) 표시 확인

### 탭 상태 URL 해시 동기화 (2026-05-09)
- 기존: 탭 state가 React state에만 존재 → 새로고침 시 항상 overview(시장 개요)로 복귀
- 변경: index.html App에 URL 해시(`#themes`, `#issues`, `#news`, `#ai`) ↔ tab state 양방향 동기화
- `getTabFromHash()`: 마운트 시 hash 읽어 초기 tab 결정 (whitelist: overview/issues/themes/news/ai)
- `useEffect([tab])`: tab 변경 시 `history.replaceState`로 hash 갱신 (overview는 hash 제거)
- `useEffect([])`: `hashchange` 이벤트 구독 → 브라우저 뒤로/앞으로 시 탭 동기화
- 효과: 인기 테마 탭에서 새로고침해도 그대로 유지, URL 공유로 특정 탭 직접 진입 가능

### 자동 새로고침 폴링 최적화 (2026-05-09)
- 기존: index.html이 5분 간격으로 fetchData 폴링, 백그라운드 탭/장 마감 후에도 계속 호출
- 변경: 90초 간격, 장중(KST 09:00~15:30, 평일)에만 + 백그라운드 탭일 땐 일시정지
- `isMarketOpen()`: `getTimezoneOffset()`으로 KST 변환 후 요일·분 단위 비교 (토/일 제외, 09:00~15:30)
- 폴링 콜백: `document.visibilityState !== "visible"`이거나 장 마감이면 즉시 return
- 탭 활성화 시(`visibilitychange`)는 즉시 1회 갱신 유지 (사용자가 돌아왔을 때 최신 데이터 보장)
- 효과: 크롤링 직후 페이지 자동 반영, Supabase 대역폭은 24h 폴링 대비 ~70% 절감

### 인기 테마 검색에 종목명 매칭 추가 (2026-05-04)
- 기존: TabThemes 검색이 테마명만 매칭 → "삼성전자" 검색해도 결과 없음
- 변경: `leading_stocks`(테마당 상위 대장주) 내 종목명도 함께 매칭
- `matchTheme(t)` 헬퍼: 테마명 우선 검사 → 미일치 시 leading_stocks를 `,` 분리 후 각 항목 첫 토큰(종목명)에 query 포함 여부 확인
- placeholder: "테마 검색... (예: 방산, 반도체, AI)" → "테마/종목 검색... (예: 방산, 삼성전자, AI)"
- 한계: leading_stocks 밖 종목은 검색 안 됨 (전체 매칭이 필요하면 `theme_stocks_all` 로드 필요)

### AI 브리핑 매크로 이벤트 환각 차단 (2026-05-10)
- 기존: 프롬프트에 "향후 1~3일 주목할 이벤트를 짚어라"는 지시는 있는데 실제 경제 캘린더 데이터를 주지 않음 → Groq AI가 "Fed 금리 결정이 곧 있다" 등 학습 데이터 기반 흔한 매크로 이벤트를 환각 생성. FOMC 회의가 6주 간격임에도 매번 임박한 것처럼 표시됨
- 변경: `economic_calendar.json` 화이트리스트 도입 + 프롬프트에 절대 규칙으로 "리스트에 없는 이벤트 언급 금지" 주입
- **`economic_calendar.json`**: FOMC, 한국 금통위, 미국 CPI/PPI/고용보고서, 한국 옵션·선물 만기일 등 주요 이벤트 (2026년 5~8월 시드). 각 이벤트에 `date`, `time`(KST), `name`, `impact`(high/medium), `category`, `verified`(공식 일정 확인 여부) 포함. `last_updated` 필드로 갱신일 추적
- **`load_economic_calendar(days_ahead=3)`**: JSON 로드 → 오늘 ~ +3일 이내 이벤트만 반환. 마지막 이벤트가 30일 이내로 다가오면 crawl 로그에 "갱신 필요" 경고 출력
- **`format_calendar_block()`**: 이벤트 없으면 "향후 3일 내 예정된 주요 매크로 이벤트 없음" 명시 → AI가 빈 리스트를 보고도 환각 만들지 않음
- **프롬프트 수정** (premarket / market·close 양쪽):
  - `[뉴스]` 블록 직후에 `[향후 3일 예정 매크로 이벤트]` 블록 주입
  - 작성 규칙에 "리스트에 없는 일정(FOMC, CPI 등) 추측·창작 금지" 추가
  - 섹션 4(전략과 시나리오) 지시문에 "리스트가 비어 있으면 매크로 이벤트 언급 없이 시장 자체 모멘텀에 집중하라고 쓰라"
- **유지보수 부담**: 매년 1월 갱신 필요. JSON `verified=false`인 항목은 Fed.gov, BOK, BLS 공식 일정과 대조 후 수정

### theme_map 증분 빌드 + 이슈종목 태그 세분화 (2026-05-14)
- 기존 1: `build_theme_stock_map`이 7일 캐시를 그대로 사용 → 신규 상장 종목(예: 코스모로보틱스)이 캐시 만료될 때까지 인기 테마/leading_stocks 어디에도 누락
- 기존 2: 이슈종목 태그가 `display_sector`(10개 광범위 분류)만 사용 → 로보틱스 회사가 "건설"로 표시되는 문제 (NAVER_SECTOR_MAP에서 WICS=기계 → display="건설"이 catch-all로 묶여 있음)
- **변경 1 - 증분 빌드** ([crawl.py:1030-1277](crawl.py:1030)):
  - 캐시에 `processed_codes` 필드 추가 (테마 분류 시도한 모든 종목코드 기록, 테마 없어도 포함)
  - 캐시 유효(7일 이내) 시 KRX 시총 3000억+ 종목 중 `processed_codes`에 없는 것만 추출 → 그들만 기업개요 fetch → 기존 stock_themes에 merge
  - 신규 0개면 캐시 그대로 return (기존 동작)
  - 캐시 저장 시 `date`는 원래 빌드 날짜 유지 (만료 시계 보존)
  - 구버전 캐시(processed_codes 없음) 호환: `stocks.keys()`를 처리 이력으로 fallback → 첫 실행 시 미분류 종목 일회성 재크롤(약 200~500개)
  - 시총 컷 변동 처리: 역매핑 단계에서 현재 시총 < 3000억이면 노출 제외(캐시는 유지)
- **변경 2 - theme_map 데이터 공유** ([crawl.py:866-893](crawl.py:866), [crawl.py:2731](crawl.py:2731), [crawl.py:3523](crawl.py:3523)):
  - `classify_stock_tags`에 `theme_map_themes` 파라미터 추가 → 있으면 display_sector보다 우선 사용
  - `crawl_issue_stocks` 시그니처에 `stock_themes` 추가 → `main()`에서 `build_theme_stock_map`이 반환한 stock_themes 전달
- **변경 3 - THEME_SPECIFICITY 우선순위** ([crawl.py:844-863](crawl.py:844)):
  - 테마 구체성 점수 매핑 추가 (1순위: 로봇/AI/2차전지 등 신생, 2순위: 방산/조선 등 특화, 3순위: 일반, 5순위: 기계/건설/화학 등 광범위)
  - 종목이 여러 테마에 속할 때(예: 코스모로보틱스 = ["기계","로봇"]) 구체성 낮은 숫자 우선 정렬 → "로봇·기계" 순으로 노출
  - 핫 테마(theme_names, TOP 10 leading)에 포함된 테마는 추가로 최우선 부스트 → 오늘 시장 맥락 반영
- **효과**: 코스모로보틱스 같은 신규 상장 종목이 다음 크롤링 5분 이내 theme_map 진입 + 이슈종목 태그도 "로봇·기계" 같은 구체적 분류로 표시됨

### AdSense 2차 거절 대응 — SEO fallback + 자동생성 페이지 noindex (2026-05-17)
- 4월 27일 1차 정리 후에도 "가치 없는 콘텐츠" 사유로 재거절. 두 가지 신규 원인 추정:
  1. **메인 페이지가 봇 입장에서 빈 셸** — index.html은 React SPA + Supabase 비동기 로드라 Googlebot이 raw HTML을 fetch했을 때 스크립트만 보이고 콘텐츠가 없음 (JS 실행 전). `<noscript>` fallback도 없었음
  2. **사이트 전체 품질 신호 희석** — analysis/archive/theme_detail/theme_calendar는 광고는 뺐지만 indexable + sitemap에 그대로 남아 있어, 봇이 보기엔 "자동 생성 페이지 비중이 높은 사이트"로 분류될 위험
- **변경 1 - index.html SEO fallback** ([index.html:194](index.html:194)):
  - `<div id="root">` 안에 ~3000자 정적 콘텐츠 주입 (서비스 설명, 제공 기능 6개 상세, 데이터 출처, 가이드 5개 링크, 면책 고지)
  - React `createRoot()`가 마운트되면 자동 교체 → cloaking 아님 (사용자 경험 그대로)
  - `</div>` 다음에 `<noscript>` 블록 추가 (JS 비활성 사용자도 콘텐츠 접근 가능)
  - 검증: fetch로 raw HTML 확인 → `hasH1`, `hasSeoFallback`, `hasGuideSectorsLink`, `hasNoscript` 모두 true
- **변경 2 - 자동 생성 페이지 noindex 처리**:
  - `analysis.html`, `archive.html`, `theme_detail.html`, `theme_calendar.html`의 robots 메타를 `index,follow` → `noindex,nofollow`로 변경
  - sitemap.xml에서 4개 페이지 URL 제거 (남은 항목: 메인 + guide 6개 + about/privacy/terms = 9개)
  - 인덱싱은 막지만 사용자가 직접 접근하거나 내부 링크로는 정상 이용 가능
- **AdSense 재신청 전 체크리스트**: (1) raw HTML view-source로 봇이 보는 콘텐츠 확인 (2) Search Console에서 4개 페이지 noindex 적용 확인 (3) 사이트 메인이 오리지널 가이드 페이지로 충분히 라우팅되는지 확인

### 과대 낙폭 탭 + 일봉 누적 (2026-05-19)
- 신규 탭: MA20(20일 이동평균) 대비 -20% 이하로 하락한 시총 3000억+ 종목을 거래대금 순으로 노출
- **`setup_oversold.sql`**: `daily_prices`(code, date PK / close / trading_value / market_cap)와 `oversold_stocks`(date, rank, code, name, price, ma20, deviation, change_pct, trading_value, market_cap, market, display_sector, tags JSONB) 테이블 + 인덱스 + RLS
- **`backfill_daily_prices.py`**: 1회 실행용. 시총 3000억+ 종목에 대해 야후 chart API (`{code}.KS/.KQ` interval=1d range=2mo)로 최근 40일치 일봉을 받아와 `daily_prices`에 INSERT. crawl.py의 `fetch_naver_market_data`/`is_etf_etn`/`supabase_request` 재사용
- **`crawl.py` 변경**:
  - `save_daily_close(krx_data)` — close 모드에서만 호출. 시총 3000억+ 종목의 당일 종가를 `daily_prices`에 누적 저장. 같은 (code, date) PK 충돌 방지를 위해 `DELETE date=eq.TODAY` 선행
  - `crawl_oversold_stocks(krx_data)` — `daily_prices`에서 최근 60일치를 페이지네이션(1000행씩)으로 로드 → 종목별 최근 20개 종가 평균 계산 → `(price - ma20)/ma20*100 <= -20` 필터 → 거래대금 내림차순 정렬
  - 상수: `OVERSOLD_MIN_MARKET_CAP=3000억`, `OVERSOLD_THRESHOLD=-20.0`, `OVERSOLD_MA_WINDOW=20`, `OVERSOLD_HISTORY_DAYS=60`
  - `main()`: `crawl_issue_stocks` 직후(ai_mode=="close"인 경우만) 위 두 함수 호출 → 저장 단계에서 `DELETE date=eq.TODAY` 후 `POST oversold_stocks`
  - close 모드 cleanup 블록에 `daily_prices` 60일 / `oversold_stocks` 90일 초과 삭제 추가
- **`index.html` 변경**:
  - 신규 컴포넌트: `OversoldRow` (랭크 뱃지, 종목명+코드+태그, MA20·거래대금, 현재가·이격률 -X.XX%) / `TabOversold` (검색 input, 거래대금 정렬 리스트, 면책 고지)
  - `VALID_TABS`에 "oversold" 추가 → URL 해시 동기화 동작
  - 탭 nav: `이슈종목 / 인기테마 / 주요뉴스 / 과대 낙폭 / AI브리핑` 순. 아이콘 `▼` 파란색
  - `App` 상태에 `ovs` 추가. `fetchData`에 `db("oversold_stocks","order=date.desc,rank.asc&limit=100")` 추가 후 최신 date만 필터링하여 setOvs
  - 빈 데이터/404일 때 graceful degradation으로 empty state 카드 노출 ("현재 MA20 대비 -20% 이하 종목 없음")
- **운영 순서**: (1) Supabase에 `setup_oversold.sql` 실행 → (2) `python backfill_daily_prices.py` 1회 실행 (20거래일치 백필 확보) → (3) 다음 close 모드(15:35) 크롤링부터 `oversold_stocks` 자동 채워짐
- **부하**: close 모드 1회만 동작. INSERT 800~1000행 + GET 16000~20000행(60일×800종목) + 산출 메모리 연산. 폴링 영향 없음

### 과대 낙폭 종목 15:00 장중 갱신 추가 (2026-05-22)
- 기존: `save_daily_close`/`crawl_oversold_stocks`가 `ai_mode=="close"`(15:35/16:00)에서만 실행 → 장중에는 전일 데이터만 표시
- 변경: 평일 15:00~15:19 KST 장중에도 현재 시세 기준으로 갱신 추가 (사용자 요청 "3시 업데이트")
  - `main()`에 `oversold_intraday = (kst_start.weekday() < 5 and kst_start.hour == 15 and kst_start.minute < 20)` 플래그 추가
  - 트리거 조건: `if ai_mode == "close" or oversold_intraday:` → 15:00 장중 + 15:35/16:00 확정 종가 둘 다 갱신
  - 15:00 장중에는 미확정 시세를 `daily_prices`에 임시 저장하지만 15:35 close 모드에서 `DELETE date=eq.TODAY` 후 확정 종가로 덮어씀 → 일봉 무결성 유지
  - cleanup(60일/90일 정리)은 여전히 close 모드에서만 실행 (1일 1회)
- 한계: GitHub Actions cron 지연 가능성 때문에 15:00 단일 시점이 아닌 15:00~15:19 윈도우로 잡음. 해당 윈도우 내 */5 실행마다 oversold 재계산(중복 GET 발생)되나 마지막 쓰기가 유효
- **당일 상승 종목 제외 (2026-05-22)**: `crawl_oversold_stocks` 후보 필터에 `if d.get("change_pct", 0) > 0: continue` 추가 → 낙폭 종목 탭이므로 당일 상승 종목은 MA20 대비 -20% 이하라도 노출 안 함 (하락/보합만)
- **낙폭과대 탭에 테마 등장 횟수 위젯 추가 (2026-05-22)**: index.html `TabOversold` 상단에 최근 30일 인기 테마 등장 횟수 표시 (theme_calendar.html의 월간 등장 횟수와 동일 로직 — rank<=3 카운트)
  - 신규 컴포넌트 `ThemeAppearCounts({hist})`: hist에서 rank≤3 테마별 카운트 → 내림차순 TOP 12 뱃지, 상위 3개 주황 강조, 각 뱃지 클릭 시 theme_detail.html 이동, "테마 캘린더 →" 링크 포함
  - `App`에 `thmHist` state 추가, `fetchData` Promise.all에 `db("theme_history", select=date,name,rank,trend&date=gte.{30일전}&order=date.desc)` 추가 → `setThmHist`
  - `TabOversold`에 `hist` prop 전달, 종목 유무 두 분기 모두 상단에 위젯 렌더링
  - 안내문도 갱신 시점(15:00 장중 + 15:35/16:00) 반영하도록 수정

### 과대 낙폭 탭 테마 뱃지 → 사이드 패널 (2026-05-23)
- 기존: `ThemeAppearCounts` 뱃지 클릭 시 `theme_detail.html?theme=...`로 페이지 이동 → 컨텍스트(낙폭 종목 화면) 끊김
- 변경: 우측에 sticky 사이드 패널이 열려 iframe으로 `theme_detail.html` 로드 → 본 화면 유지
- **index.html**:
  - `App`에 `themePanel` state + `openThemePanel(name)` 핸들러 추가 (호출 시 챗 패널 자동 닫음 — 상호 배타)
  - 챗 토글도 대칭으로 `themePanel` 자동 닫음
  - `ThemeAppearCounts({hist,onThemeClick})`: `onThemeClick` prop 추가, 있으면 anchor `onClick`에서 `preventDefault()` 후 콜백 호출 (없으면 기존 네비게이션 fallback — 다른 곳에서 재사용 가능)
  - `TabOversold`에 `onThemeClick` prop 추가하여 두 분기(빈/정상 데이터) 모두 forward
  - 패널 헤더: 테마명 + `↗`(새 창) + `✕`(닫기), 바디: `<iframe>` `theme_detail.html?theme=...`
  - 패널 폭 480px (챗 패널 380px보다 넓음 — 테마 종목 테이블 가독성)
- **style.css**: `.chat-side-panel` 미디어쿼리에 `.theme-side-panel`도 함께 포함 (max-width 480px, <600px에서 100%)
- 효과: 낙폭 탭에서 테마 뱃지 클릭 → 화면 분할 형태로 테마 종목 확인 → ✕ 닫고 다시 종목 확인 가능

### 과대 낙폭 갱신 시각 표시 (2026-05-22)
- 사용자가 "데이터가 언제 갱신됐는지 알 수 없다"는 불편 제기 → 갱신 날짜+시각 뱃지 추가
- **setup_oversold.sql**: `oversold_stocks` 테이블에 `generated_time TEXT DEFAULT ''` 컬럼 추가 + `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` 마이그레이션 구문 포함 (기존 테이블 안전 적용)
- **crawl.py `crawl_oversold_stocks`**: 함수 시작 시점에 `gen_time = datetime.now(KST).strftime("%H:%M")` 한 번 계산 → 모든 결과 행에 `generated_time` 필드 채워서 INSERT (ai_summary와 동일 패턴)
- **index.html `TabOversold`**: 제목 우측에 `📅 YYYY-MM-DD HH:MM 갱신` 블루 pill 뱃지 표시. `generated_time` 없는 구버전 데이터는 날짜만 표시 (graceful fallback)
- **운영 메모**: Supabase에 `ALTER TABLE oversold_stocks ADD COLUMN IF NOT EXISTS generated_time TEXT DEFAULT '';` 1회 실행 필요. 다음 크롤링부터 시각 채워짐

### APS 생산계획 시스템 (2026-06-11)
- 사이트 본 기능과 무관한 별도 도메인. 관리자 페이지(admin.html)의 동일 인증을 빌려 쓰는 관리자 전용 모듈
- **`setup_aps.sql`** (1회 실행): 테이블 4개 + VIEW 1개 + 인증 헬퍼 + CRUD RPC 14개
  - `aps_items` (품목 마스터: 제품/반제품/원자재 + 단위/안전재고/리드타임)
  - `aps_bom` (자재명세서: parent → child + qty + loss_rate, 자기참조 CHECK)
  - `aps_plans` (생산계획: item / qty / start_date / due_date / status[planned·in_progress·done·canceled])
  - `aps_stock_txns` (입출고 트랜잭션: 부호 포함 qty, type[in/out/adjust], 선택적 plan 연결)
  - `aps_inventory_view` (`SUM(qty)` 기반 현재 재고 + 안전재고 대비 status[out/low/ok])
  - 모든 테이블 RLS ENABLE + 정책 없음 → REST 직접 접근 차단, `aps_assert_admin(hash)` 첫 줄 검증하는 SECURITY DEFINER RPC로만 접근
  - 인증은 기존 `board_admins.password_hash` 그대로 검증 (별도 계정 불필요)
- **`aps.html`** (신규): React 18 SPA, 1100px 폭 데스크탑 최적화
  - 로그인: admin.html의 `admin_login` RPC + `sessionStorage("sp-admin-hash")` 재사용 (한 번 로그인하면 admin.html과 양쪽 호환)
  - 탭 3개: 📦 품목/BOM, 📅 생산계획, 📊 재고 (URL 해시 동기화)
  - 품목 탭: 구분/검색 필터 + CRUD 모달 + BOM 편집 모달(자식품목 추가/소요량·로스율 인라인 편집/삭제)
  - 생산계획 탭: 상태별 필터 + CRUD + 빠른 상태 전환(▶시작/✓완료) + 납기 초과 빨강 강조
  - 재고 탭: 상태별 필터(품절/부족/정상) + 입출고 기록 모달(입고+/출고-/조정±) + 최근 50건 이력 + 이력 삭제 시 재고 자동 재계산
  - 외부 노출 차단: `<meta robots="noindex,nofollow">`, sitemap.xml 미등록
- **운영 순서**: (1) Supabase SQL 에디터에서 `setup_aps.sql` 실행 → (2) `aps.html` 직접 URL 접근 → (3) 기존 관리자 비밀번호로 로그인 → 즉시 사용
- **MVP 범위 제외**: 수요예측/MRP/CRP/작업지시서/공정 라우팅 (후속 단계)

### APS 간트차트 뷰 추가 (2026-06-11)
- 생산계획 탭 내부에 리스트/간트 토글 추가 (별도 탭 아님, 같은 데이터 두 가지 뷰)
- **`aps.html` `GanttView` 컴포넌트**:
  - 28일 윈도우(GANTT_DAYS), 28px 컬럼(GANTT_COL_W), 38px 행(GANTT_ROW_H), 200px sticky 좌측 라벨(GANTT_LABEL_W)
  - 막대: `start_date → due_date`, `STATUS_PILL` 색상(계획 회색/진행중 시안/완료 초록/취소 빨강)
  - 좌/우 4px 두꺼운 테두리 = 윈도우 밖으로 연장된 계획
  - 오늘 빨강 세로선(`opacity:.6`), 헤더에도 빨강 배경 강조
  - 주말 배경 강조(`rgba(148,163,184,0.06)`), 일요일 빨강/토요일 파랑 라벨
  - 막대 클릭 → 기존 `PlanForm` 모달로 수정 (state 공유)
  - 네비게이션: `← 2주 / 오늘 / 2주 →` (앵커는 `오늘-3일`이 기본)
  - 윈도우 밖 계획은 자동 숨김 + "표시 N/M건" 카운터 표시
  - 상태 필터(`filter`)는 리스트/간트 양쪽에 공유 적용
- **`PlansTab`에 `viewMode` state 추가**: `list`(기본) / `gantt` 토글, `.aps-view-toggle` CSS로 segmented 버튼 UI
- 별도 SQL 변경 없음 (기존 `aps_plans` 데이터 그대로 사용)

### APS v2 — 라인 마스터 + 시간 단위 간트 (2026-06-11)
- 일 단위 → 시간 단위 전환. 행 구조도 계획별 → **라인별**로 변경 (옵션 A 표준 생산 간트)
- **`setup_aps_v2.sql`** (신규, setup_aps.sql 위에 추가 실행):
  - `aps_lines` (라인 마스터: code/name/memo)
  - `aps_settings` (key/value, 초기값 `work_start_hour=8`, `work_end_hour=17`)
  - `aps_plans` DROP/CREATE: `start_date/due_date(DATE)` → `start_at/end_at(TIMESTAMPTZ)`, `line_id` 컬럼 추가
  - `aps_stock_txns.related_plan_id` FK 자동 복구 (CASCADE로 잃어버린 것)
  - 신규 RPC: `aps_list_lines`/`aps_upsert_line`/`aps_delete_line`, `aps_get_settings`/`aps_set_setting`
  - `aps_list_plans`/`aps_upsert_plan` 시그니처 교체 (DROP FUNCTION 후 CREATE) — start_at/end_at TIMESTAMPTZ, line_id 추가
- **`aps.html` 주요 변경**:
  - 4번째 탭 **🏭 라인** 추가 (LineForm + LinesTab CRUD, 사용 중 라인 삭제 거부)
  - **SettingsModal**: 근무 시작/종료 시각 (0~24h) 편집
  - **KST 변환 헬퍼**: `isoToKstInput` / `kstInputToIso` / `isoToKstHourFloat` / `isoToKstDateStr` / `fmtKstDateTime` / `fmtKstTime` — 서버 TIMESTAMPTZ ↔ datetime-local 입력 변환 일관성
  - **PlanForm**: 라인 picker(미지정 허용) + datetime-local 입력 (KST 표시). 기본값 = 오늘 + 근무 시작 시각
  - **PlansTab**: viewMode 기본값 `gantt`, 리스트 컬럼에 **라인** 추가, 시작일/납기일 → 시작/종료(시각 포함). 지연 판단도 시간 단위 비교
  - **GanttView 완전 재작성**:
    - 행 = 라인 (없으면 가상 "미지정" 라인 자동 추가)
    - 컬럼 = 1시간 단위, 폭 64px, 범위 = `work_start_hour`~`work_end_hour`
    - 단일 일자 선택 (이전 날 / 오늘 / 다음 날 / 날짜 picker)
    - **레인 자동 분할**: 같은 라인 시간 겹침 → greedy lane 할당, 행 높이 = lane 수 × 48px
    - 근무 외 시간으로 연장된 막대는 좌/우 4px 두꺼운 테두리
    - 빨강 세로선 = 현재 KST 시각 (오늘 보고 있을 때만)
    - 막대 클릭 → PlanForm 모달 (재사용)
    - ⚙ 버튼 → SettingsModal
- **운영 순서**: Supabase에서 `setup_aps_v2.sql` 실행 1회 → 🏭 라인 탭에서 라인 등록 → 생산계획 추가 시 라인/시간 선택 → 간트 자동 표시

### APS v3 — 실제 생산 시간 기록 + 품목별 통계 (2026-06-11)
- 사용자 요청: "시작/완료 버튼 클릭 시각을 자동 기록 → 품목별 실제 생산 시간 1년치 축적"
- **`setup_aps_v3.sql`** (신규, v2 위에 추가):
  - `aps_plans.actual_start_at`/`actual_end_at` TIMESTAMPTZ 컬럼 추가 (idempotent)
  - 부분 인덱스 `idx_aps_plans_actual` (status='done' 조건)
  - **`aps_set_plan_status(p_admin_hash, p_id, p_status)`** RPC: 서버에서 `now()` 자동 기록
    - planned/canceled → in_progress: `actual_start_at=now()`, `actual_end_at=NULL` 리셋
    - ? → done: `actual_end_at=now()`. 시작 시각 없으면 같이 채움
    - 반환: `{id, status, actual_start_at, actual_end_at}`
  - **`aps_list_plans` 재정의**: 응답에 `actual_start_at`/`actual_end_at` 포함
  - **`aps_cleanup_old_plans(p_admin_hash, p_days=365)`** RPC: 완료/취소 + updated_at > p_days 일 경과 행 삭제, 삭제 개수 반환
  - **`aps_get_item_stats(p_admin_hash, p_days_back)`** RPC: 품목별 누적 통계 집계
    - 완료(done) + 실제 시각 둘 다 있는 행만 집계
    - 출력: `plan_count`, `total_qty`, `avg_qty`, `total_actual_hours`, `avg_actual_hours`, `avg_planned_hours`, `qty_per_hour`, `last_completed_at`
    - 제품/반제품만 (원자재 제외)
- **`aps.html` 변경**:
  - `changeStatus`: `aps_upsert_plan` → `aps_set_plan_status` (서버 시각 기록 보장, 시각 추측 방지)
  - 리스트 뷰: 시작/종료 컬럼에 "계획: ..." + "실제: ..." 2단 표시 (실제는 초록색)
  - 간트 막대 툴팁: `\n` 줄바꿈으로 "계획 / 실제" 비교 (실제 종료 없으면 "진행중" 표시)
  - **신규 📈 통계 탭**:
    - 5번째 탭, `VALID_TABS`에 "stats" 추가
    - 요약 카드 3개: 완료 계획 / 총 생산 시간 / 실적 보유 품목
    - 기간 필터: 7일/30일/90일/1년/전체 (`aps_get_item_stats(p_days_back)`)
    - 정렬: 건수순/총시간순/평균순/생산률순
    - 품목별 표: 완료 건수, 총 수량, 총/평균 시간, 계획↔실제 차이(±5% 초과 시 빨강/초록), 시간당 생산률, 최근 완료
    - 실적 없는 품목은 하단 회색 줄로 나열
    - `fmtHours()` 헬퍼: 시/분 단위 한국어 표시 ("2시간 54분")
    - **자동 retention**: 탭 마운트 시 `localStorage["aps-cleanup-last"]` 확인 → 오늘 안 했으면 `aps_cleanup_old_plans(365)` 1회 호출
    - 🗑 365일 정리 수동 버튼도 제공
- **운영 순서**: Supabase에서 `setup_aps_v3.sql` 실행 1회 → 기존 시작/완료 버튼 그대로 사용 → 통계 탭에서 누적 데이터 확인

### APS — 생산계획 리스트·간트 날짜 동기화 (2026-06-12)
- 기존: 간트차트의 이전날/오늘/다음날 버튼이 GanttView 내부 state(`dayStr`)만 갱신 → 리스트 뷰는 항상 전체(상태 필터만) → 사용자가 날짜를 바꿔도 리스트는 그대로
- 변경: `dayStr`를 `PlansTab`으로 끌어올려 리스트·간트 공유, 선택된 날짜와 겹치는 계획만 표시
- **`GanttView`**: `dayStr` prop 받도록 시그니처 변경, 내부 `useState`와 `shiftDay`/날짜 nav 버튼 제거. 좌상단 "근무 ··표시 X/Y건" 정보 + ⚙ 근무시간 버튼만 유지
- **`PlansTab`**: `dayStr`(default `todayStr()`) + `allDates`(default false) state 추가, `shiftDay(n)` 헬퍼 보유
- **`overlapsDay(p)`** useMemo: KST 00:00~24:00 범위와 plan의 `[start_at, end_at]` 겹침 판정 (둘 다 ms 비교)
- **`statusFiltered`**(상태 필터만) → 간트로 전달, **`listFiltered`**(상태+날짜 필터) → 리스트로 전달. `allDates=true`면 날짜 필터 skip → 리스트는 전체, 간트는 그 특성상 항상 선택일
- **상태 카운트**: `allDates`에 따라 base를 plans 전체 또는 해당 날짜만으로 동적 계산 → 토글 시 "전체 N"도 함께 갱신
- **두 번째 toolbar 행 추가**: `← 이전 날 / 오늘 / 다음 날 → / date picker / 🗓 전체 날짜 OFF·ON 토글 / 정보 텍스트`. `allDates=true`면 nav 버튼·picker disabled, opacity 0.5
- **정보 텍스트**: OFF 시 "리스트·간트 모두 YYYY-MM-DD", ON 시 "리스트: 전체 / 간트: 선택일"
- **empty 메시지**: 날짜 모드 시 "YYYY-MM-DD에 해당 상태의 계획이 없습니다"로 갱신 (전체 모드는 기존 "해당 상태의 계획이 없습니다" 유지)

### APS — 간트 행 높이 완만한 증가 (2026-06-14)
- 기존: 한 라인에 품목이 겹치면 `rowH=GANTT_ROW_H*laneCount` → 2레인 120px / 3레인 180px로 세로폭이 두 배·세 배로 커져 화면이 답답함
- 변경: 기본 행 높이는 유지하되 추가 레인은 작은 증분으로 늘리도록 변경
- `GANTT_LANE_EXTRA=30` 상수 + `rowHeightFor(laneCount)=GANTT_ROW_H+GANTT_LANE_EXTRA*(laneCount-1)` 헬퍼 도입
- 1레인 60px / 2레인 90px / 3레인 120px — 기존 대비 약 50% 압축
- 적용 위치: 좌측 라인 라벨 컬럼 / 본문 라인 행 / 현재시각 세로선 총 길이 3곳
- `laneH` 계산식도 새 rowH 기준 + 레인 간격(`GANTT_LANE_GAP=3` × (n-1))을 명시적으로 빼서 계산 → 2레인 약 40px, 3레인 약 35px로 막대 가독성 유지

### APS — 시간표 뷰 추가 (2026-06-20)
- 생산계획 탭 viewMode 토글에 **🕐 시간표** 옵션 추가 (리스트/간트와 동일한 데이터, 다른 표현)
- 어르신·신규 작업자용 가독성 우선 뷰: 학교 시간표 스타일(행=시간 1시간 단위, 열=라인)
- 막대 길이로 시간 읽기 → 셀에 "수량 · 시작~종료" 텍스트 직접 표시 (예: "100개 · 08:00~10:30")
- 글씨 크기: 품목명 17px(700), 수량/시간 15px, 상태 13px(700) — 간트 12px 대비 약 40% 큼
- 셀 구조:
  - 빈 셀: 그대로
  - **앵커 셀**(계획 시작 시간): 품목명 + 수량·시간 + 상태 라벨 풀 표시. 실선 상단
  - **연속 셀**(이전 시간부터 진행 중): 같은 색만 채움, 텍스트 없음, **점선 상단 테두리**로 이어짐 표시
- 같은 라인·같은 시간에 여러 계획이 겹치면 가장 먼저 시작한 것만 anchor로, 나머지는 "+N건 동시" 뱃지로 표시 (상세는 간트에서 확인)
- 컴포넌트 [aps.html `TimetableView`](aps.html): cellInfo useMemo로 (lineKey:hour) → {primary, isAnchor, extraCount} 맵 계산 → table tbody 렌더
- 셀 클릭 → 기존 `PlanForm` 모달 재사용 (간트와 동일)
- 현재 시각 행 시간 라벨 빨강 강조 (오늘 보고 있을 때만)
- 미지정 라인 가상 처리(간트와 동일 패턴)
- 별도 SQL 변경 없음, 기존 데이터/RPC 그대로 사용
- 한계: 30분 단위 미만의 미세 표현 불가(1시간 셀 단위 고정). 정밀한 시간 조정은 간트의 드래그 기능 이용

### APS — 간트 가독성 + 막대 드래그 시간 변경 (2026-06-13)
- **GanttView 글씨/셀 크기 확대**: 시간 컬럼 64→84px, 라인 행 48→60px, 라벨 폭 170→220px, 헤더 44→52px / 폰트 라인 헤더 12→14px, 라인 이름 13→15px, 메모 10→12px, 시간 라벨 11→13px, 막대 텍스트 10→12px
- **라벨 컬럼 부가 정보**: 라인 코드 → 라인 메모 표시 (메모 비어 있으면 코드 폴백), `wordBreak/overflowWrap`으로 줄바꿈 허용
- **막대 드래그로 시간 변경**: `planned`/`in_progress` 상태 막대를 드래그해 `start_at`/`end_at` 즉시 수정
  - 가운데 드래그 → 통째로 이동(start·end 동시 이동)
  - 좌·우 끝 12px 영역 드래그 → `start_at` 또는 `end_at`만 조정 (cursor `ew-resize`)
  - 15분 단위 스냅, 최소 길이 15분 보장
  - 4px 미만 이동 = 클릭으로 간주 → 기존 수정 모달 그대로 열림
  - 완료(`done`)/취소(`canceled`) 막대는 드래그 금지 (이력 보호) — 클릭만 가능
  - 드래그 중 막대가 새 위치로 실시간 이동(opacity 0.85 + shadow), 툴팁에 "드래그 중: HH:MM ~ HH:MM" 표시
  - 낙관적 업데이트로 즉시 반영 후 `aps_upsert_plan` RPC 호출 → 실패 시 `load()` 재호출로 롤백
  - 윈도우 이벤트(`mousemove`/`mouseup`) 핸들러는 `drag.planId` 변경 시에만 재바인딩(useRef로 최신 콜백/plans 참조) → mousemove마다 effect 재실행 회피
- 별도 SQL 변경 없음 (`aps_upsert_plan` 기존 사용)

### APS — 생산계획 탭 좌측 재고 패널 (2026-06-21)
- 사용자 요청: 재고 시트(엑셀 업로드)에 담긴 재고를 생산계획 짤 때 왼쪽에 보고 싶음
- 기존: 재고 시트 탭에서 업로드한 데이터는 React state에만 존재 → 탭을 떠나면 사라지고 다른 탭에서 볼 수 없음
- 변경: 업로드 데이터를 localStorage에 자동 저장 + 생산계획 탭에 토글로 좌측 사이드 패널 추가
- **localStorage 키 `aps-inv-data`**: `{products, raws, prodName, rawName, dateLabel, title, savedAt}` 한 객체로 저장
  - `loadStoredInventory()`/`saveStoredInventory(patch)` 헬퍼 (aps.html 내부)
  - 저장 시 `aps-inv-data-change` CustomEvent 발행 → 같은 탭 내 패널이 즉시 갱신 (storage 이벤트는 다른 탭에만 발생)
- **InventorySheetTab 변경**:
  - 마운트 시 `loadStoredInventory()`로 초기 state 복원 → 새로고침/탭 전환 후에도 마지막 업로드 유지
  - `handleFile` 성공 시 즉시 `saveStoredInventory({products|raws, ...})` 호출
  - `clearAll()`이 `localStorage.removeItem` + 이벤트 발행
  - `title`/`dateLabel` 변경 시(업로드 데이터 있을 때만) useEffect로 저장 → 패널 헤더 동기화
- **신규 `InventoryQuickPanel` 컴포넌트**: 생산계획 탭 좌측에 표시
  - localStorage + TEMPLATE_KEY를 읽어 템플릿 순서대로 제품 표시 (코드/이름/박스, 색상별 dot 인디케이터)
  - 검색 입력 → 코드·제품명 필터
  - 템플릿 외 추가 품목은 "+ 마스터 외" 섹션으로 분리
  - 원육은 접기/펼치기 가능한 별도 섹션 (기본 접힘), kg 내림차순
  - `storage` 이벤트 + `aps-inv-data-change` 이벤트 양쪽 구독으로 실시간 동기화
  - 데이터 없으면 "재고 시트 탭으로 이동" 버튼 (`window.location.hash="#sheet"`)
- **PlansTab 변경**:
  - `invPanelOpen` state, localStorage `aps-inv-panel-open`로 영속화
  - toolbar에 `📦 재고 ON/OFF` 토글 버튼 추가 (모든 view mode에서 표시 — list/gantt/timetable 공통)
  - 뷰 영역을 `<div className={invPanelOpen?"aps-plans-layout":""}>`로 감싸 패널이 열렸을 때만 flex 레이아웃 활성
  - 닫혔을 때는 빈 className → 기존 레이아웃 그대로 유지 (영향 없음)
- **CSS**: `.aps-plans-layout` (flex/gap:14), `.aps-plans-main` (flex:1, min-width:0), `.aps-inv-panel` (240px 폭, sticky top:14, max-height:82vh), `.aps-inv-panel-tbl` (11px 폰트, 색상 행 배경, zero 빨강), 980px 이하 반응형(세로 스택 + max-height:280px)
- 별도 SQL/DB 변경 없음. 데이터는 사용자 브라우저 localStorage에만 존재 (기기·브라우저 간 동기화 없음 — 2026-06-21 Supabase 동기화로 해소)

### APS — 재고 시트 Supabase 동기화 (PC ↔ 모바일) (2026-06-21)
- 사용자 보고: "컴퓨터에서는 재고 시트 저장돼 있는데 모바일로 보니까 저장 안 되어 있음" — 기존 localStorage 단일 저장은 기기·브라우저 간 동기화 불가
- 변경: 재고 시트 데이터(`{products, raws, prodName, rawName, title, dateLabel}`)를 Supabase 싱글톤 테이블에 함께 저장 → 모든 기기에서 동일한 재고 자동 표시
- **`setup_aps_inv_sheet.sql`** (신규, 1회 실행):
  - `aps_inventory_sheet` 테이블 (id=1 CHECK 싱글톤, payload JSONB, updated_at TIMESTAMPTZ)
  - RLS ENABLE + 정책 없음 → REST 직접 접근 차단, SECURITY DEFINER RPC로만 접근
  - RPC 3종: `aps_get_inventory_sheet`(payload+updated_at 반환), `aps_save_inventory_sheet`(upsert, updated_at 반환), `aps_clear_inventory_sheet`(delete)
  - 모든 RPC 첫 줄에서 `aps_assert_admin(p_admin_hash)` 검증
- **`aps.html` 변경**:
  - 헬퍼 추가: `loadRemoteInventory(adminHash)`, `saveRemoteInventory(adminHash,patch)`, `clearRemoteInventory(adminHash)`, `applyRemoteInventoryToLocal(remote)`
  - `saveStoredInventory(patch)`에 `patch.savedAt` 우선 적용 (서버 timestamp 반영 가능)
  - **InventorySheetTab(adminHash) 변경**:
    - 마운트 시 원격 fetch → `local.savedAt` vs `remote.savedAt` ISO 문자열 비교 → 새로운 쪽이 이김 (원격 새로움 → 로컬 교체, 로컬 새로움 → 원격 push)
    - handleFile 업로드 시 로컬 저장 + 원격 await push (실패 시 ⚠ 동기화 실패 뱃지)
    - clearAll() async 변경 → 로컬 + 원격 동시 삭제
    - title/dateLabel 변경 시 600ms 디바운스 후 원격 push
    - toolbar 우측에 동기화 상태 뱃지: ☁ 동기화 중… / ☁ 동기화됨 / ⚠ 동기화 실패
  - **InventoryQuickPanel(adminHash) 변경**: 마운트 시 원격 fetch → 로컬보다 새로우면 교체 + 이벤트 발행 → 다른 인스턴스도 자동 갱신
  - App에서 `<InventorySheetTab adminHash={adminHash}/>`, PlansTab에서 `<InventoryQuickPanel adminHash={adminHash}/>` prop 전달
- **충돌 해결**: payload는 항상 전체 교체(upload-as-whole-snapshot)이므로 partial merge 충돌 없음. last-write-wins (server `updated_at` 기준)
- **운영 순서**: Supabase에서 `setup_aps_inv_sheet.sql` 실행 1회 → PC에서 재고 업로드 → 모바일에서 APS 페이지 접속 시 자동으로 PC 업로드 데이터 fetch

### APS — 재고 시트 헤더 간격 + 날짜 자동 갱신 (2026-06-22)
- 사용자 보고: "PC에서 제목과 날짜 사이 공백이 너무 멀다 (모바일은 괜찮음). 그리고 날짜는 오늘 날짜로 자동 표시되게 해달라"
- 원인 1(공백): `.inv-sheet-header`가 `justify-content:space-between` + 좌측 `.inv-sheet-spacer(min-width:110px)` + `.inv-sheet-title{flex:1}` + 우측 `.inv-sheet-date(min-width:110px, text-align:right)` 구조 → PC 폭에서 제목은 중앙, 날짜는 우측 끝으로 밀려 시각적으로 멀어 보임. 모바일은 `min-width:60px`로 줄여놔서 가까웠음
- 원인 2(날짜): `useState(stored?.dateLabel||todayKoreanLabel())` + 원격 fetch 시 `if(remote.dateLabel)setDateLabel(remote.dateLabel)`로 저장된 라벨을 우선 복원 → 처음 자동 입력된 날짜가 영속화되어 다음날에도 어제 날짜 그대로 표시
- **변경 1(CSS)** ([aps.html:126-129](aps.html:126)): `.inv-sheet-header{justify-content:center}` + `.inv-sheet-title`의 `flex:1` 제거 + `.inv-sheet-date`의 `min-width:110px,text-align:right` 제거 + `.inv-sheet-spacer{display:none}` → 제목과 날짜가 헤더 가운데에서 `gap:16px`로 자연스럽게 붙음. 모바일 미디어쿼리는 그대로 둠(spacer는 display:none 우선되어 무영향)
- **변경 2(JS)** ([aps.html:2656](aps.html:2656), [aps.html:2679](aps.html:2679)): 초기 state를 `useState(todayKoreanLabel())`로 변경 → 로컬 stored.dateLabel 무시. 원격 fetch에서 dateLabel 복원 라인 제거 → 페이지 진입할 때마다 오늘 날짜로 자동 표시
- 보존: 사용자가 input에서 수동 편집은 가능. title/dateLabel 변경 시 600ms 디바운스로 원격 push되는 자동 저장 로직은 그대로 → 수동 편집한 날짜는 그 세션 동안만 유지되고, 다음 마운트 시 다시 오늘 날짜로 리셋됨
- 한계: 페이지를 띄워둔 채 자정 넘어가도 자동 갱신은 없음(새로고침 필요). 사용자 요구 범위에서 벗어나는 시간 기반 useEffect는 추가하지 않음

### APS — 생산계획 추가 모달 우측 슬라이드 + 리스트 라인별 그룹 + 수동 정렬 (2026-06-24)
- 사용자 요청 1: "생산계획 추가할 때 가운데 창 뜨는 게 불편 — 오른쪽에 뜨게"
- 사용자 요청 2: "계획 리스트는 라인별로 구분되면 좋겠어"
- 사용자 요청 3: "제품명은 추가한 순서대로 나열 + 순서변경되게"
- **변경 1 — PlanForm 우측 슬라이드 패널**: CSS에 `.aps-modal-bg.aps-side`(우측 정렬, padding 0) + `.aps-modal.aps-modal-side`(폭 480px, 100vh, `aps-slide-in` 0.22s 애니메이션) 추가. `PlanForm`에만 `aps-side`/`aps-modal-side` 클래스 적용 → 다른 모달(품목/BOM/라인/근무시간 등)은 가운데 정렬 그대로 유지. 모바일(<600px)은 전체 폭. 바깥 클릭 닫기 동작은 동일
- **변경 2 — 리스트 라인별 그룹화**: `PlansTab` 리스트 뷰의 tbody에서 `listFiltered`를 `line_id` 기준으로 Map 그룹핑 → 각 그룹마다 colSpan=7 헤더 행(`🏭 라인명·코드·N건`, 청록색 배경 + 상단 굵은 테두리) + 그룹 행들 렌더. 라인 코드 오름차순 정렬, 라인 미지정 그룹은 맨 아래. 기존 `라인` 컬럼은 헤더로 정보가 옮겨졌으므로 thead에서 제거 → 가로 폭 절약. 간트/시간표는 그대로(이미 라인별 행 구조)
- **변경 3 — 수동 정렬(sort_order) + ↑/↓ swap RPC**:
  - **`setup_aps_v4.sql`** 신규: `aps_plans.sort_order INT` 컬럼 + 기존 데이터 `UPDATE sort_order = id` 1회 초기화 + `idx_aps_plans_line_sort (line_id, sort_order)` 인덱스 + BEFORE INSERT 트리거 `aps_plans_assign_sort_order` (신규 INSERT 시 `MAX(sort_order)+1` 자동 부여 → upsert RPC 안 건드림)
  - `aps_list_plans` 재정의: 응답에 `sort_order` 포함, `ORDER BY sort_order ASC NULLS LAST, id ASC`로 변경 (기존 `start_at DESC`에서 변경) → 추가 순서가 자연스럽게 위→아래
  - 신규 RPC `aps_move_plan_order(p_admin_hash, p_id, p_direction)`: 같은 `line_id`(또는 둘 다 NULL) 그룹 내에서 인접 행과 `sort_order` swap. 인접 행 없으면 `{moved:false}` 반환. `p_direction`은 'up'|'down'
  - **`aps.html`**: `PlansTab`에 `movePlan(p, direction)` 핸들러 추가 → RPC 호출 후 `load()`. 리스트 thead의 `#` 컬럼(50px) → `순서` 컬럼(70px)으로 변경. tbody 행 첫 셀에 ▲ / `#id` / ▼ 세로 배치 (`flex-direction:column`, 그룹 내 첫 행은 ▲ disabled+opacity 0.3, 마지막 행은 ▼ disabled). 그룹 내 순서는 서버에서 이미 sort_order로 정렬되어 오므로 `g.plans.map((p,idx)=>...)`의 idx로 첫/끝 판정
- **운영 순서**: Supabase에서 `setup_aps_v4.sql` 실행 1회 → 기존 계획은 id 순서로 자동 정렬 → 이후 추가되는 계획은 트리거로 자동 부여 → ▲▼로 라인별 그룹 안에서 순서 조정
- **한계**: ↑/↓는 인접 행 한 칸씩 swap만 지원 (drag-and-drop 미구현). 그룹 간 이동은 라인 자체를 변경(수정 모달에서 라인 picker) 후 그룹 내에서 다시 정렬해야 함

### APS — 생산계획 탭 viewMode 영속화 + 현재 뷰 PNG 저장 (2026-06-24)
- 사용자 요청 1: "계획에서 새로고침하면 자꾸 간트차트로 넘어가는데" — viewMode가 `useState("gantt")`로 매번 초기화되던 문제
- 사용자 요청 2: "계획을 사진파일로 저장할수있을까?"
- **viewMode 영속화** ([aps.html PlansTab](aps.html)): `useState(()=>localStorage.getItem("aps-plan-view-mode")` whitelist(`list`|`gantt`|`timetable`) + 폴백 `"gantt"`. 변경 시 `useEffect`로 자동 저장 → 다음 새로고침에도 마지막으로 보던 뷰 유지. `invPanelOpen`/`aps-plan-view-mode` 동일 패턴
- **생산계획 PNG 저장 (전용 ExportPlansView 컴포넌트, 2026-06-24 v2)**:
  - 초기 시도(2026-06-24 v1)는 현재 화면(`viewMode` 분기 div)을 그대로 캡처했으나 사용자 피드백: "캡처보단 깔끔하게 다듬어서 해줘"
  - **변경**: 기존 주간 요약 export(`ExportWeekView` + 오프스크린 마운트) 패턴을 그대로 따라 `ExportPlansView` 신규 컴포넌트 작성
  - `ExportPlansView({plans, lines, dayStr, allDates})`: 820px 고정 폭, 라이트 테마(흰색 배경 + 진한 텍스트), Pretendard 폰트, 라인별 그룹 카드(라인명 + 메모) → 각 그룹 안에 `<table>`로 품목/수량/시작·종료/상태 컬럼 정리. `colgroup`으로 컬럼 폭 36%/16%/33%/15% 고정. 짝수 행 살짝 어두운 배경(zebra)
  - 헤더: "PRODUCTION PLAN · DAILY PLAN" 또는 "ALL PERIODS" + 날짜(또는 "전체 기간") + 총 N건 카운트
  - 푸터: STOCKPULSE · APS 브랜드 + 생성 시각(`new Date().toLocaleString("ko-KR")`)
  - 상태 뱃지 색상은 라이트 테마 전용 팔레트(`#f1f5f9`/`#cffafe`/`#dcfce7`/`#fee2e2`) — STATUS_PILL의 다크 변종이 아닌 인쇄 친화 색
  - **렌더 흐름**: `capturing=true` → 다음 paint 사이클 대기 → 오프스크린 div(`position:fixed; left:-99999`) 안의 `ExportPlansView` 마운트 → `html2canvas(exportPlansRef.current, {scale:2, backgroundColor:"#ffffff"})` → PNG 다운로드 → `capturing=false` → 오프스크린 div 언마운트
  - 표시 데이터는 `listFiltered`(상태 필터 + allDates 토글에 따라 단일일 또는 전체) 그대로 전달 → 화면에 보이는 그대로 저장
  - 파일명: `생산계획_{날짜|전체}.png`. viewMode와 무관(어느 뷰에서 저장해도 동일한 깔끔한 리포트)
  - 툴바 우측 "+ 생산계획 추가" 옆 `📷 이미지 저장` 버튼 (캡처 중 "저장 중...", `plans.length===0`이면 disabled)
- **한계**: viewMode가 간트/시간표여도 결과 PNG는 항상 라인별 리스트 형태(시각적인 시간축 차트로 저장하고 싶으면 후속 작업 필요). side panel(재고/주간 요약) 미포함. 라인 메모가 비어 있으면 라인명만 표시

### APS — 생산계획 1주일치 긴 이미지 저장 (2026-10-26)
- 사용자 요청: "생산계획 1주일치가 이미지로 길게 쭉 보이게"
- 생산계획 툴바 `📷 이미지 저장` 옆에 `📷 1주일 (길게)` 버튼 → 선택한 날짜(🗓 전체 날짜 모드면 오늘)부터 7일치를 날짜 순으로 세로로 이어 붙인 PNG 1장 (`생산계획_1주일_{시작}_{끝}.png`)
- 신규 `ExportWeekLongView` (같은 날 사용자 요청 "더 깔끔하고 가독성 있게"로 처음 버전 — 날짜마다 `ExportPlansView` 반복 — 을 전용 레이아웃으로 교체):
  - 머리: "주간 생산계획" + 기간(요일 포함) + 오른쪽 총 건수·박스·kg
  - 7일 한눈에 보기: 요일·날짜·건수 칸 7개 (토 파랑/일 빨강, 오늘 주황 테두리, 계획 없는 날 회색 "–")
  - 날짜마다 띠(큰 날짜+요일, 왼쪽 요일색 선, 오늘이면 노랑 배경 + "오늘") + 오른쪽 그날 건수·박스·kg → 표 1개(시간 / 라인 칩 / 품목·원육·메모 / 수량·kg). 줄 순서 = 라인 코드 → 시작 시각, 라인 칩은 라인이 바뀌는 줄에만 표시하고 라인 경계는 진한 선
  - 상태 뱃지는 진행중·완료·취소만(계획은 표시 안 함), 취소는 흐리게 + 취소선 + 합계에서 제외. 다른 날로 넘어가는 시각은 `10.27 08:00`처럼 날짜 표기
  - 계획 없는 날은 띠만 "계획 없음"으로 표시
  - `ExportPlansView`의 `hideFooter` prop은 남아 있지만 지금은 사용하지 않음
- 날짜별 계획 = 상태 필터 적용 + 그날(KST 00~24시)과 겹치는 계획 (하루 이미지와 같은 기준). 원육은 7일 계획을 모아 `buildExportMaterialsFor` 1번 호출
- 너무 길면 캔버스 한도를 넘지 않게 배율 2 → 최소 1로 낮춤(`30000/높이`)
- 가짜 데이터로 확인: 16건 → 1640×4538px. SQL 변경 없음

### APS — 📋 작업지시서 (2026-10-28)
- 사용자 고민: "작업자에게 지시가 애매하다" → 라인별 작업지시서 한 장
- 생산계획 툴바 `📋 작업지시서`(전체 날짜 모드에서는 비활성) → `WorkOrderModal`: 라인 칩 선택 / 왼쪽 입력 / 오른쪽 미리보기(794px 종이를 `zoom`으로 축소, 1100px 이하는 세로 배치)
- 종이(`WorkOrderSheet`, 794px 흰 바탕): 제목 "작업지시서" + 날짜(요일) + 라인 색 뱃지 + 담당자(비우면 손으로 쓰는 밑줄) / 작업 건수·총 박스·kg·근무·점심 / 📢 오늘 전달사항(빨강 상자) / 작업 카드(시작 시각 순 번호, 시간+소요, 품목명 22px, 코드·규격·입수, 수량 30px + kg, 🥩 원육 필요 kg + 재고시트에서 매칭된 원육 이름·kg + 부족 시 빨강 뱃지, 📏 작업 기준, 📝 이번 지시, 손으로 적는 칸: 시작/완료/실제 수량/확인 □) / 점심 시작 이후 첫 작업 앞에 🍱 점심 줄 / 특이사항 3줄
- 원육은 기존 `buildExportMaterialsFor` 재사용. 취소된 계획은 제외
- 저장(SQL 변경 없음, 기존 `aps_set_setting`): `wo:{날짜}:{라인id|none}` = `{leader, note}` JSON, `wo_item:{품목id}` = 작업 기준(품목에 붙어 매번 표시). 이번 지시 = 계획 `memo`(`aps_upsert_plan`, 리스트·이미지 메모와 같은 칸). 입력칸에서 나가면 자동 저장
- **A4 세로 저장 (같은 날 사용자 요청)**: 종이 = 794px(A4 폭), 여백 38px(10mm), 내용 폭 718px. `WO_A4`/`woSlices`/`woCutsOf`/`woA4Pages` — 내용(`[data-wobody]`)을 한 번 캡처(scale 3)한 뒤 `[data-wocut]`(전달사항·작업 카드·점심 줄·특이사항) 경계에서만 쪽을 나눠 794×1123 종이에 붙임 → 작업 카드가 쪽 사이에서 잘리지 않음. 1.15쪽 이하는 한 쪽에 축소, 마지막 쪽이 짧으면(앞 쪽과 합쳐 1.2쪽 이하) 앞 쪽에 축소해 붙임. 2쪽부터 위에 "작업지시서 · 날짜 · 라인 (이어서)", 여러 쪽이면 아래 `n / 전체`. 라인마다 새 쪽에서 시작
- 형식 토글 📄 PDF(기본, jsPDF 2.5.1 cdnjs 추가 — 한 파일) / 🖼 PNG(쪽마다 파일, 700ms 간격), localStorage `aps-wo-fmt`. 버튼 `🖨 이 라인 A4 저장` / `🖨 전체 라인 A4 저장`. 파일명 `작업지시서_{날짜}[_{라인}].pdf`, PNG는 `_{라인}_{n}쪽`. 예전 긴 이미지 저장 버튼은 삭제
- 미리보기 제목에 "A4 세로 N쪽", 쪽이 넘어가는 자리에 빨간 점선 + "✂ N쪽 시작"(저장 이미지에는 없음)
- 가짜 데이터로 확인: 1라인 7건 → 2쪽, 2라인 1건 → 1쪽, PDF 3쪽. 실제 로그인 화면·실제 프린터 출력은 미확인
- 한계: 모바일에서 PNG 여러 장은 첫 장만 받아질 수 있음(PDF 사용). `aps_settings`에 날짜별 키가 계속 쌓임(용량 미미, 정리 없음). 점심을 걸치는 작업은 그 작업 다음에 점심 줄이 나옴. 작업 카드 하나가 한 쪽보다 길면 쪽 높이에서 잘림

### APS — 📦 발주 부족 알림 (발주서 → 생산계획) (2026-10-28)
- 사용자 요청: 발주서를 올리면 재고가 모자란 제품을 생산계획 탭에 알림 + 그 날짜에 계획 추가 버튼. 입고일 하루 전까지는 꼭, 이틀 전이면 더 좋음. 안전재고는 남기고 계산(추천안)
- 쿠팡 상품코드 ≠ APS 품목 코드 → 연결표: **`setup_orders_aps_link.sql`** (신규, 1회 실행 — setup_orders.sql 끝에도 반영): `ol_products.aps_item_id BIGINT NULL` + `ol_set_product_aps_item(hash,id,aps_item_id)` + `ol_list_aps_items(hash)`(aps_items 제품/반제품의 id·code·name·type·spec, 인증 없음 — 다른 `ol_*`와 같음). 여러 발주 제품이 한 APS 품목을 가리켜도 됨
- **orders.html**: 제품 폼에 "🔗 APS 품목" 선택(+ 이름이 비슷한 품목 추천 `suggestApsItem` — 괄호·중량·기호 뺀 2글자 묶음 유사도, 0.45 이상 → "이걸로 연결"). 값이 바뀐 경우만 `ol_set_product_aps_item` 호출, SQL 미실행이면 폼에 빨간 안내. 제품표 이름 아래 `🔗 APS 품목명` / 주황 `🔗 APS 미연결`, 생산지점 칩 줄에 "🔗 APS 미연결 N" 필터. APS 목록은 모듈 캐시(`loadApsItems`/`useApsItems`)
- **aps.html `OrderShortagePanel`** (생산계획 탭 툴바 아래, 접기 상태 localStorage `aps-order-alert-open`):
  - 오늘 ~ +21일(`ORDER_ALERT_DAYS`) 입고 발주를 `ol_list_orders` 일반+추가로 읽고 `ol_list_masters` 제품으로 APS 품목 매칭. 필요 박스 = 발주수량 ÷ 입수량(per_box)
  - `computeOrderShortages`: 품목별로 입고일 순서대로 누적 — 쓸 수 있는 박스 = max(0, 재고시트 박스 − 안전재고) + 계획/진행중 계획 중 오늘 이후 ~ 마감일 사이에 끝나는 수량. 부족 = 누적 필요 − 쓸 수 있는 − 앞 입고일 부족분(그날 알림으로 만들 것으로 봄 → 재고 두 번 안 셈), 올림
  - 마감 = 입고일 1생산일 전, 권장 = 2생산일 전(`nthProdDayBefore`, 생산 요일은 🤖 자동 생성 옵션 `aps-autoplan-opts-v2.prodDays`, 기본 월~금). 권장일이 지났으면 "⚠ 마감" 버튼만. 마감도 지난 건은 표시하지 않음(같은 날 사용자 요청 — 계산에는 남아 뒤 입고일 부족분이 중복되지 않음)
  - 버튼 → 날짜를 그날로 바꾸고 `PlanForm`을 `prefill`(품목·부족 수량·라인·시간·메모 "M/D 입고 발주분")로 연다. 라인/시간 = `suggestPlanSlot`: 품목 생산 라인 중 그날 가장 빨리 비는 라인(기존 계획 끝 or 근무 시작, 오늘이면 지금 이후, 15분 올림, 점심 건너뜀), 길이 = 수량 ÷ 시간당 생산량(통계 180일 → 품목 units_per_hour, 없으면 1시간 + 안내). 저장하면 그 계획이 "마감 전 계획"에 들어가 알림이 사라짐
  - 빠진 제품 표시: APS 미연결 / 제품리스트에 없는 상품코드 / 연결한 APS 품목 삭제됨 → "🔗 APS 연결 안 된 발주 제품 N개" 칩으로 목록 + orders.html 링크
  - 재고시트가 비었거나 오늘 이전 기준이면 ⚠ 안내. 발주서 테이블이 없으면(발주서 미사용) 패널 자체를 안 보임, `aps_item_id` 컬럼이 없으면 SQL 실행 안내
- 확인: 가짜 데이터(재고 22 · 안전 10 · 계획 5 · 발주 20/10박스) → 3/10/10박스 부족, 권장·마감 날짜, 계획 추가 창 미리 채움(1라인 10:00~11:00) 확인. orders.html 제품 폼 추천·선택은 가짜 APS 목록으로 확인(저장은 안 함). 실제 DB 연결은 SQL 실행 후 미확인
- 한계: 쿠팡 박스 = APS 박스로 가정(입수량으로만 환산). 재고시트 업로드 후 판매분·쿠팡 외 주문은 안전재고로만 대비. 반제품 BOM 소요 미반영. 발주서는 입고일 기준 1달 보관
- **발주서 최근 업로드 시각 (같은 날)**: orders.html 📄 발주서(➕ 추가 발주서도) 업로드 버튼 옆 `🕒 최근 업로드 10/28 (수) 12:57 · 입고 10/28 (수)`(누르면 그 입고일로 이동), 입고일 제목 옆 "이 날짜 최근 업로드", 발주서 카드마다 "🕒 … 업로드". 시각 = `ol_orders.created_at`(같은 발주번호 재업로드 시 now()로 갱신). 전체 입고일 기준 최신값은 `ol_list_due_dates`에 추가한 `last_upload`(MAX(created_at)) — **setup_orders_aps_link.sql 안에 함께 들어 있음**(setup_orders.sql도 반영). SQL 실행 전에는 지금 보는 입고일 발주서 기준으로 표시(`fmtUploadAt`, 브라우저 시간대)

### APS — 생산계획 PNG에 품목 규격 × 수량 표시 (2026-06-25)
- 사용자 요청: "생산계획 이미지에 개수만 뜨는데 개수도 뜨고 옆에 품목에서 규격/사양 × 개수도 뜨면 좋겠어"
- 기존: `ExportPlansView` 품목 셀에는 품목명 + 코드만, 우측 수량 셀에 `qty 단위` 표시 → 규격 정보 누락
- 원인: `aps_list_plans` RPC가 `i.spec`을 응답에 포함하지 않아 클라이언트에 `item_spec` 필드 자체가 없었음
- **`setup_aps_v5.sql`** (신규, 1회 실행): `aps_list_plans` DROP+CREATE로 응답 JSON에 `'item_spec', i.spec` 한 필드만 추가. 다른 필드/정렬/시그니처는 v4와 동일 (idempotent, 기존 데이터 영향 없음)
- **`aps.html` `ExportPlansView`**: 품목 셀(좌측) 안 품목명과 코드 사이에 `박스당 {p.item_spec} × {fmtNum(p.qty)}{p.item_unit||"박스"}` 라인 추가. 의미: spec은 박스당 중량(예: 500g/1kg), qty는 박스 수량. `(p.item_spec||"").trim()` 가드로 규격 없는 품목은 줄 자체를 숨김 → 후방 호환. unit 비어 있으면 "박스"로 fallback. 우측 수량 셀(개수 + 단위)은 그대로 유지 → 사용자 요청대로 "개수도 뜨고 옆에 규격×개수도" 동시 표시
- 적용 위치: PNG export 전용 컴포넌트만 (리스트/간트/시간표 화면 표시는 기존 그대로). 화면 표시까지 일관시키고 싶으면 후속 단계에서 `PlansTab` 리스트 행도 동일 패턴으로 확장 가능

### APS — 박스당 중량 × 박스 수량 = 총 kg 표시 (PNG + 리스트, 2026-06-25)
- 사용자 피드백: "규격×수량이 아니라 수량옆에 kg으로 따로 곱해서 표기 필요. 이미지에만 뜨게하지말고 리스트에도"
- 직전 변경(PNG에 "박스당 spec × qty" 한 줄 묶음)은 곱셈 결과(총 kg)가 없고 리스트는 그대로 → 사용자 의도와 불일치 → 재설계
- **헬퍼 신설** (전역, `fmtKstTime` 직후):
  - `parseSpecKg(spec)`: "500g" / "1kg" / "2.5kg" / "1,500g" 등을 kg(number)로 파싱. 정규식 `^([\d.,]+)(kg|g)$` 매칭 실패 시 null → 후방 호환
  - `fmtKg(kg)`: 1kg 이상은 kg, 미만은 g. 불필요한 0 제거 (예: 50→"50kg", 0.5→"500g", 2.5→"2.5kg")
- **`ExportPlansView` (PNG)**:
  - 품목 셀 안 "박스당 spec × qty" 라인 제거 → 품목명 + 코드만 (원래 모습 복원)
  - 수량 셀에 두 번째 줄 추가: `× {spec} = {fmtKg(kg*qty)}` (예: "100박스" 아래 "× 500g = 50kg")
  - spec 파싱 실패 시 두 번째 줄 자체를 숨김
- **`PlansTab` 리스트 뷰** 수량 td도 동일 패턴 적용:
  - 1줄: 기존 `qty + unit` 유지
  - 2줄: `× spec = 총kg` (회색 + 총kg만 본문색·굵게로 강조)
- 적용 범위: PNG export + 리스트. 간트/시간표/툴팁은 미적용 (셀이 빽빽해서 가독성 저하 우려)

### APS — 생산계획 PNG 헤더·행에 요일 표시 (2026-06-25)
- 사용자 요청: "이미지에 요일도 뜨면 좋겠어"
- 기존: 헤더는 `2026.06.25`, 행은 `06/25 09:00` 형식 → 요일 없음. allDates 모드에서 여러 날짜가 섞일 때 특히 불편
- 변경: `ExportPlansView` 안에 로컬 헬퍼만 추가 (전역 `fmtKstDateTime`은 다른 화면에서 쓰여 영향 회피)
  - `dowOfDayStr`: `dayStr`("YYYY-MM-DD") → `Date.UTC(y,m-1,d).getUTCDay()` → DOW_LABEL 인덱스 변환 `(uDay+6)%7` (DOW_LABEL은 월=0 시작)
  - dateLabel: `"2026.06.25"` → `"2026.06.25 (목)"`. allDates 모드는 "전체 기간" 그대로 (날짜 단일이 아니므로 요일 의미 없음)
  - `fmtDtDow(iso)`: KST 변환 후 `MM/DD(요일) HH:MM` 형식으로 출력 → 각 행의 시작/종료 시각에 요일 인라인 표시
- 적용 위치: `ExportPlansView` 헤더 dateLabel + 행의 시작/종료 시각 (`fmtKstDateTime` → `fmtDtDow`)

### APS — 매출 일보 업로드 + 월평균 안전재고 (2026-06-28)
- 사용자 요청: "매출일보(매출.xlsx) 업로드하면 1년치 저장하면서 월평균 통계. A/D/E/H 셀 사용. 상품코드가 재고시트 제품코드와 일치하는 항목에 한달평균 안전재고 자동 입력. 현재재고는 재고시트에서 연동"
- **`setup_aps_sales.sql`** (신규, 1회 실행):
  - `aps_sales_daily(date DATE, code TEXT, name TEXT, qty NUMERIC, PRIMARY KEY(date,code))` + RLS ENABLE
  - 인덱스: `idx_aps_sales_code(code)`, `idx_aps_sales_date(date DESC)`
  - RPC 5종 (모두 `aps_assert_admin` 첫 줄 검증):
    - `aps_upsert_sales_batch(hash, rows JSONB)`: 업로드 범위 `[min, max]` DELETE 후 INSERT — 재업로드 idempotent. 같은 (date,code) 충돌 시 qty 누산
    - `aps_get_sales_stats(hash, days)`: 최근 N일 품목별 집계 — `total_qty`, `days_with_sales`, `avg_daily`(=total/days), `avg_monthly`(=avg_daily×30), first/last_date
    - `aps_get_sales_meta(hash)`: `total_rows`, `distinct_codes`, `min_date`, `max_date`
    - `aps_cleanup_sales(hash, days=365)`: 1년 초과 데이터 삭제
    - `aps_clear_sales(hash)`: 전체 초기화
- **`aps.html` 변경**:
  - `VALID_TABS`에 `"sales"` 추가, 6번째 탭 **💰 매출** 추가 (📋 재고 시트 오른쪽)
  - 헬퍼 추가: `normalizeSalesDate(v)` — Date 객체/Excel serial/`YYYY/MM/DD` 모두 → `YYYY-MM-DD` 정규화. `parseSalesWorkbook(buf)` — A/D/E/H 컬럼 추출 + (date,code)로 그룹 합산 + 합계행("합 계" 같은 한글-only 셀) 자동 스킵. `fmtSalesNum(n,digits)` — 천단위 한국어 포맷
  - **`SalesTab({adminHash})`** 신규 컴포넌트:
    - 상단 4개 요약 카드: 저장 행 / 등록 상품 / 보유 기간 / 재고시트 매칭 수
    - 기간 필터(7/14/30/60/90/180/365일), 코드·상품명 검색, 정렬(한달평균↓/부족량↓/현재재고↓/코드순), "재고시트 매칭만" 토글, 🗑365일 정리, ⚠전체 초기화
    - 메인 테이블: # / 상품코드 / 상품명(재고시트 매칭 시 📋 뱃지) / N일 판매 / 일평균 / **한달평균(안전재고 추천)** / **현재재고(재고시트)** / 상태(품절/부족 X/정상/판매없음/—)
    - 데이터 가공: `invMap`(재고시트 products by code) → stats와 merge → `displayName` 우선순위(재고시트 name > 매출 name) + `currentStock`(재고시트 box) + `shortage`(avg_monthly - currentStock)
    - 재고시트 변경 실시간 구독: `storage` 이벤트 + `aps-inv-data-change` CustomEvent + 마운트 시 `loadRemoteInventory(adminHash)` (다른 기기 업로드 동기화)
  - 업로드 흐름: 파일 선택 → SheetJS(`cellDates:true`)로 파싱 → (date,code) 그룹 합산 → 500행씩 배치로 `aps_upsert_sales_batch` 호출 → 성공 시 메타+stats 자동 새로고침
- **Excel 인코딩 노트**: 매출.xlsx는 ERP에서 깨진 UTF-8/CP949 혼합 인코딩 — 그러나 SheetJS는 정상 디코딩 가능(openpyxl과 달리). 노드 테스트: 604행 → 592행 유효 매출, 203개 (date,code) 그룹, 82개 상품, 한글명 정상
- **운영 순서**: Supabase에서 `setup_aps_sales.sql` 실행 1회 → 💰 매출 탭에서 매출.xlsx 업로드 → 재고시트 탭에 제품코드 등록되어 있으면 자동 매칭

### APS — 매출 수량을 I열 ÷ 품목 입수량으로 집계 (2026-10-20)
- 사용자 요청: 매출 업로드 시 H열(box) 대신 I열(수량)을 읽고 품목의 **입수량**으로 나눠 박스 수로 집계 (예: I=60, 입수량 12 → 5박스). 처음엔 규격/사양으로 나눴다가 같은 날 사용자 요청으로 별도 입수량 칸으로 변경
- **`setup_aps_pack_qty.sql`** (신규, 1회 실행, v10 전제): `aps_items.pack_qty NUMERIC NULL` + `aps_list_items` 재정의(`pack_qty` 포함) + `aps_set_item_pack_qty(hash, item_id, qty)`(0 이하/NULL = 미설정). `aps_upsert_item` 시그니처는 그대로
- **ItemForm**(제품/반제품만): 규격/사양 옆에 "입수량" 숫자 칸. 저장 시 `aps_upsert_item` 후 `aps_set_item_pack_qty` 호출(SQL 미실행이면 안내 alert)
- `parseSalesWorkbook(buf, packQtyByCode)`: 행마다 `I ÷ 입수량`. 입수량이 없는 상품이나 I열이 빈 행은 H열(box) 그대로 → 업로드 후 빨강 경고로 상품 목록 표시
- `SalesTab.handleFile`: 업로드 전 `aps_list_items`로 코드별 입수량 로드. 소수는 3자리 반올림 저장
- 단위가 박스 그대로라 주평균·안전재고·자동 생성 로직은 그대로
- **보강 (같은 날)**: 사용자 보고 "여전히 H열로 불러오는 것 같다" → 코드 비교를 `salesCodeKey`(공백·앞 작은따옴표 제거 + 대문자)로 양쪽 정규화, I/H열 숫자는 `salesNum`으로 `"1,200"` 같은 문자열도 읽음. 업로드 완료 메시지에 `I열÷입수량 N행 / H열 M행 · 입수량 등록 품목 K개 · I열 제목 "…"` 표시(헤더 행에서 H/I 제목 탐지). 📦 품목표 품목명 아래에 `입수량 N` 표시 → 저장 여부 확인 가능
- **저장 실패 표시 (같은 날)**: 사용자 보고 "입수량 1 넣었는데 3(H열)으로 나옴" — 입수량 저장 실패 안내가 `alert()`라 앱 내장 브라우저에서 안 보였을 가능성. ItemForm은 `aps_set_item_pack_qty` 실패 시 창을 닫지 않고 빨간 글씨로 표시. 매출 업로드는 `aps_list_items` 응답에 `pack_qty` 필드가 아예 없으면(SQL 미실행) H열로 넣지 않고 업로드 중단 + 안내. 샘플 매출 파일 확인: H=수량(Box), I=수량(Kg), 대부분 상품은 I = H × 입수량이라 I÷입수량 결과가 H와 같고, `(작업)` 같은 무게 판매 상품만 달라짐(예: 돼지삼겹살(작업) 입수량 1 → I 그대로)
- **날짜별 보기 캐시 버그 (같은 날)**: `SalesDatesView`가 펼친 날짜의 상품별 판매(`detail`)를 캐시하고 업로드 후(`refreshKey` 변경)에도 비우지 않아, 다시 올려도 예전 값(H열 3)이 계속 보였음 → refreshKey 변경 시 캐시를 비우고 펼쳐 둔 날짜는 다시 조회. 업로드 메시지에 I열÷입수량으로 계산한 상품명도 표시
- **기존 업로드분은 H열 기준**이므로 입수량 입력 후 같은 매출 파일을 다시 업로드해야 새 산식으로 바뀜

### APS — 매출 날짜별 삭제 (2026-10-20)
- 사용자 요청: 💰 매출 탭 📅 날짜별 보기에서 날짜 하나씩 삭제
- **`setup_aps_sales_delete.sql`** (신규, 1회 실행): `aps_delete_sales_date(p_admin_hash, p_date)` — `aps_assert_admin` 검증 후 `DELETE FROM aps_sales_daily WHERE date = p_date`, 반환 `{deleted, date}`
- **`SalesDatesView`**: 각 날짜 행 오른쪽에 🗑 삭제 → 그 자리에서 "이 날짜 매출을 삭제할까요? [삭제] [취소]" (앱 내장 브라우저에서 `confirm()`이 안 뜨는 문제 회피). 행 클릭(펼치기)과 충돌 안 하게 `stopPropagation`. 삭제 후 목록에서 제거 + `onChanged`(=`loadAll`)로 상단 요약·상품별 통계 새로고침. SQL 미실행이면 안내 메시지
- 한계: 삭제해도 📦 품목 안전재고는 자동 재계산되지 않음 → 필요하면 💰 안전재고 동기화 버튼

### APS — 📊 재고 탭에 재고시트 박스 수 연동 (2026-06-28)
- 사용자 요청: "재고탭에 재고수량이 재고시트랑 연동되게 해달라"
- 기존: 📊 재고 탭의 `current_stock`은 `aps_inventory_view`(= `aps_stock_txns` 누적값)만 사용 → 재고시트 업로드 데이터와 완전히 분리됨
- 변경: 재고시트(`aps_inventory_sheet` Supabase + localStorage `aps-inv-data`)의 박스 수를 우선 표시, 매칭 없는 품목만 거래내역 fallback
- **`InventoryTab` 변경** ([aps.html:956](aps.html:956)):
  - `sheetInv` state 추가 (`loadStoredInventory()` 초기화)
  - 마운트 시 원격 fetch (`loadRemoteInventory(adminHash)`) → 로컬보다 새로우면 교체 (PC/모바일 동기화)
  - `storage` + `aps-inv-data-change` 이벤트 구독 → 재고시트 탭에서 업로드/삭제 시 실시간 갱신
  - `sheetMap` useMemo: products + raws의 code → product 객체 매핑
  - `linked` useMemo: `inv`를 순회하며 sheetMap에 매칭되는 코드는 `current_stock=sheet.box`로 덮어쓰기 + `stock_status` 재계산(0=품절, <safety_stock=부족, 이상=정상) + `_source:"sheet"` 마킹
  - 매칭 없는 품목은 `_source:"txn"` (기존 거래내역 그대로)
  - `filtered`/`counts`/`sheetLinkedCount` 모두 `linked` 기준으로 계산 (정확한 필터/통계)
- **UI 변경**:
  - 상단에 안내 박스: "📋 재고시트와 N개 품목 연동 중 — 시트의 박스 수가 우선 표시됩니다. 매칭되지 않는 품목은 입출고 누적값을 사용합니다." (sheetLinkedCount>0일 때만)
  - 품목명 뒤에 📋 뱃지(`_source==="sheet"`만, `title="재고시트 연동"`)
  - 단위 표시도 동적: 시트 매칭이면 "박스", 거래내역이면 기존 `unit`
- **검증**: 매출 Excel 업로드 후 재고시트에 113개, aps_items 41개 등록 상태에서 32개 매칭 → 필터 카운트 "정상 32 / 품절 9 / 부족 0"으로 정확히 분류됨. 매칭 품목은 "3 박스" + 📋 + 정상, 미매칭은 "0 EA" + 품절 fallback 유지

### APS — 품목 안전재고에 매출 한달평균 자동 동기화 (2026-06-28)
- 사용자 요청: "제품탭에 안전재고에는 매출 1달 평균값이 적히도록"
- 기존: `aps_items.safety_stock`은 수동 입력 전용 → 매출 변동 반영 안 됨
- 변경: 매출 한달평균(avg_monthly = 기간 총량/일수×30) 값을 `aps_items.safety_stock`으로 일괄 동기화 (코드 매칭 기준)
- **`setup_aps_sales.sql` 신규 RPC `aps_sync_safety_from_sales(hash, days=30)`**:
  - 최근 N일 매출 stats CTE → `UPDATE aps_items i SET safety_stock = s.avg_monthly FROM stats s WHERE i.code = s.code`
  - 매출 데이터 없는 품목은 건드리지 않음 (JOIN 절로 자연스럽게 제외)
  - `safety_stock IS DISTINCT FROM s.avg_monthly` 조건으로 변경 없는 행은 skip (updated_at 불필요한 갱신 회피)
  - 반환: `{updated, matched, period_days}` — matched는 매출 있는 매칭 행 수, updated는 실제 값이 바뀐 수
- **`aps.html` `SalesTab` 변경**:
  - `handleFile` 끝에 자동 호출: 업로드 성공 직후 `aps_sync_safety_from_sales(range)` → 토스트 메시지에 "안전재고 N/M건 자동 갱신" 추가. 동기화 실패는 ⚠ 경고만 표시(업로드 자체는 성공 처리)
  - 신규 `handleSyncSafety()`: 수동 트리거 (재실행/재계산용). 사용자 수동 안전재고 덮어쓰기 경고 confirm
  - 툴바에 "💰 안전재고 동기화" 버튼 추가 (시안 강조 색, 365일 정리 옆)
  - 사용법 안내에 "5. 매출 업로드 시 📦 품목/BOM 탭의 안전재고도 한달평균값으로 자동 갱신" 추가
- **의도된 부수효과**: `safety_stock` 변경으로 📊 재고 탭 stock_status(out/low/ok) 계산도 자동으로 매출 평균 기준으로 업데이트됨 → 매출 1달 평균보다 현재재고 적으면 "부족" 표시
- **한계**: 사용자가 수동 설정한 safety_stock 값이 덮어써짐. 수동 트리거에는 confirm 경고 있지만 자동 동기화(업로드 시)는 그냥 갱신. 수동값 보존이 필요하면 후속 단계에서 `aps_items`에 `safety_stock_manual` 플래그 추가 필요
- **운영 순서**: Supabase에서 신규 RPC만 추가 실행 (`setup_aps_sales.sql` 의 `aps_sync_safety_from_sales` 함수 블록) → 다음 매출 업로드부터 자동 동기화. 이미 업로드된 데이터에는 💰 안전재고 동기화 버튼 1회 클릭

### APS — 매출 안전재고 기준을 한달평균 → 주평균(7일)으로 변경 (2026-06-28)
- 사용자 요청: "한달평균을 주단위로 합산해서 가능할까? 하루에 나가는 평균말고 주마다 얼마나 나가는지"
- 기존: avg_monthly = 일평균 × 30 (월 단위) — 발주 주기 짧은 비즈니스에 과한 안전재고
- 변경: avg_weekly = 일평균 × 7 (주 단위) — 1주일에 평균적으로 나가는 박스 수 기준
- **`setup_aps_sales.sql` 변경**:
  - `aps_get_sales_stats` 응답에 `avg_weekly` 필드 추가 (`avg_monthly`도 유지 — 참고용 호환성)
  - `aps_sync_safety_from_sales`: `avg_monthly` → `avg_weekly`로 변경하여 `aps_items.safety_stock` 갱신
- **`aps.html` SalesTab 변경**:
  - 컬럼 헤더 "한달평균" → "주평균" (서브 라벨 "(안전재고 추천)" 유지)
  - 정렬 옵션 라벨 "한달평균 ↓" → "주평균 ↓" (sortKey 'avg' 그대로지만 비교 기준은 avg_weekly)
  - `merged` useMemo: `avgMonthly` → `avgWeekly`, shortage 계산 기준도 주평균
  - **클라이언트 폴백**: `Number(s.avg_weekly) || Number(s.avg_daily||0)*7` — Supabase RPC가 옛 정의(avg_weekly 미반환)여도 클라이언트가 일평균×7로 자동 계산 → SQL 재실행 전에도 UI 정상 표시. 단 `aps_sync_safety_from_sales` 실제 갱신은 서버측이라 SQL 재실행 필수
  - 헤더 부제목/사용법 안내/handleSyncSafety confirm 메시지 모두 "주평균"으로 통일
- **검증**: F0000045 (729박스/30일 가정) → 일평균 24.3 × 7 = **주평균 170.1박스**, 현재재고 146 → 부족 24.1 정확히 계산. 5개 행 모두 산식 일치
- **운영 순서**: 이미 SQL 적용한 사용자는 `setup_aps_sales.sql`의 `aps_get_sales_stats`/`aps_sync_safety_from_sales` 두 함수 블록만 다시 실행 → 서버측 통계 응답에도 avg_weekly가 포함되고 안전재고 갱신도 주평균 기준으로 동작

### APS — 매출 주평균을 "최근 4 ISO 주 단순 평균"으로 변경 (추세 반영) (2026-06-29)
- 직전 변경(ISO 주 그룹 평균)의 한계: 데이터가 누적될수록 모든 주를 동일 가중치로 평균 → 1년치(52주) 쌓이면 최근 주 1개가 평균에 1/52 비중밖에 영향 못 줌. 시즌·신메뉴·단종 등 추세 변동 반영 늦음
- 사용자 요청: "추세 반영 필요" → 선택지 중 **최근 4주 슬라이딩 윈도우** 선택
- 새 산식: `avg_weekly = AVG(week_qty) over last 4 ISO weeks` — 데이터 전체에서 가장 최근 4 ISO 주만 골라 단순 평균
  - 데이터 4주 미만이면 있는 만큼 평균 (예: 2주만 있으면 2주 평균)
  - 기간 필터(7/14/30/...)는 평균 산식과 분리됨 → total_qty/days_with_sales 등 표시용으로만 사용
  - 시즌·추세 변동을 빠르게 반영 (5주 전 데이터부터는 평균에 영향 X)
- **`setup_aps_sales.sql` 두 함수 수정**:
  - `aps_get_sales_stats`: CTE 3단(`all_weekly` → `ranked`(ROW_NUMBER OVER PARTITION BY code ORDER BY week_start DESC) → `recent4`(rn<=4)) + `period_stat`(기간 필터 집계, 표시용). 응답에 `recent_week_count` 추가 (평균에 실제 반영된 주 수)
  - `aps_sync_safety_from_sales`: 동일 CTE 패턴으로 최근 4주 평균을 `aps_items.safety_stock`에 반영. `p_days` 파라미터는 시그니처 유지하나 평균 산식에 영향 없음
- **`aps.html` SalesTab 변경**:
  - 클라이언트 폴백 4단계 분기: (1) `recent_week_count` 있으면 새 RPC → server avg_weekly 신뢰 (2) `week_count`만 있으면 직전 변경(전체 주 평균) RPC (3) `first_date`/`last_date` 추정 폴백 (4) 최후 일평균×7
  - 컬럼 헤더: "주평균 (안전재고 추천)" → "주평균 (최근 4주 · 안전재고 추천)"
  - 헤더 부제: "주평균 안전재고 자동 계산" → "최근 4주 평균을 안전재고로 자동 계산"
  - 사용법 텍스트 갱신: 산식 + 예시(최근 4주 [100,120,110,130] → 115) + 데이터 4주 미만 시 동작 + 기간 필터와 분리됨 안내
  - `handleSyncSafety` confirm + 동기화 버튼 title 모두 "최근 4주" 명시
- **검증**:
  - 1주차 120 → recent_week_count=1, avg_weekly=120 ✅
  - 1주차 100, 2주차 120, 3주차 110, 4주차 130 → recent_week_count=4, avg_weekly=115 ✅
  - 5주차 200 추가 → 최근 4주(2~5주차)=[120,110,130,200] → 평균 140 (1주차 100은 평균에서 빠짐) ✅
- **운영 순서**: Supabase에서 `setup_aps_sales.sql`의 `aps_get_sales_stats`/`aps_sync_safety_from_sales` 두 함수 블록 재실행 → 다음 매출 업로드부터 새 산식. 클라이언트 폴백으로 SQL 재실행 전에도 UI는 정상 표시되나 서버측 안전재고 동기화는 SQL 재실행 필수
- **한계**: 추세 반영이 빨라진 만큼 노이즈에도 민감해짐. 한 주 갑작스러운 급증이 다음 한 달간 안전재고에 영향. 너무 출렁이면 후속 단계에서 "최근 4주 가중평균"(가중치 1,2,3,4) 또는 "최근 N주 가변" 옵션 추가 가능

### APS — 매출 주평균 산식을 ISO 주(월~일) 단위 그룹 평균으로 변경 (2026-06-29)
- 사용자 보고: "매출 1주일치 120개만 올렸는데 7일평균이 28로 됨"
- 원인: 기존 산식 `avg_weekly = total / p_days * 7`은 분모가 "선택 기간 일수"(예: 30일) 고정 → 1주일치(120개)를 30일로 나눠서 4 × 7 = 28. 데이터 누적 전에는 무조건 과소평가
- 추가 컨텍스트: "특정 요일에 발주 몰림" → 단순 일평균 산식은 의미 없음. 한 주에 평균 몇 박스 나가는지가 필요
- 새 산식: `avg_weekly = SUM(qty) / COUNT(DISTINCT DATE_TRUNC('week', date))` — ISO 주(월~일) 단위로 그룹핑 후 주별 합계의 평균
  - 1주차에 120박스(한 주만 데이터) → 120 / 1주 = 120
  - 1주차 120 + 2주차 130 → 250 / 2주 = 125
  - 한 주 안에 휴무·결근으로 5일치만 있어도 그 주는 한 주로 카운트 (다음 주 데이터로 8일 채우지 않음)
  - 요일별 발주 편향은 주 단위로 묶이며 자연스럽게 흡수됨
- **`setup_aps_sales.sql` 두 함수 수정**:
  - `aps_get_sales_stats`: 응답에 `week_count` 추가, `avg_weekly = total / week_count`로 계산. `avg_daily`/`avg_monthly`는 `avg_weekly`에서 파생(/7, ×30/7) — 참고용
  - `aps_sync_safety_from_sales`: stats CTE의 산식을 동일하게 ISO 주 평균으로 변경
- **`aps.html` SalesTab 변경**:
  - 클라이언트 폴백 산식 3단계 분기: (1) `week_count` 있으면 server의 `avg_weekly` 그대로 (2) 옛 RPC(week_count 없음)이면 `first_date~last_date` 범위로 `ceil(spanDays/7)` 주 수 추정해서 `total / weeks` 재계산 → SQL 재실행 전에도 UI에 정확한 주평균 표시 (3) 둘 다 없으면 최후 `avg_daily × 7`
  - 사용법 텍스트 갱신: "ISO 주(월~일) 단위로 묶고 주별 합계의 평균" 명시 + 예시(120 → 120, 120+130 → 125) + 한 주에 일부 날짜만 있어도 한 주로 카운트 안내
  - `handleSyncSafety` confirm + 동기화 버튼 title 메시지도 새 산식 설명으로 갱신
- **검증**:
  - 1주차 120박스만 업로드, 기간 30일 → 옛 산식 `120/30*7 = 28`, 새 산식 `120/1 = 120` ✅
  - 2주차 130 추가, 기간 30일 → 새 산식 `250/2 = 125` ✅
- **운영 순서**: Supabase에서 `setup_aps_sales.sql`의 `aps_get_sales_stats`/`aps_sync_safety_from_sales` 두 함수 블록 재실행 → 다음 매출 업로드부터 새 산식. SQL 재실행 전에도 클라이언트 폴백으로 정확한 주평균 표시되나, 서버측 안전재고 동기화는 SQL 재실행 후에야 새 값으로 갱신됨

### APS — 생산계획 탭 재고 패널에 안전재고 동시 표시 (2026-06-29)
- 사용자 요청: "생산계획탭에 재고on하면 재고랑 같이 안전재고도 뜨도록"
- 기존: `InventoryQuickPanel`이 재고시트(`aps-inv-data`) 박스 수(current)만 표시 → 발주 우선순위 판단 어려움
- 변경: `aps_items.safety_stock`(매출 주평균 자동 동기화 값)을 코드 매칭으로 함께 표시
- **`InventoryQuickPanel` 변경** ([aps.html:1165](aps.html:1165)):
  - props에 `items` 추가 (PlansTab의 `aps_list_items` 결과 그대로 전달)
  - `safetyMap` useMemo: `items[].code → safety_stock` 매핑
  - 제품 테이블에 헤더 행 추가(품목/현재/안전) + 4번째 컬럼 `td.safety` 추가
  - 안전재고 미설정 품목은 "–" 회색 표시 (`td.safety.none`)
  - **시각 강조**: 현재 < 안전이면 박스 수가 주황(`#f59e0b`, `td.qty.low`), 0이면 빨강 그대로
  - "+ 마스터 외" 섹션 행에도 동일 매칭 적용
  - 품목명 셀 max-width 155→110px로 축소해 안전 컬럼 자리 확보
- **CSS 추가** ([aps.html:113-122](aps.html:113)): `td.qty.low`(주황), `td.safety`(11px→10px 작게, muted), `td.safety.none`(dimmer), `tr.head td`(9px 회색 헤더)
- 별도 SQL 변경 없음 (기존 `aps_list_items`/`aps_get_settings` 그대로 사용)

### APS — 인원 관리 탭 + 일일 가용 인원 PNG 저장 (2026-06-29)
- 사용자 요청: "엑셀로 4층 생산 가용 인원표(부서별 체크박스 + N명) 관리하던 걸 시스템에 도입. 스케줄 이미지 저장할 때 같은 양식으로 가용 인원 PNG도 저장하고 싶다"
- 결정 사항: 직원 마스터(부서/이름/역할/메모) + 날짜별 휴무 기록(default=출근, 휴무자만 row) + 사진과 동일 양식 PNG export
- **`setup_aps_staff.sql`** (신규, 1회 실행):
  - `aps_staff(id, department, name, role, memo, active, sort_order, created_at, updated_at)` — 직원 마스터
  - `aps_attendance(date, staff_id, status, memo)` PK(date, staff_id), FK ON DELETE CASCADE — **휴무자만 row 저장** (출근 = row 없음 = default)
  - 트리거 `aps_staff_assign_sort_order`: INSERT 시 같은 부서 내 MAX(sort_order)+1 자동 부여
  - RLS ENABLE + 정책 없음 → REST 직접 접근 차단, SECURITY DEFINER RPC로만 접근
  - RPC 7종 (모두 `aps_assert_admin` 첫 줄 검증): `aps_list_staff(only_active)`, `aps_upsert_staff`, `aps_delete_staff`, `aps_move_staff_order(up/down)`, `aps_get_attendance(date)`, `aps_set_attendance(date, staff_id, status, memo)` — status='work'/null이면 row 삭제·그 외는 upsert, `aps_get_attendance_range(start, end)` — 캘린더 뷰용 (현재 미사용, 추후 확장)
- **`aps.html` 변경**:
  - 신규 4번째 탭 **👥 인원** (VALID_TABS에 "staff" 추가, 📅 생산계획 ↔ 📊 재고 사이에 배치)
  - `loadStaffTitle()`/`saveStaffTitle()`: PNG 헤더 제목을 localStorage(`aps-staff-title`)에 저장 (기본값 "생산 가용 인원 및 생산 계획")
  - **`StaffForm`**: 직원 추가/수정 모달 — 부서 input + datalist 자동완성(기존 부서 추출), 이름(필수), 역할, 메모, 활성 체크박스
  - **`ExportStaffView`** (오프스크린 PNG 전용): 사진과 동일 레이아웃 — 880px 폭, 라이트 톤 고정(흰 배경 + 진한 검정 테두리·헤더), 부서별 박스 그리드(최대 7열) + 검은 헤더(부서명) + 명단(✓ 체크박스 + 이름, 휴무자 취소선) + 회색 푸터(N 명), 우측 하단 "총 인원: N명" 시안색 강조
  - **`StaffTab`** 메인 컴포넌트: 2가지 mode(daily/master)
    - state: `staff`, `offIds(Set<staff_id>)`, `dateStr`, `title`, `editing`, `showForm`, `capturing`
    - `loadStaff()` + `loadAttendance(date)` 자동 호출
    - `toggleAtt(s)`: 체크박스 클릭 → 낙관적 업데이트 후 `aps_set_attendance` RPC, 실패 시 롤백
    - `exportPng()`: 오프스크린 div 마운트 → html2canvas(scale:2, bg:#fff) → PNG 다운로드(`가용인원_YYYY-MM-DD.png`)
    - daily 뷰: 제목 input + 날짜 navigator(이전/오늘/다음 + date picker) + 📷 이미지 저장 + 부서별 그리드 + 하단 summary
    - master 뷰: 부서별 그룹화된 직원 테이블(▲▼ 정렬, 수정·삭제) + + 직원 추가
    - 체크박스 default checked(=출근), 클릭 시 휴무 토글. PNG에는 출근자만 체크 표시(휴무자는 회색 취소선)
  - **CSS** `aps.html` 내부 `<style>`에 추가: `.aps-staff-grid`(auto-fit minmax(160px,1fr)), `.aps-staff-card`(2px solid var(--text) 테두리), `.aps-staff-card-hdr`(var(--text) 배경·var(--bg) 글자로 명도 반전 → 다크/라이트 모드 자동 대응), `.aps-staff-row.off .nm`(취소선), 모바일(<700px) 그리드·폰트 축소
- **운영 순서**: (1) Supabase SQL Editor에서 `setup_aps_staff.sql` 실행 → (2) 👥 인원 탭 → 직원 마스터 모드 → 명단 등록 → (3) 일일 가용 모드에서 휴무자 체크박스 클릭 → (4) 📷 이미지 저장 → 사진 양식 PNG 다운로드
- **한계**: 캘린더 월간 뷰는 미구현(`aps_get_attendance_range` RPC는 만들어 둠 — 향후 확장). 휴무 상태는 단일 'off'만 사용(연차/병가/출장 분리 미사용 — RPC는 지원)

### APS — 인원 + 생산계획 통합 PNG 저장 (2026-07-03)
- 사용자 요청: "생산계획 이미지랑 인원 이미지랑 합쳐서 같이 다운받고 싶다. 같은날짜로 한눈에 보이게"
- 기존: 👥 인원 탭에서는 `ExportStaffView`만, 📅 생산계획 탭에서는 `ExportPlansView`만 각각 별도 PNG 저장 → 두 이미지를 오프라인에서 합성해야 했음
- 변경: **두 탭 모두**에 `📷 인원+계획` 신규 버튼 추가 (사용자가 어느 탭에서 작업 중이든 접근 가능하도록)
  - 👥 인원 탭 일일 가용 모드: 헤더 오른쪽 `📷 이미지 저장` 옆
  - 📅 생산계획 탭 툴바: `📷 이미지 저장` 옆 (allDates=true면 disabled — 통합 이미지는 단일 날짜 전용)
- 현재 선택된 날짜의 가용 인원 + 그 날짜와 겹치는 생산계획을 한 PNG로 저장 → `가용인원_생산계획_YYYY-MM-DD.png`
- **`ExportPlansView`**: `width` prop 추가 (default 820) → 통합 뷰에서는 880으로 전달해 인원 뷰와 폭 통일
- **신규 `ExportCombinedView`** ([aps.html:4674](aps.html:4674)): 880px 폭 컨테이너에 `ExportStaffView` + dashed divider + `ExportPlansView`를 세로 스택 (재사용 컴포넌트, 코드 중복 없음)
- **`StaffTab`**: `combinedCapturing`/`combinedPlans`/`combinedLines` state + `combinedExportRef` + `exportCombined()` 핸들러 → `aps_list_plans`+`aps_list_lines` fetch, 인라인 KST 00:00~24:00 overlap 필터
- **`PlansTab`**: `combinedCapturing`/`combinedStaff`/`combinedOffIds` state + `combinedExportRef` + `exportCombinedFromPlans()` 핸들러 → `aps_list_staff`+`aps_get_attendance` fetch, 오프스크린 렌더 시 인라인 IIFE로 deptGroups/totalAvail 계산 (`title`은 `loadStaffTitle()`로 인원 탭과 동일)
- 한계: 계획 0건인 날짜에도 저장 가능 (플레이스홀더 "표시할 생산계획이 없습니다")

### APS — 인원+계획 통합 PNG에 사용 원육 정보 추가 (2026-07-08)
- 기존: `ExportCombinedView`가 내부 `ExportPlansView`에 `matsByPlan={}` 하드코딩 전달 → 통합 이미지에는 🥩 원육 라인이 안 뜸 (사용자 보고 "인원+계획 이미지에는 사용원육이 안떠")
- 원인: 2026-07-03 초기 구현에서 MVP 범위로 원육 상세를 제외 → 별도 생산계획 PNG에는 표시되는데 통합 PNG에서는 누락
- 변경:
  - **`buildExportMaterialsFor(adminHash, planList, items, invData)`** 최상단 헬퍼 신설 ([aps.html:543](aps.html:543)) — 기존 `PlansTab` 내부 `buildExportMaterials` arrow function을 top-level로 승격
  - `ExportCombinedView`에 `matsByPlan` prop 추가 → 내부 `ExportPlansView`에 그대로 전달 (기존 `{}` 하드코딩 제거)
  - `PlansTab.exportCombinedFromPlans`: `buildExportMaterialsFor(adminHash, listFiltered, items, invData)` 호출 → `combinedMats` state 세팅 → `ExportCombinedView`에 전달
  - `StaffTab.exportCombined`: 기존 계획/라인 fetch에 `aps_list_items` 추가, 재고시트는 `loadStoredInventory()` + `loadRemoteInventory(adminHash)` 병행하여 `_invRemoteIsNewer` 비교로 신선한 쪽 선택 → `buildExportMaterialsFor` 호출 → `combinedMats`
  - `PlansTab.exportCurrentView`도 top-level 헬퍼로 마이그레이션 (기존 inner 함수 제거) — 3개 export 경로가 동일 헬퍼 공유
- 효과: `가용인원_생산계획_YYYY-MM-DD.png` 파일에 각 계획 아래 `🥩 [원자재명] — [원육명1 kg1] · [원육명2 kg2] · ...` 인라인 라인이 나타남 (별도 생산계획 PNG와 동일 포맷)

### APS v7 — 원자재 매칭 키워드 + 생산계획 필요 원육 실시간 표시 (2026-07-01)
- 사용자 요청: "생산계획 잡을 때 그 제품에 필요한 원육이 얼마나 남았는지 뜨도록 + 재고시트 원육이랑 BOM 원자재 자동 연동"
- 배경: 재고시트 원육 이름은 브랜드/공장코드 포함(예: `냉동우육 삼겹양지 SWIFT 3D`)이라 매번 바뀌지만, BOM에서는 일반 부위명(`삼겹양지`)만 쓰고 싶음. 원산지 구분도 필요(`삼겹양지(미국)` vs `삼겹양지(호주)`)
- 해결: 원자재마다 **매칭 키워드 배열**을 등록 → 재고시트 원육 이름에 키워드가 포함되면 그 원자재의 재고로 자동 합산. 원산지는 원자재 이름에 명시하는 것으로 통일
- **`setup_aps_v7.sql`** (신규, 1회 실행, v6까지 실행 전제):
  - `aps_items.match_keywords JSONB NOT NULL DEFAULT '[]'::jsonb` 컬럼 추가 (IF NOT EXISTS)
  - `aps_list_items` 응답에 `match_keywords` 필드 추가
  - `aps_upsert_item` 시그니처 확장: 11번째 파라미터 `p_match_keywords JSONB DEFAULT '[]'::jsonb`. `p_type='material'`이 아니면 무시하고 `[]` 저장 (제품/반제품은 재고시트 매칭 불필요)
  - 시그니처 변경이므로 `DROP FUNCTION IF EXISTS aps_upsert_item(10인자)` + 신규 11인자 정의 → 클라이언트는 항상 `p_match_keywords` 전송해야 함
- **매칭 규칙**:
  - 키워드 하나 = 공백 구분 여러 토큰의 AND 매칭. 예: `삼겹양지 SWIFT` → 원육 이름에 "삼겹양지" **와** "SWIFT" 둘 다 포함되어야 매칭
  - 배열 여러 키워드는 OR: `["삼겹양지 SWIFT", "삼겹양지 CARGILL"]` → 둘 중 하나라도 매칭되면 그 원자재 재고로 합산
  - 대소문자 무관 (프론트에서 `toLowerCase()` 후 비교)
  - 한 원육은 하나의 원자재에만 귀속(중복 계산 방지). 원자재 등록 순서상 앞선 것이 우선(만약 우선순위가 문제되면 후속 단계에서 명시적 priority 필드 추가 가능)
- **`aps.html` 신규 헬퍼**:
  - `parseMatchKeywords(raw)`: JSONB(문자열/배열) → 트림된 문자열 배열
  - `nameMatchesKeyword(rawNameLower, keyword)`: 공백-AND 매칭 판정
  - `matchRawsToMaterials(raws, materialItems)`: 재고시트 raws + 원자재 목록 → `{materialId:{item,totalKg,matches:[{rawName,kg,keyword}]}}`
  - `calcMaterialRequirements(itemId, plannedQty, bomByParent, itemById)`: BOM 재귀 조회 → 원자재별 필요 kg. 반제품이 자식이면 그 반제품의 BOM도 재귀. loss_rate 자동 반영 (`qty × (1 + loss_rate/100) × plannedQty`)
- **`ItemForm` 변경**: `type==="material"`일 때만 매칭 키워드 UI 노출
  - 태그 스타일 입력: 텍스트 입력 후 Enter/콤마/`+ 추가` 버튼 → 태그 추가. 태그 X 버튼으로 삭제. 중복 키워드 자동 제거(대소문자 무관)
  - 안내 텍스트에 AND/OR/대소문자 규칙 명시. 시안색 강조 박스로 원자재 전용임을 시각적으로 구분
  - 저장 시 `type!=="material"`이면 `p_match_keywords: []` 강제 (서버에서도 재검증)
- **`PlanForm` 변경**: 품목 + 수량이 입력되면 하단에 원자재 소요/재고 카드 자동 표시
  - 재고시트 데이터 로드: 마운트 시 `loadStoredInventory()` + `loadRemoteInventory(adminHash)` 병행 (PC/모바일 동기화). `aps-inv-data-change` + `storage` 이벤트 구독으로 실시간 갱신
  - BOM 로드: `itemId` 변경 시 `aps_list_bom` 재귀 호출(반제품 자식이 있으면 그 반제품 BOM까지) → `bomByParent` 캐시
  - `materialReport` useMemo: `calcMaterialRequirements` + `matchRawsToMaterials` 조합 → 원자재별 `{needKg, stockKg, matches, ok, hasKeywords}` 리스트 계산
  - 카드 UI: 원자재마다 별도 박스 (배경/테두리 색으로 상태 표시 — 초록:충분 / 빨강:부족 / 회색:키워드 미설정) + 필요 kg / 재고 kg 병기 + ✓ 충분 (+여유 kg) 또는 ⚠ 부족 (-shortage kg) 뱃지 + 매칭 원육 상세는 `<details>`로 접기 (원육명 × N건 + 각 kg)
  - 재고시트 비어있으면 안내 문구, BOM 원자재 없으면 안내 문구 (graceful degradation)
- **동작 예시**:
  - 원자재 등록: `삼겹양지(미국)` + 키워드 `["삼겹양지 SWIFT", "삼겹양지 CARGILL"]`
  - `돌돌우삼겹` 제품 BOM에 `삼겹양지(미국)` 자식 등록 (qty=0.5kg/박스, loss_rate=2%)
  - 생산계획 추가 시 `돌돌우삼겹` 선택 + 수량 100 입력 → 카드에 "삼겹양지(미국) 필요 51kg / 재고 200kg ✓ 충분 (+149kg 여유)" 표시
  - 매칭 원육 상세: `냉동우육 삼겹양지 SWIFT 3D 100kg`, `냉동우육 삼겹양지 SWIFT 969 100kg`
- **운영 순서**: (1) Supabase에서 `setup_aps_v7.sql` 실행 → (2) 📦 품목/BOM 탭에서 원자재 편집 → 매칭 키워드 등록 → (3) 제품 BOM에 원자재 연결 → (4) 📅 생산계획 추가 시 자동 표시
- **한계**: 원자재끼리 키워드가 겹치면 원자재 등록 순서(id 오름차순)로 우선. 원산지가 다른 원자재는 이름 + 키워드로 명확히 분리하도록 유도(예: SWIFT는 미국, TEYS는 호주 등 브랜드 코드가 원산지 판별의 핵심)

### APS — 생산계획 PNG 저장에 사용 원육 정보 추가 (2026-07-01)
- 사용자 요청: "계획을 이미지로 저장했을 때 어떤 원육을 사용하는지도 나오면 좋겠어"
- 기존: `ExportPlansView` PNG는 라인별 리스트만 표시(품목/수량/시간/상태). BOM에 연결된 원자재나 매칭된 재고시트 원육 정보는 누락
- 변경: 각 plan 행 아래에 별도 카드 형태로 사용 원자재 + 매칭 원육 상세 표시
- **`PlansTab` 변경**:
  - `invData` state 추가 (재고시트 데이터, 마운트 시 remote fetch + `aps-inv-data-change`/`storage` 이벤트 구독)
  - `exportMats` state 추가: `{planId: [{name, code, needKg, stockKg, matches, ok, hasKeywords}]}` — PNG 저장 직전 계산되는 원자재 요약
  - `buildExportMaterials(planList)` 헬퍼: listFiltered의 unique item_id를 순회하며 `aps_list_bom` 재귀 fetch → `calcMaterialRequirements` + `matchRawsToMaterials`로 plan별 원자재 리스트 계산
  - `exportCurrentView` 흐름 변경: (1) `buildExportMaterials` 호출 → `setExportMats` (2) 오프스크린 렌더 대기 (3) html2canvas 캡처 (4) 다운로드 완료 후 `setExportMats({})` 초기화
  - 캡처 실패 시에도 `setExportMats({})` 정리 (stale state 방지)
- **`ExportPlansView` 변경**:
  - props에 `matsByPlan` 추가
  - **간소화**(2026-07-01 사용자 피드백): 초기 구현은 별도 카드(`🥩 사용 원육` 라벨 + 필요/재고 kg + ✓/⚠ 뱃지)를 각 plan 다음 `<tr>`에 삽입 → "너무 크다" 지적 → **품목명 바로 아래 컴팩트 한 줄**로 인라인 표시로 변경
  - 최종 포맷: `🥩 [원자재명] — [원육명1 kg1] · [원육명2 kg2] · ...`
  - 예시: `🥩 차돌박이(미국) — 냉동우육 차돌백이 EXCEL 86E 190g · 냉동우육 차돌백이 EXCEL 86M 179.95kg`
  - `mats.length===0`이면 아무것도 표시 안 함 (BOM 미연결 계획은 원본 그대로)
  - "필요 kg" / "재고 kg" 라벨 완전 삭제 — 우측 수량 컬럼에 이미 총 kg(`qty×spec`)이 있어서 중복이었음
  - 부족 시에만 `⚠ 부족` 라벨 추가 (충분·정상은 무표시)
  - 원자재 여러 개면 각각 한 줄씩 (`<div>` 반복)
- **동작 예시**: `(마벨리에)돌돌차돌 1kg*4` 10박스 계획 → PNG 품목명 아래에 `🥩 차돌박이(미국) — 냉동우육 차돌백이 EXCEL 86E 190g · 냉동우육 차돌백이 EXCEL 86M 179.95kg` 표시 (재고 충분 시 부족 라벨 없음)
- **한계**: 오프스크린 렌더 시점에 BOM RPC를 계획 수만큼 fetch → 계획 20~50건 규모에서는 즉시 완료. 100건 이상이면 저장 버튼 클릭 후 2~3초 지연 가능. 매칭 원육이 매우 많으면 (5건+) 한 줄이 길어져 자동 wrap

### APS v8 — 원자재 안전재고 BOM 자동 계산 + 재고시트 표시 (2026-07-02)
- 사용자 요청: "원육(원자재) 안전재고는 BOM설정되면 그 연동된 제품들의 안전재고 × 규격 합산 해주면 될것같아. 삼겹양지(미국)을 슬라이스(안전재고 24)/돌돌우삼겹(안전재고 32)이 쓴다면 계산 자동화. 재고시트 이미지에 뜨게하고 안전재고보다 50% 밑이면 빨강, 매칭 원육이 재고시트에 없으면 '차돌박이(미국) 재고부족' 안내"
- 확정 계산법: `원자재 필요 안전재고 = Σ(직접 부모의 safety_stock × BOM.qty × (1 + loss_rate/100))` — 사용자 명확화 답변으로 "BOM에 등록된 원자재 소요량 사용" + "직접 연결된 부모만 (1단계, 반제품 재귀 X)"
- **`setup_aps_v8.sql`** (신규, 1회 실행, v7까지 실행 전제):
  - **`aps_get_material_requirements(p_admin_hash)` RPC 신규**: 원자재별 필요 kg 서버측 SQL 집계 — `aps_items c LEFT JOIN aps_bom b ON b.child_id=c.id LEFT JOIN aps_items p ON p.id=b.parent_id AND p.type IN ('product','semi') WHERE c.type='material' GROUP BY c.id`
  - 응답 필드: `material_id, code, name, required_kg, source_count, sources[{parent_id, parent_code, parent_name, parent_type, parent_safety_stock, qty, loss_rate, contrib_kg}]`
  - 부모가 원자재(material)인 경우 무시 (재귀 없음). required_kg=0인 원자재도 리스트에 포함(부모 없어서) — 클라이언트에서 필터
- **`aps.html` `InventorySheetTab` 변경**:
  - state 추가: `items`, `matReqs({material_id:{code,name,required_kg,...}})`
  - 마운트 시 `aps_list_items` + `aps_get_material_requirements` 병행 fetch → `matReqs` 맵 구성. RPC 실패 시 빈 배열 fallback (구버전 SQL 서버 호환)
  - `materialStatus` useMemo: 원자재 × 재고시트 매칭 결과와 필요치 결합 → `{id, code, name, requiredKg, stockKg, ratio, status, matches, hasKeywords, sources}` 리스트. `stockKg<=0=empty`, `ratio<0.5=critical`, `<1.0=low`, `>=1.0=ok`. required_kg=0인 원자재 제외
  - `shortageList = materialStatus.filter(status in ['empty','critical'])` — 하단 알림 배너 노출
  - **원육 테이블 행 강조**: `rawStatus{name.toLowerCase():status}` 역매핑 → 각 원육 행에 매칭 원자재의 status가 critical이면 `raw-crit`(옅은 빨강 배경), empty면 `raw-empty`(진한 빨강)
  - **재고시트 body 아래 신규 섹션 "🥩 BOM 기준 원자재 재고 현황"**:
    - 부족 알림 배너 (shortageList 존재 시): "**{원자재명}** 재고 없음/재고 부족 · 필요 XXkg / 재고 YYkg (부족 ZZkg) · 매칭 키워드 미설정" — 예: `차돌박이(미국) 재고 없음`
    - 전체 표: 원자재 | 필요 (BOM) | 재고 (시트) | 비율 (%) — 상태별 배경색 4단(empty 진한 빨강, critical 빨강, low 주황, ok 초록)
    - 매칭 키워드 없는 원자재는 "키워드 미설정" 인라인 뱃지 (빨강)
  - **PNG 저장 시 자동 포함**: `sheetRef` 안에 렌더링되므로 📷 이미지 다운로드 결과 이미지 하단에 함께 저장됨. 라이트 톤(#111 텍스트, 흰/파스텔 배경)으로 사진 형식 스타일과 일관
- **CSS 추가** ([aps.html:160](aps.html:160)):
  - `.inv-tbl .raw-crit td`(옅은 빨강 배경 + 진한 빨강 텍스트), `.raw-empty td`(진한 빨강 배경)
  - `.inv-mat-section`(상단 dashed 구분선), `.inv-mat-title`(가운데 정렬 14px 700), `.inv-mat-alerts`(세로 배열), `.inv-mat-alert.empty/critical`(좌측 컬러 border-left 4px)
  - `.inv-mat-tbl`(max-width 520px 중앙 정렬), row status별 배경색 4단(empty/critical/low/ok)
  - `.inv-mat-nokw`(빨강 10px "키워드 미설정" 뱃지)
- **운영 순서**: (1) Supabase에서 `setup_aps_v8.sql` 실행 → (2) 📦 품목/BOM 탭에서 제품 안전재고 + 원자재 BOM 등록 + 원자재 매칭 키워드 등록 → (3) 📋 재고 시트 탭에서 원육 엑셀 업로드 → (4) 자동으로 재고시트 하단에 원자재 재고 현황 표시, 부족 시 빨강 강조, 📷 이미지 다운로드 시 함께 저장됨
- **한계**: (1) 반제품이 원자재를 쓰는 경우 반제품 자체의 안전재고만 사용 (완제품 재귀 X — 사용자가 명시적으로 1단계 선택). (2) 원자재에 매칭 키워드 미설정이면 재고시트 원육이 있어도 재고 0으로 계산 → "키워드 미설정" 뱃지로 원인 표시. (3) 원육 하나가 여러 원자재에 매칭 가능한 경우 첫 매칭 원자재에만 귀속(기존 `matchRawsToMaterials` 규칙)

### APS — 통계 탭 인라인 수정 (실제 시각 + 실제 수량) (2026-06-30)
- 사용자 요청: "통계탭은 시간하고 중량을 수정할수있도록 가능할까?" — 잘못 기록된 실제 시작/종료 시각을 통계 탭에서 바로 고치고, "40박스 계획 → 실제 35박스 생산" 같은 케이스를 위해 실제 생산 수량을 따로 입력
- 기존 한계: 통계 탭은 `aps_get_item_stats` 집계만 읽는 read-only 뷰. 실제 시각 보정은 ▶/✓ 버튼 재클릭으로만 가능했고, 실제 수량 개념 자체가 없었음(계획 qty만)
- **`setup_aps_v6.sql`** (신규, 1회 실행):
  - `aps_plans.actual_qty NUMERIC NULL` 컬럼 추가 — NULL=계획 qty 그대로 사용, 숫자=실제 생산량
  - `aps_list_plans` v5+actual_qty로 재정의 (응답에 `actual_qty` 추가)
  - `aps_get_item_stats` 재정의: total_qty/avg_qty/qty_per_hour 모두 `COALESCE(actual_qty, qty)` 사용 → 실제 수량이 있으면 그것을, 없으면 계획 qty를 집계 (구버전 데이터 호환)
  - **`aps_get_done_plans_for_item(p_admin_hash, p_item_id, p_days_back)`** 신규 RPC: 통계 탭 드릴다운용 — 특정 품목의 완료 plan 목록을 통계와 같은 기간 필터로 반환
  - **`aps_update_plan_actuals(p_admin_hash, p_id, p_actual_start_at, p_actual_end_at, p_actual_qty)`** 신규 RPC: status='done' 행에만 적용, end>start 검증, actual_qty 음수 거부. NULL 보내면 actual_qty 리셋(계획값 사용)
- **`aps.html` 변경**:
  - 신규 컴포넌트 **`StatsDrilldownTable`**: 미니 테이블로 #id / 라인 / 실제 시작 / 실제 종료 / 실제 시간 / 계획 수량 / 실제 수량 / 동작(✏ 수정) 표시. 편집 모드는 datetime-local + number input으로 인라인 교체. 실제 수량이 계획 수량과 다르면 계획 수량에 취소선 + 실제 수량을 시안색으로 강조
  - **`StatsTab`** 확장:
    - state 추가: `expanded`(현재 펼친 item_id, 단일), `itemPlans`({item_id:[plans]} 캐시), `editingId`, `editForm`, `saving`
    - 품목 행 클릭 → `toggleExpand(item)`: 펼침/접기. 최초 펼침 시 `loadItemPlans` lazy fetch. ▶ 회전 애니메이션으로 펼침 상태 표시
    - `range` 변경 시 `itemPlans` 캐시 invalidate + 펼침/편집 상태 리셋 (기간 필터가 드릴다운에도 반영되도록)
    - `startEdit`/`cancelEdit`/`saveEdit`: 인라인 편집 흐름. saveEdit 성공 시 드릴다운 + 상위 통계 둘 다 재로드
    - 빈 string으로 비우면 actual_qty=NULL로 RPC 전달 → 계획 qty 사용 의미로 복귀
  - 안내 텍스트 갱신: "잘못 기록된 시각·실제 수량은 품목 행을 클릭해 펼친 뒤 ✏ 버튼으로 직접 수정 가능 · 실제 수량을 비워두면 계획 수량 그대로 통계 반영"
- **운영 순서**: Supabase에서 `setup_aps_v6.sql` 실행 1회 → 📈 통계 탭에서 품목 행 클릭 → 펼친 plan 목록에서 ✏ 수정 → 저장 시 통계 즉시 갱신
- **한계**: 진행중(`in_progress`) plan은 수정 불가 (▶/✓ 버튼 흐름으로만 처리, RPC가 `only_done_editable` 거부). 일괄 편집·취소된 plan 복구 미지원

### APS — 생산계획 라인별 색상 (2026-07-03)
- 사용자 요청: "생산계획 라인별로 색상을 다르게 할수있을까"
- 기존: 간트/시간표 막대는 status(planned/in_progress/done/canceled) 색상, 리스트 라인 그룹 헤더는 고정 시안색 → 라인이 여러 개일 때 라인별 구분이 시각적으로 안 됨
- 변경: 라인별 12색 팔레트 도입, 라인 code 오름차순 인덱스 기반 deterministic 배정 → 4개 뷰(간트·시간표·리스트·PNG) 모두 동일 색상 적용
- **`LINE_PALETTE`** ([aps.html:563](aps.html:563)): 12색(blue/emerald/amber/violet/pink/cyan/orange/lime/rose/indigo/teal/fuchsia) × 5필드(`base`, `bg`(alpha), `bgLight`, `fgLight`, `bdLight`) — 다크 모드용 rgba + 라이트 모드(PNG export)용 파스텔·진한색 페어
- **`LINE_UNASSIGNED`**: 라인 미지정용 slate 뉴트럴
- **`lineColorFor(lineId, lines)`**: `lines`를 `code` 오름차순 정렬한 뒤 index mod 12 → 팔레트 매핑. 라인 삭제·추가 시 다른 라인 색상도 변할 수 있으나(정렬 인덱스 기반) code가 유지되면 순서 안정. lineId 없으면 UNASSIGNED
- **간트 뷰**:
  - 좌측 라인 라벨 컬럼에 6px 두께 좌측 컬러 보더
  - 막대 배경/테두리/텍스트 색상 → 라인 색상 (기존 status 색상 대체)
  - status는 opacity로 표현: canceled 0.45 + line-through, done 0.72 + ✓ 아이콘, in_progress 1.0 + ▶ 아이콘, planned 0.9 + dashed border
- **시간표 뷰**:
  - 헤더에 4px 컬러 상단 보더
  - 셀 배경 라인 색상, anchor 셀은 2px 상단 solid, 연속 셀은 dashed. status opacity(canceled 0.45 / done 0.75) + canceled 셀 품목명 line-through
  - 우측 status 라벨은 기존 STATUS_PILL 색상 유지 (라인 색상과 status 정보 병존)
- **리스트 뷰**: 라인 그룹 헤더 배경/좌측 4px 보더/텍스트 색상 → 라인 색상. 각 행에도 좌측 4px 컬러 보더로 라인 소속 시각화
- **PNG export (`ExportPlansView`)**: 그룹 카드 좌측 5px 보더 + 헤더 배경(bgLight)/헤더 텍스트(fgLight) → 라인 색상 라이트 톤 (인쇄 친화)
- 색상 배정은 랜덤이 아닌 code 알파벳순 → 사용자가 같은 라인은 항상 같은 색으로 인식 가능 (단, 라인 code 추가/변경으로 정렬 위치가 바뀌면 색도 이동)

### APS — 회의록 탭 + PNG export (2026-07-02)
- 사용자 요청: "회의록 탭 만들어서 관리하고싶은데 가능할까? 회의록을 깔끔하게 정리해서 이미지로 공유"
- 확정 사양: 구조화(안건/결정사항/액션아이템 3섹션) + 참석자 자유텍스트 + 액션 체크박스(완료 표시)
- **`setup_aps_meetings.sql`** (신규, 1회 실행): 테이블 2개 + 트리거 1개 + RPC 7개
  - `aps_meetings` (id, meeting_at TIMESTAMPTZ, title, attendees, author, memo)
  - `aps_meeting_items` (id, meeting_id FK CASCADE, kind CHECK IN ('agenda','decision','action'), content, assignee, due_date, done, sort_order)
  - 트리거 `aps_meeting_items_assign_sort_order`: 같은 (meeting_id, kind) 그룹 내 MAX(sort_order)+1 자동 부여
  - RLS ENABLE + 정책 없음 → RPC만 허용
  - RPC: `aps_list_meetings`(days/search 필터 + item_count + open_actions 카운트), `aps_get_meeting`(헤더+items JSON 묶음), `aps_upsert_meeting`, `aps_delete_meeting`, `aps_upsert_meeting_item`, `aps_delete_meeting_item`, `aps_toggle_meeting_item_done`(빠른 완료 토글)
- **`aps.html` 변경**:
  - `VALID_TABS`에 "meetings" 추가 → URL 해시 동기화 동작 (`aps.html#meetings`)
  - 신규 9번째 탭 **📝 회의록** (💰 매출 오른쪽)
  - `MTG_KINDS` 상수: 안건(📋 보라)/결정사항(✅ 초록)/액션(🚀 주황) 3섹션 + 색상 스킴
  - `fmtMtgWhen`/`fmtMtgWhenShort`: KST 요일 포함 시각 포맷팅
  - **`MeetingsTab`** — 2컬럼 레이아웃 (좌 340px 목록 sticky panel + 우 상세 flex). 모바일(≤900px)은 세로 스택
    - 목록: 제목·작성자·참석자·메모 ILIKE 검색 + 기간 필터(30/90/180/365/전체) + item_count·open_actions 뱃지
    - 상세: 헤더(제목·일시·참석자·작성자·개요) + 3섹션 각각 항목 리스트 + 인라인 add form(Ctrl+Enter로 빠른 추가) + ✏수정/🗑삭제
    - 액션아이템만 체크박스(낙관적 업데이트 후 RPC), 담당자·기한 필드 노출. 기한 지난 미완료는 빨강 ⚠지연 표시
    - 목록 로드 후 첫 회의 자동 선택
  - **`MeetingForm`** 중앙 모달: 제목/일시(datetime-local, 기본값 현재 KST 시각)/작성자/참석자(textarea)/개요 메모
  - **`MeetingItemRow`** + **`MeetingItemEditor`** + **`MeetingItemAdd`**: 인라인 CRUD, 액션만 담당자·date input 추가 렌더
  - **`ExportMeetingView`** — PNG용 오프스크린 라이트 톤 리포트(820px, Pretendard, "MEETING MINUTES" 헤더 + 굵은 하단선 + 참석자 카드 + 3섹션 좌측 컬러 보더 + 번호 매김 + STOCKPULSE·APS 푸터). done 항목은 취소선 + opacity 0.55
  - **PNG 저장**: 📷 이미지 버튼 → 오프스크린 div 마운트 → html2canvas(scale:2) → `회의록_YYYY-MM-DD_제목.png` 다운로드
  - CSS 추가: `.mtg-layout`/`.mtg-list-panel`/`.mtg-list-item`/`.mtg-detail`/`.mtg-sec`/`.mtg-item`/`.mtg-add`/`.mtg-check`/`.mtg-kind-{agenda,decision,action}` — 다크·라이트 모드 자동 대응(var(--bg)/var(--text) 사용)
- **운영 순서**: (1) Supabase SQL Editor에서 `setup_aps_meetings.sql` 실행 → (2) 📝 회의록 탭 → + 회의록 추가 → 제목·일시 입력 → (3) 상세 화면에서 안건/결정/액션 추가 → (4) 📷 이미지 버튼으로 PNG 저장·공유
- **한계**: BBCode 서식(굵게/색상) 미지원(자유메모는 whitespace 보존만). 회의록 간 항목 복사·이월 미지원. PNG는 항목 매우 많은 회의(50+건)에서 세로가 길어질 수 있음

### APS — 통계 탭 날짜별 뷰 추가 (2026-07-04)
- 사용자 요청: "통계탭은 날짜별로 나눠서 보여지게 가능할까"
- 기존: 통계 탭은 품목별 집계 하나뿐 → "이 품목 평균 몇 시간 걸리나" 확인 최적, 반면 "그날 뭘 얼마나 했나"(일자별 회고) 시나리오에는 부적합
- 변경: 통계 탭 최상단에 `📦 품목별 / 📅 날짜별` 뷰 토글 추가, 마지막 선택은 localStorage(`aps-stats-view-mode`)에 영속화 (생산계획 탭 viewMode 패턴 동일)
- **`setup_aps_v9.sql`** (신규, 1회 실행, v8까지 실행 전제):
  - **`aps_get_done_plans_all(p_admin_hash, p_days_back)`** 신규 RPC: status='done' + actual 시각 있는 plan 전체를 기간 필터로 반환
  - 응답 필드셋은 `aps_get_done_plans_for_item`과 통일 + `item_code`/`item_type` 추가 → 클라이언트에서 `StatsDrilldownTable` 재사용
  - 정렬: `actual_end_at DESC, id DESC` (최신 완료가 위)
- **`aps.html` 변경**:
  - `StatsDrilldownTable`에 `showItemColumn` prop 추가 (default false) — true일 때 `#` 다음에 품목명·코드 컬럼 렌더 + minWidth 760→920
  - `StatsTab` 최상단에 `viewToggle` UI + `viewMode==="date"`이면 `<DateStatsView>` 렌더 후 early return, `viewMode==="item"`이면 기존 렌더 그대로
  - 기존 `load(range)` useCallback에 `if(viewMode!=="item")return` 가드 추가 → 날짜별 뷰에서 불필요한 `aps_get_item_stats` 호출 방지
  - 신규 **`DateStatsView`** 컴포넌트:
    - 독립 state: `plans`/`range`/`expanded(dateStr)`/`editingId`/`editForm`/`saving`
    - `aps_get_done_plans_all` fetch → `groups` useMemo: `isoToKstDateStr(actual_end_at)`로 KST 날짜 그룹핑 → 각 날짜에 `count`/`totalHours`/`byUnit`(품목 단위별 총량) 집계 → 날짜 내림차순
    - 요약 카드 3개: 완료 계획 / 총 생산 시간 / 실적 있는 날짜
    - 표: 날짜(요일 색상 강조 — 일 빨강/토 파랑) + 완료 건수 + 품목별 수량 (unit별 분리 표시, 예 "22 박스 · 5.5 kg") + 총 시간
    - 날짜 행 클릭 → 펼침 → `StatsDrilldownTable` 재사용(showItemColumn=true)로 그날 완료된 plan 리스트 표시
    - 인라인 편집 로직(`startEdit`/`saveEdit`/`aps_update_plan_actuals`)은 품목별 뷰와 동일 패턴 재사용 → 저장 시 `load(range)` 재호출로 상위 통계 즉시 갱신
- **트레이드오프**: 두 뷰 모두 독립 fetch → 뷰 전환 시 매번 새로 로딩(캐시 없음). 대신 코드 흐름이 단순하고 편집 후 자동 반영이 즉시 동작
- **운영 순서**: Supabase에서 `setup_aps_v9.sql` 실행 1회 → 📈 통계 탭에서 `📅 날짜별` 토글로 즉시 사용

### APS — 실제 투입 원육 kg 입력 + 통계 반영 (2026-10-29)
- 사용자 요청: 계획(BOM) 원육 kg과 실제 투입 원육 kg이 달라 통계가 부정확 → 생산계획 수정에서 실제 투입 kg 입력
- **`setup_aps_raw_actual.sql`** (신규, 1회 실행, 재실행 안전): `aps_plan_raw_actuals(plan_id FK CASCADE, material_id FK CASCADE, kg, PK(plan_id,material_id))` + RLS. RPC `aps_get_plan_raw_actuals(hash, plan_ids[])`, `aps_set_plan_raw_actuals(hash, plan_id, rows [{material_id,kg}])`(통째로 교체, 빈 배열 = 삭제), `aps_get_raw_usage_stats(hash, days_back)`(실제 원육 입력된 완료 계획만 품목별 `total_raw_kg`·`total_qty`(actual_qty 우선)·원자재별 kg). 기존 함수 변경 없음
- **aps.html**: `RawActualInputs`(BOM 원자재별 실제 kg 입력 + 계획 대비 % + 원자재 2개 이상이면 계획/실제 합계), `loadPlanRawActuals`/`rawValuesToRows`/`isRawActualMissing`
  - `PlanForm` 수정 모드에만 "🥩 실제 투입 원육 kg" 접이식 칸(진행중·완료 계획이나 입력값이 있으면 펼쳐짐). 비교 기준 = BOM × 실제 수량(완료 계획에 actual_qty가 있으면) 또는 수량. 값이 바뀐 경우만 계획 저장 전에 `aps_set_plan_raw_actuals` 호출, SQL 미실행이면 창 안에 안내
  - 📈 통계 완료 계획 표(`StatsDrilldownTable`, 품목별·날짜별 공통): "실제 원육" 열(합계, 마우스 올리면 원자재별) + `🥩 원육` 버튼 → `PlanRawModal`(같은 입력칸, BOM은 실제 수량 기준)
  - 📈 통계 품목별 표: "원육 kg/단위 (실제 · BOM)" 열 = 실제 원육 합 ÷ 실제 수량 vs BOM 직접 자식 원자재 `qty×(1+loss)` 합(`aps_get_material_requirements` sources), 차이 % 색 표시
- 가짜 데이터로 확인(96박스 · 실제 108.5kg → 1.13kg/박스 vs BOM 1.02kg +11%, 수정 창 저장 값). 실제 DB 미확인
- **원육 고정, kg만 입력 (같은 날)**: 사용자 정정 "원육이 바뀌는 게 아니라 투입 kg만 바뀐다" → "+ 다른 원자재 추가"·BOM 외 원육·✕ 빼기 제거. 원육 이름은 BOM 그대로 표시하고 kg 칸만(빈 칸 = 계획 kg). 저장 시 BOM 원자재만 보냄(`rawValuesToRows(values, allowedIds)`). BOM에 원자재가 없으면 연결 안내
- 한계: 품목 BOM 비교는 직접 자식 원자재만(반제품 경유 원육은 BOM 값에 빠짐). 🤖 자동 생성·재고·발주 부족 알림은 여전히 BOM 기준(실제 원육 비율로 BOM을 보정하지 않음)

### APS — 📈 통계 생산 시간에서 점심 제외 (2026-10-29)
- 사용자 보고: 통계에 점심시간이 반영 안 됨 — 점심 12~13시면 그 사이는 빼야 함
- 원인: 서버 `aps_get_item_stats`와 화면(완료 계획 표·📅 날짜별)이 실제 종료 − 시작만 계산
- `loadLunch`(aps_get_settings 1분 캐시)/`useLunch`/`workMsBetween`/`workHoursOf`(기존 `speedLunchOverlapMs` 재사용 — 날짜마다 점심 겹침을 뺌)
- `rpc()`가 `aps_get_item_stats` 결과를 `adjustItemStatsForLunch`로 보정: 같은 기간 `aps_get_done_plans_all`(v9)로 품목별 총/평균 실제 시간·평균 계획 시간·시간당 생산량을 점심 빼고 다시 계산 → 📈 통계 품목별, 계획 추가 종료 시각 자동 계산, 🤖 자동 생성, 발주 부족 알림 속도가 모두 점심 제외 기준. 점심 미설정·v9 미실행이면 서버 값 그대로
- 완료 계획 표 "실제 시간"(수정 중 미리보기 포함)·📅 날짜별 총 시간도 점심 제외. ⚡ 속도 분석의 "기존" 비교도 점심 제외 시간으로 맞춤(열 이름 "기존 (통계)")
- SQL 변경 없음. 한계: 지금 설정된 점심시간을 지난 실적에도 똑같이 적용(점심 시간을 바꾸면 과거 통계도 바뀜). 서버 함수 자체는 그대로라 다른 곳에서 RPC를 직접 부르면 점심 포함 값

### APS — 📈 통계 긴 품목명 정리 (2026-10-29)
- 사용자 요청: 통계에서 품목명이 길게 늘어져 표가 옆으로 밀림
- `.aps-nm2` CSS(최대 240px, 2줄까지, 넘치면 잘림) — 마우스를 올리면 전체 이름(title)
- 적용: 📦 품목별 표 품목 열(열 폭 260px), 완료 계획 표(품목별·날짜별 공통) 품목 열(200px), ⚡ 속도 분석 품목별 표
- "아직 실적 없음: A, B, C…" 긴 한 줄 → "아직 실적 없는 품목 N개" 접기 + 펼치면 이름 칩(칩마다 220px, 한 줄 말줄임)

### APS — 재고 패널에 오늘 이후 계획 수량 컬럼 추가 (2026-07-06)
- 사용자 요청: "생산계획에서 재고on누르면 현재, 안전 재고 뜨는데 계획잡혀있는 품목도 옆에 계획이라고 뜨게. 만약 오늘이 7월 5일이고 7월 6일 계획 잡혀있으면 5,6일 계획된 수량이 뜨는거지. 당일부터 계획잡힌 날짜까지 합산하고 이전날짜는 없어지는"
- 기존: `InventoryQuickPanel`에 `현재`(재고시트 박스 수) + `안전`(aps_items.safety_stock) 두 컬럼 → 앞으로 얼마나 만들 예정인지가 즉시 안 보임 → 매번 계획 탭 표를 훑어야 함
- 변경: `계획` 컬럼 신설 — 오늘(KST) 이후 시작(start_at)하는 planned/in_progress 계획의 수량을 item_code별로 합산하여 표시. 완료/취소 계획은 제외. 오늘 이전 시작 계획은 자동 제외 → 지난 날짜는 사라지고 미래 계획만 남음
- **`InventoryQuickPanel` 변경** ([aps.html:1446](aps.html:1446)):
  - props에 `plans` 추가 (PlansTab의 `aps_list_plans` 결과 그대로 전달)
  - `plannedMap` useMemo: `plans.filter(status in ['planned','in_progress'] && isoToKstDateStr(start_at) >= todayStr())` → item_code별 qty 합산 map
  - `rows` useMemo에 `planned` 필드 추가 (템플릿 매칭 + extras 양쪽 모두). 값 0이면 `–` 회색 표시(`td.plan.none`), 값 있으면 시안색 강조(`td.plan`)
  - 테이블 head 행에 "계획" 컬럼 추가 (title 툴팁: "오늘 이후 계획된 수량 합계")
  - 마스터 외(extras) 섹션 colSpan="4" → colSpan="5"로 조정
  - 각 tr `title` 툴팁에 "· 오늘 이후 계획 N" 정보 추가
- **CSS 변경** ([aps.html:113-131](aps.html:113)):
  - `td.plan` 클래스 신설 (시안색 `#06b6d4`, width:32px, font-size:10px, font-weight:600)
  - `td.plan.none` (0인 경우 `var(--dimmer)` 회색)
  - 기존 컬럼 폭 축소: `td.qty width:34→32px`, `td.safety width:34→32px` — 5컬럼(dot/nm/qty/safety/plan) 배치 공간 확보
- **패널 폭 확대 (2026-07-06 follow-up)**: 사용자 피드백 "품목명이 짤린다" → `.aps-inv-panel` 240→280px, `td.nm max-width` 85→130px로 확대. 모바일 미디어쿼리(<980px)는 그대로 100% 폭 유지
- **`PlansTab`** ([aps.html:3155](aps.html:3155)): `<InventoryQuickPanel plans={plans}/>` prop 전달 (기존 items/adminHash와 함께)
- 별도 SQL 변경 없음, 기존 `aps_list_plans` 응답의 item_code/status/qty/start_at 필드 그대로 사용
- 한계: 계획 상태 여부만 판단 → 이미 부분 생산된 in_progress 계획도 원래 qty 전량으로 합산됨 (실제 남은 수량 개념 미구현. actual_qty가 완료 시 채워지지만 in_progress에서는 없음). 반제품 → 완제품 파급 소요량 미반영(사용자가 계획을 완제품 기준으로만 잡는다는 전제)

### APS 🩸 로스탭 + 제품별 원육 이력 모달 (2026-07-07)
- 사용자 요청: "로스탭을 만들고싶어. 참고 로직 파일과 생산일보 엑셀 첨부. 그리고 품목탭 제품 클릭하면 지금까지 그 제품 만들 때 어떤 원육 사용했는지 볼 수 있게. 생산일보 엑셀 업로드 → 누적"
- 참고 파이썬 로직: 원육 chain 개념 — 하나의 원육으로 여러 제품을 만들 때 첫 제품에 원육 매칭, 뒤 제품들은 `_inherited` carry-over. 체인 마지막 제품이 원본 원육 kg 기준으로 최종 로스 흡수, 중간 제품은 로스 0
- 엑셀 구조 분석: 시트 하나 = 하루 (시트명 YYYYMMDD). 좌측(A-H) = 원육, 우측(I-P) = 상품, 로스율(Q). 좌측 비면 상속. `XXXXXXXX 로스량 합계` 행 = 체인 로스 요약 (검증용). 마지막 "합 계" 행 스킵
- **`setup_aps_production.sql`** (신규, 1회 실행):
  - `aps_production_log` 테이블 (date, sheet_name, row_index, chain_id, is_chain_start/is_inherited/is_loss_summary 플래그, 원육 필드 8개 + 상품 필드 8개 + loss_reported 3개)
  - 인덱스: date DESC, product_code, raw_meat_code, (date, row_index)
  - RLS ENABLE + 정책 없음 → RPC로만 접근
  - RPC 7종 (모두 `aps_assert_admin` 검증):
    - `aps_upsert_production_batch(hash, rows)`: 날짜 범위 DELETE+INSERT 재업로드 idempotent
    - `aps_get_production_by_date(hash, date)`: 시트 원본 로우 목록 (row_index 순)
    - `aps_get_production_dates(hash)`: 저장된 날짜 목록 + 날짜별 요약(product_rows / total_raw_kg / total_prod_kg / total_loss_kg / loss_rate)
    - `aps_get_raw_meat_history_by_product(hash, product_code, days_back=365)`: 제품별 원육 사용 이력 — CTE로 prod_rows → matched_raws(chain_id 기준 JOIN chain_start) → per_raw(원육별 집계) + daily_details(일자별) → `{summary:[], daily:[]}` 반환. 상속 chain 관계는 이 SQL이 자동 역추적
    - `aps_get_production_meta(hash)`: 총 row 수, 총 date 수, 기간
    - `aps_cleanup_production(hash, days=365)`: 365일 초과 삭제
    - `aps_clear_production(hash)`: 전체 초기화 (WHERE TRUE)
- **`aps.html` 신규 헬퍼**:
  - `sheetNameToDate(name)`: "20260615" 또는 "2026-06-15" → "2026-06-15"
  - `extractDateFromHeaderCell(v)`: R2 A열 "2026년06월15일" 파싱 fallback
  - `parseProductionWorkbook(buf)`: SheetJS로 모든 시트 순회 → 각 시트를 원육/상품 페어 로우로 정규화. chain_id는 chain_start 카운터로 증가, is_inherited는 좌측 빈 데이터 행, is_loss_summary는 `XXXXXXXX` 또는 "로스량 합계" 매칭. 500행씩 배치 업로드
  - `calcProductLoss(entry)`: 원육 총 투입 kg / 상품 산출 kg → 로스 kg / 로스율 계산
  - `computeSheetLoss(rows)`: **참고 파이썬 로직 완전 이식** — rows → product_entries 구성 (chain_start는 원육 매칭, is_inherited는 carry-over placeholder) → 순회하며 remaining_kg 넘김 → 체인 중간 제품 로스 0 처리 → 체인 마지막 제품(상속됨) 원본 투입 기준 재계산 → 요약 반환
  - `fmtLossKg`/`fmtLossPct`/`lossRateColor` (rate별 색상: ≤5% 초록/≤15% 노랑/≤30% 주황/>30% 빨강)
- **신규 `ProductionLossTab({adminHash})`**:
  - 툴바: 📁 생산일보 업로드 + 새로고침 + 🗑 365일 정리 + ⚠ 초기화
  - 요약 카드 4개: 저장 일자 / 총 로우 / 기간 / 전체 평균 로스율
  - 2컬럼 레이아웃(grid 260px 1fr): 좌 = 날짜 리스트 sticky panel (최근 순, 활성 시안색 border), 우 = 그날 상세
  - 상세: 오늘 요약(원육 총 투입 / 상품 총 산출 / 총 로스 / 평균 로스율) + `ProductionLossDetail` 체인별 카드
  - `ProductionLossDetail`: chain_id 기준 그룹핑 → 각 체인 카드 헤더에 🥩 원육명·코드·원산지·kg + 체인 로스 강조 + 하위에 상품 테이블(순번/제품/박스/kg/매입금액/계산 로스/원본 로스). 상속 제품은 "↪ 상속" 뱃지
- **신규 `RawMeatHistoryModal({adminHash, product, onClose})`**:
  - 품목탭에서 제품/반제품 행의 🥩 원육 버튼 클릭 → 모달 오픈
  - 기간 필터 (30/90/180/365일)
  - `📊 원육별 총 사용량` 테이블: 순번/원육(코드·원산지)/사용 일수/이 제품 총 생산 kg/비중(%)/기간
  - `📅 일자별 사용 원육`: 각 일자마다 사용된 원육들을 색상 뱃지로 (원육명 → 제품 X kg)
  - 서버 CTE가 상속 체인 자동 역추적 → 클라이언트 계산 없이 즉시 표시
- **`ItemsTab` 변경**: 제품/반제품 행의 작업 컬럼에 `🥩 원육` 버튼 추가 (원자재는 제외). `histTarget` state + `<RawMeatHistoryModal>` 렌더
- **탭 등록**: `VALID_TABS`에 "loss" 추가, App 렌더에 `<ProductionLossTab>` 등록, `📝 회의록` 옆에 `🩸 로스` 탭 버튼
- **운영 순서**: (1) Supabase에서 `setup_aps_production.sql` 실행 → (2) 🩸 로스탭 → 📁 생산일보 업로드 → (3) 저장된 날짜 클릭해 상세 확인 → (4) 📦 품목/BOM 탭에서 제품 행의 🥩 원육 버튼 클릭 → 원육 사용 이력 조회
- **한계**: (1) 로스 계산은 excel의 product_kg를 그대로 완성품 kg로 간주 — 참고 파이썬의 spec conversion(packs_per_box/kg_per_box)은 미구현 (aps_items.spec 정보와 연동 필요 시 후속 확장). 매칭 없는 코드는 loss=0 나올 수 있음. 대신 "원본 로스" 컬럼에 excel의 XXXXXXXX 로스율을 병기해 참고 가능. (2) 시트명이 YYYYMMDD 아니고 R2도 없으면 시트 스킵. (3) 원육 이력 모달은 chain_start 원육만 표시 → 상속 chain의 실제 사용 원육은 자동 역추적됨

### APS 로스탭 — 좌우 매핑 정정 (2026-07-07)
- 사용자 지적: "왼쪽이 A3 생산 제품, 오른쪽이 I3 투입 품목인데 뭘 보고 왼쪽이 원육이라 판단했어?"
- 원인: 최초 구현 시 인코딩 깨진 엑셀 원문에서 R3 그룹 헤더를 정확히 못 읽고 R5-R7의 kg 합계(원육 888 = 제품 37.9+812.2+37.9)만 보고 "왼쪽=원육, 오른쪽=제품"으로 오판. 실제 그룹 헤더는 A3="생산 제품", I3="투입 품목"으로 정반대
- 재해석: 하나의 제품(LEFT) 만들 때 여러 원육(RIGHT)이 순차 투입 → 그게 하나의 chain. LEFT 비고 RIGHT만 있는 행 = 같은 제품에 원육 추가 투입 (상속이 아니라 continuation). 참고 파이썬의 carry-over/chain 상속 로직은 "원육 하나가 여러 제품에 분배" 시나리오인데, 실제 엑셀은 반대(제품 1 : 원육 N) → 상속 로직 불필요
- **`parseProductionWorkbook` 컬럼 스왑**: 0-7 → product_*, 8-15 → raw_meat_*. XXXXXXXX 감지 위치도 col 0 → col 8. `is_chain_start`=LEFT 채워짐, `is_inherited`=계속 필드명 유지하되 의미는 continuation(같은 제품에 원육 추가)
- **`computeSheetLoss` 재작성**: 참고 파이썬 carry-over 로직 완전 제거. chain_id 기준 그룹핑 → 각 chain당 하나의 제품 + 여러 원육 → `loss = Σraw_meat_kg − product_kg`. 코드 절반으로 축약
- **`ProductionLossDetail` UI 재정렬**: chain 헤더가 이제 📦 제품(코드·박스·kg·매입금액 요약), 아래 테이블이 🥩 투입 원육 리스트(순번·원육명·박스·kg·매입금액·비중). 하단 합계 행에 "원육 총량 → 제품 kg / 로스율" 명시
- **SQL 2종 재작성**:
  - `aps_get_production_dates`: total_raw_kg는 모든 non-summary 로우의 raw_meat_kg 합. total_prod_kg는 chain_start의 product_kg 합. loss_kg = GREATEST(raw − prod, 0)
  - `aps_get_raw_meat_history_by_product`: product_code로 **is_chain_start** 로우 찾고 (date, chain_id)로 같은 chain 내 모든 raw_meat 로우(chain_start + continuation) JOIN. 응답 필드도 `total_product_kg` → `total_raw_kg`로 개명 (원육 총 사용량으로 의미 변경)
- **`RawMeatHistoryModal`**: 컬럼 라벨 "이 제품 총 생산 kg" → "총 사용 kg" (원육 사용량 관점). daily 뱃지 "→ 제품 X kg" → "X kg 투입"
- **인트로 텍스트 수정**: "상속 체인은 원본 원육 투입 기준" → "엑셀 좌측=제품/우측=원육. 하나 제품에 여러 원육 순차 투입"
- **테이블 스키마는 그대로 유지** (필드명은 raw_meat_* / product_* 그대로 사용 가능) → SQL DROP 없이 함수만 CREATE OR REPLACE로 갱신 가능
- **운영 순서** (이미 setup_aps_production.sql 실행한 사용자): `aps_get_production_dates`/`aps_get_raw_meat_history_by_product` 두 함수 블록만 재실행. 기존 업로드 데이터는 있으면 삭제 후 재업로드 (파서가 뒤바뀌었으므로 기존 저장 데이터는 좌우가 반대로 저장돼 있음)

### APS 로스탭 — 제품명 스펙 파싱 + 실제 완성 kg 반영 (2026-07-07)
- 사용자 지적: "제품명이 `500g*8`, `1kg*6` 등으로 된 제품은 excel product_kg가 사실상 총 팩 수 → 팩당 kg를 곱해야 실제 완성 kg. 예: `[S]돌돌말이 우삼겹 500g*8` 288 → 288×0.5 = 144kg"
- 배경: excel 좌측(A-H)의 kg 컬럼은 kg 단위가 아니라 (박스 수 × 박스당 팩 수) = 총 팩 수. 실제 완성 kg를 얻으려면 제품명 스펙에서 팩당 무게를 파싱해서 곱해야 함
- **`extractPackWeightFromName(name)`** 신규 헬퍼: 정규식 `(\d+(?:\.\d+)?)\s*(kg|g)\s*\*\s*\d+` 매칭. 예 `500g*8`→0.5, `1kg*6`→1, `3kg*5`→3, `600g*10`→0.6. 매칭 안 되면 null → excel 값 그대로 사용
- **`computeSheetLoss` 변경**:
  - 각 chain의 product에서 `packWeightKg = extractPackWeightFromName(product_name)` 계산
  - `totalOutputKg = packWeightKg != null ? excelProdKg * packWeightKg : excelProdKg`
  - product entry에 `pack_weight_kg`, `excel_product_kg` 필드 추가 (UI 표시용)
  - Loss = Σraw_kg − actualOutputKg (스펙 파싱으로 훨씬 정확)
- **`ProductionLossDetail` UI**:
  - Chain 헤더의 생산량 표시가 조건부: 스펙 있으면 `<b>실제 144 kg</b> (288팩 × 500g)`, 스펙 없으면 excel 값 `288 Kg` 그대로
  - `pack_weight_kg`가 1kg 이상이면 `Xkg`, 미만이면 `Xg` 형식 표기
- **인트로 텍스트 갱신**: `<code>500g*8</code>/<code>1kg*6</code> 등 스펙 있으면 excel의 생산량 × 팩당 kg = 실제 완성 kg (예: 288 × 500g = 144kg) 명시
- **효과**: 이전에는 excel product_kg가 원육 kg보다 훨씬 크게 나와서 로스가 음수(-)로 표시되는 케이스가 정상 계산됨. 예: 원육 153kg → 실제 완성 144kg → 로스 9kg = 5.93% (기존엔 288kg product로 -35kg = -22% 오표시)
- **한계**: (1) `X × Y` (곱셈 기호 `×`)나 `Xg/N` 같은 다른 표기법은 미지원 (asterisk `*`만 매칭). (2) 제품명에 무게가 여러 개 있으면 첫 번째만 사용 (예: `120g*10*5팩` → 120g). (3) 스펙 없는 제품(냉장 원육 등)은 excel 값 그대로 사용 → 실제 로스와 다를 수 있음 (그러나 원육 성격 자체가 스펙 없이 kg 단위로 유통되므로 대체로 정확)
- 별도 SQL 변경 없음 (계산은 클라이언트 로직)

### APS 로스탭 — 날짜별 삭제 버튼 (2026-07-09)
- 사용자 요청: "업로드 데이터를 전체초기화말고 날짜 하나하나 삭제할수있는 기능"
- 기존: 🗑 365일 정리 / ⚠ 전체 초기화만 존재 → 특정 날짜만 잘못 업로드된 경우 대응 불가
- **`setup_aps_production.sql` 신규 RPC `aps_delete_production_date(p_admin_hash, p_date)`**: `aps_assert_admin` 검증 후 `DELETE FROM aps_production_log WHERE date = p_date`. p_date NULL이면 `date_required` 예외. 반환 `{deleted, date}`
- **`aps.html` `ProductionLossTab`**:
  - `handleDeleteDate(date)` 핸들러 추가 — confirm 후 RPC 호출, 삭제한 날짜가 현재 selectedDate이면 `sheetRows`/`selectedDate` 초기화
  - 좌측 날짜 리스트 각 행에 🗑 삭제 버튼 (빨강 outline, `e.stopPropagation()`으로 selectedDate 클릭과 충돌 방지, busy 상태 시 disabled)
  - 기존 날짜 셀 flex 레이아웃(정보 좌 / 삭제 버튼 우 flex-shrink:0)
- 운영 순서: Supabase에서 `setup_aps_production.sql`의 `aps_delete_production_date` 함수 블록만 재실행 → 즉시 사용

### APS 로스탭 — 제품 코드 = 원육 코드 chain 자동 제외 (2026-07-11)
- 사용자 요청: "투입원육이랑 생산제품이 코드가 같으면 제외해줘" — 재작업/재포장 케이스로 실제 로스 계산에 노이즈가 됨
- 변경: `parseProductionWorkbook`에 `currentChainProdCode` 상태 변수 추가
  - **chain_start 케이스**: `hasProdInfo && prodCode && rawCode && prodCode === rawCode`면 chain 자체 무효 → `currentChainInvalid=true`+`currentChainProdCode=""`+`continue`. `chainId++`도 발생 안 함(0 수량 chain과 동일 흐름)
  - **continuation 케이스**: LEFT 빈 행에서 `rawCode === currentChainProdCode`면 그 행만 스킵 (chain의 다른 원육 continuation은 유지)
  - 유효 chain 시작 시 `currentChainProdCode = prodCode` 기록 → 이후 continuation 원육 코드 비교용
- 별도 SQL 변경 없음 (클라이언트 파서 단계에서 필터링, DB에는 저장되지 않음)

### APS 로스탭 — 수량 0인 제품 chain 자동 스킵 (2026-07-09)
- 사용자 요청: "로스탭에서 생산일보 업로드할때 생산제품에 수량이 안적혀있으면 그 제품하고 연결된 원육은 없는것처럼 해줄수있을까? 예시엑셀의 `소일반갈비(작업)`이랑 `[S]돌돌말이 우차돌박이 500g*8`처럼 수량이 없는 것들"
- 기존 문제: `parseProductionWorkbook`에서 `hasProd = !!prodCode && prodKg>0`만 체크 → prodCode 있고 prodKg=0인 행은 `hasProd=false`로 판정되어 이전 chain의 continuation으로 오분류되고, 옆의 원육 kg이 이전 유효 chain에 잘못 합산됨
- 예시: R5 `소양다리(작업)` 정상 chain 다음 R7 `소일반갈비(작업)` prodKg=0에 원육 53.5kg 있으면 → R7의 53.5kg이 R5(소양다리) chain에 합산되어 로스율 왜곡
- 변경: `parseProductionWorkbook`에 `currentChainInvalid` 상태 변수 도입
  - `hasProdInfo = !!prodCode || !!prodName` (LEFT에 제품 코드/이름 중 하나라도 있으면 새 chain 시작 의도)
  - `if(hasProdInfo && prodKg<=0){currentChainInvalid=true;continue}` — 수량 0인 무효 chain 스킵
  - `if(hasProdInfo){currentChainInvalid=false}` — 유효 chain 시작 시 플래그 해제
  - `if(!hasProdInfo && currentChainInvalid)continue` — 무효 chain 소속의 continuation/loss summary도 스킵
- 결과: R7·R8·R9(R8 continuation) 모두 저장에서 제외 → 이전 chain에 원육 kg 오합산 방지. 이후 R10 유효 chain부터 정상 처리
- chain_id 증가는 원래 유효 chain(`hasProd`)에서만 발생하므로 무효 chain 스킵해도 chain_id 카운터 무결성 유지

### APS 로스탭 — 제품 검색 뷰 추가 (2026-07-07)
- 사용자 요청: "로스탭에 제품명 검색해서 평균로스 볼수있게" — 특정 제품의 누적 로스 트렌드를 한 번에 보고 싶다
- 기존: 로스탭은 `📅 일자별` 뷰만 존재 → 특정 제품의 누적 평균 로스를 보려면 각 날짜를 하나씩 클릭해야 함
- 변경: 로스탭 툴바에 `📅 일자별 / 🔍 제품 검색` 뷰 토글 추가, localStorage(`aps-loss-view-mode`)에 마지막 선택 영속화 (통계 탭 viewMode 패턴 동일)
- **`setup_aps_production_v2.sql`** (신규, 1회 실행, setup_aps_production.sql 실행 전제):
  - **`aps_get_product_chain_stats(hash, days_back)`** 신규 RPC: chain-level 통계 반환
  - CTE 3단(`chain_starts` — chain_start & product_code<>'' 조건 / `chain_raws` — GROUP BY (date, chain_id)로 원육 kg 합계 / `joined` — LEFT JOIN)
  - 응답 필드: `date, chain_id, product_code, product_name, product_origin, product_boxes, product_kg, product_unit, product_amount, chain_raw_kg, chain_raw_amount`
  - 팩당 kg 파싱은 서버에서 하지 않음 — 클라이언트 `extractPackWeightFromName`이 제품명에서 스펙 추출 후 계산 (일자별 뷰와 산식 통일)
- **`aps.html`** 변경:
  - 신규 컴포넌트 **`ProductLossSearchView({adminHash})`**: 제품 검색 + 평균 로스 집계 UI
    - state: `chains`, `range`(30/90/180/365일), `q`(검색어), `sortKey`(rate/uses/rawkg/recent)
    - `grouped` useMemo: chain 단위 데이터 → `product_code` 기준 집계 → `{code, name, unit, origin, totalRawKg, totalOutputKg, uses, useDays(dates.size), lastDate, hasPackSpec, lossKg, lossRate}` 리스트. 각 chain의 `actualOutputKg = packKg != null ? excelProdKg * packKg : excelProdKg` 산식 적용 (일자별 뷰의 `computeSheetLoss`와 동일)
    - `filtered` useMemo: `q`(대소문자 무관 부분일치, 제품명·코드 매칭) + sortKey 정렬
    - `overall` useMemo: 필터된 결과의 총 원육/실제 완성/평균 로스율 (Σ 방식)
    - 요약 카드 4개: 검색 결과 개수 / 총 원육 투입 / 총 실제 완성 / 평균 로스율 (색상 lossRateColor)
    - 메인 테이블: # / 제품명(+ 코드·원산지·팩 스펙 여부) / 사용 횟수(chain 수) / 사용 일수 / 총 원육 kg / 실제 완성 kg / 총 로스 kg / 평균 로스율 / 최근 사용일
    - 안내 박스: 산식 + 팩 스펙 처리 + 여러 chain 합산 규칙 명시
  - **`ProductionLossTab`** 확장: `viewMode` state + `localStorage` 영속화. 툴바 우측(업로드 버튼 옆)에 `📅 일자별 / 🔍 제품 검색` segmented 토글(`aps-view-toggle` 재사용). `viewMode==="product"`이면 `<ProductLossSearchView>` 렌더, `viewMode==="daily"`이면 기존 요약 카드 + 안내 + 날짜 리스트/상세 그리드 렌더
  - 두 뷰 사이 fragment(`<>...</>`) 감싸기, 안내 텍스트("계산 방식: …")는 daily 모드에서만 표시
- **동작 예시**: "돌돌우삼겹" 검색 → 최근 365일 동안 이 제품이 chain_start로 등장한 모든 날짜의 원육 kg + 실제 완성 kg 합산 → 평균 로스율 5.9% 표시. `500g*8` 스펙 자동 반영. "팩 스펙" 뱃지로 스펙 파싱 여부 시각화
- **운영 순서**: Supabase에서 `setup_aps_production_v2.sql` 실행 1회 → 🩸 로스탭 → `🔍 제품 검색` 토글 → 즉시 사용
- **한계**: (1) 서버측은 chain-level 원본 데이터만 반환하고 팩당 kg 파싱·집계는 클라이언트 → 365일치 chain이 수천 건이면 초기 로딩 payload 커질 수 있음(그래도 화면당 1회만). (2) 제품 검색 뷰는 검색어 무관하게 항상 전체 chain을 fetch → 검색만 클라이언트 필터. 서버측 ILIKE 필터 추가 시 payload 절감 가능하나 sortKey/집계가 클라이언트 로직이라 큰 이득 없음. (3) 제품이 `product_code` 기준으로 그룹핑됨 → 코드가 없거나 여러 제품이 같은 코드를 쓰면 병합될 수 있음(실제로는 회사 ERP에서 code=고유식별자로 신뢰 가능)

### APS v10 — 생산계획 🤖 자동 생성 (2026-10-15)
- 사용자 요청: 재고·요일별 매출 추이·제품 생산능력을 보고 그날 계획표를 자동 생성. 제품마다 생산 라인 지정, 제품당 평균 생산시간 반영, **재고가 떨어지기 2일 전부터** 미리 생산, 라인별 자동계획 허용 버튼
- **`setup_aps_v10.sql`** (신규, 1회 실행): `aps_items.line_ids JSONB`(생산 가능 라인 id 배열) + `aps_items.units_per_hour NUMERIC NULL`(수동 시간당 생산량) + `aps_lines.auto_plan BOOLEAN DEFAULT FALSE`. `aps_list_items`/`aps_list_lines` 재정의(새 필드 포함). 신규 RPC `aps_set_item_plan_info`(라인+시간당 생산량 저장 — `aps_upsert_item` 시그니처는 안 건드림), `aps_set_line_auto`, `aps_get_sales_dow(hash, weeks=8)`(매출 마지막 날짜부터 N주 윈도우, 요일별 평균 = 그 요일 판매 합 ÷ 윈도우 안 그 요일 수 — 판매 없는 날도 분모 포함)
- **ItemForm**(제품/반제품): "🏭 생산 라인" 칩 다중 선택 + "시간당 생산량" 입력. `aps_upsert_item` 후 `aps_set_item_plan_info` 호출(SQL 미실행이면 경고 alert). 품목표 품목명 아래에 라인 뱃지
- **LinesTab**: "자동계획" 열 — `🤖 허용 / 허용 안 함` 토글(기본 꺼짐)
- **PlansTab**: 툴바에 "🤖 자동 생성"(전체 날짜 모드에서는 비활성) → `AutoPlanModal`, 선택한 날짜 기준
- **`computeAutoPlan`** (클라이언트):
  - 대상: 제품/반제품 중 라인 지정 + 허용 라인 있음 + 요일 매출 있음 + 재고시트(`invData.products` box)에 코드 있음
  - 오늘부터 하루씩 재고 시뮬레이션: `재고 += 기존 계획(계획/진행중, 종료일 기준, 오늘 이전 종료분 제외) − 요일 평균 매출`. 선택일 이전 품절은 0으로 리셋(못 판 수요 이월 안 함)
  - 생산 조건: 첫 소진일(재고 < 바닥, 바닥 = 0 또는 옵션으로 안전재고) ≤ 선택일 + 리드일(기본 2) → "소진 2일 전부터" 생산
  - 생산량 = ⌈바닥 + 선택일부터 N일치(기본 5) 수요 − 선택일 시작 재고 − 그 기간 기존 계획 입고⌉
  - 생산 속도: 📈 통계 `aps_get_item_stats` qty_per_hour(최근 180일 우선, 없으면 전체) → 없으면 품목 `units_per_hour` → 없으면 제외("생산 속도 없음")
  - 배정: 소진일 빠른 순 → 하루 평균 판매 많은 순. 라인 커서 = 근무 시작 or 그날 기존 계획 끝(오늘이면 현재 시각 이후), 15분 단위 올림, 제품 전환 시간(분) 옵션. 가능한 라인 중 가장 빨리 비는 라인. 근무 종료를 넘으면 들어가는 만큼만(부분, "필요 N · 시간 부족" 표시), 15분도 안 남으면 제외
- **모달 UI**: 옵션(소진 며칠 전 / 생산 분량 일수 / 제품 전환 분 / 매출 기준 주수 / 안전재고를 바닥으로 — localStorage `aps-autoplan-opts`), 허용 라인 칩 토글(`aps_set_line_auto` 즉시 저장), 재고시트 저장일(오늘 이전이면 ⚠)·매출 기간·근무시간 표시. 제안 표(체크박스/품목·속도 출처/현재 재고·당일 예상/하루 평균·이날 판매/소진 예상일/생산 수량/라인/시간) + 제외 품목 사유별 묶음. "선택 N건 생성" → `aps_upsert_plan`(status planned, 메모 비움 — 2026-10-15 사용자 요청으로 "🤖 자동생성" 표기 제거, 시간 부족으로 일부만 배정된 경우에만 `시간 부족: 필요 N`)
- 재실행해도 이미 만든 계획이 입고로 잡혀 중복 생성되지 않음. 지난 날짜는 생성 불가
- **운영 순서**: (1) Supabase에서 `setup_aps_v10.sql` 실행 → (2) 🏭 라인 탭에서 자동계획 허용 → (3) 📦 품목에서 제품별 생산 라인 지정(+실적 없으면 시간당 생산량) → (4) 📅 생산계획에서 날짜 선택 → 🤖 자동 생성
- 한계: 단위는 재고시트 박스 = 매출 qty = 계획 qty로 가정. 재고시트 업로드 이후~오늘 사이 판매는 차감 안 함(시트를 그날 재고로 간주). 한 제품을 여러 라인에 나눠 배정하지 않음. 반제품 → 완제품 BOM 소요는 반영 안 함. 주말·휴무일 구분 없음(매출 요일 평균이 0이면 자연히 0 소비)

### APS v11 — 매출 날짜별 조회 + 상품별 주×요일 표 (2026-10-15)
- 사용자 질문: "매출 탭에 날짜는 안 나오나?" + 요일 평균은 "지난주 월 40, 이번주 월 20 → 월요일 평균 30" 방식이어야 함
- 기존: 매출 탭은 상품별 합계/주평균만, 날짜는 "보유 기간"(최소~최대)만 표시. 요일 평균은 같은 산식이었지만 분모가 "윈도우 안 달력상 그 요일 수"라 휴무·미업로드 날도 0으로 들어가 평균이 낮아질 수 있었음
- **`setup_aps_v11.sql`** (신규, 1회 실행, 테이블 변경 없음):
  - `aps_get_sales_dow` 재정의: 분모 = 윈도우(마지막 매출일부터 N주) 안에서 **매출이 업로드된 날짜**(어느 상품이든 1건 이상) 중 그 요일 수. 그날 업로드는 됐는데 이 상품이 안 팔렸으면 0으로 포함, 매출 파일 자체가 없는 날은 제외
  - 신규 RPC `aps_get_sales_dates(hash, days=365)`(날짜별 총 판매·상품 수), `aps_get_sales_by_date(hash, date)`(그날 상품별), `aps_get_sales_by_code(hash, code, weeks=8)`(`{start,end,uploaded_dates,rows}` — 윈도우는 요일 평균과 동일)
- **`SalesTab`**: `📦 상품별 / 📅 날짜별` 토글(localStorage `aps-sales-view`)
  - 📅 날짜별 `SalesDatesView`: 업로드된 날짜(요일, 주 경계 굵은 선) / 상품 수 / 총 판매, 행 클릭 시 그날 상품별 판매 칩
  - 📦 상품별: 상품 행 클릭 → `SalesDowGrid` 펼침 — 주(월요일)×요일 매출 표 + 주 합계 + 맨 아래 "요일 평균"(합계 ÷ 업로드된 그 요일 수, 일수 표시). `–` = 그날 매출 파일 없음, `0` = 올라왔지만 안 팔림. 업로드 없는 주는 숨김
  - "요일 평균 기준 최근 N주" 선택(2/4/8/12) — 🤖 자동 생성 옵션(`aps-autoplan-opts-v2.weeks`)과 같은 값을 공유 (`loadAutoPlanWeeks`/`saveAutoPlanWeeks`)
- SQL 미실행이면 새 화면에 "setup_aps_v11.sql 을 먼저 실행" 안내

### APS 자동 생성 — 부족 판단 로직 수정 (2026-10-15)
- 사용자 보고: "소진 14일 전으로 해도 계획을 잘 안 잡는다". 기대 예시: 금요일 계획 · 월요일 평균 매출 40 · 현재고 60 · 안전재고 30 → 금요일에 생산해야 함
- 원인 3가지: (1) 바닥 기본값이 0("안전재고를 바닥으로" 꺼짐) → 60−40=20은 부족 아님 (2) "N일 전"을 달력일로 셈 → 금+2일=토·일, 월요일 부족이 범위 밖 (3) 생산 분량이 `max(리드+1, 분량)`이라 리드 14면 15일치를 만들어 첫 품목이 라인 하루를 다 차지 → 나머지는 "시간 부족"으로 제외
- 변경:
  - 바닥 기본값 = 안전재고(옵션 "안전재고 밑으로 떨어지면 부족", 기본 켜짐). 옵션 저장 키 `aps-autoplan-opts-v2`로 변경해 예전 저장값(꺼짐) 무시
  - "생산 요일" 옵션(월~일 토글, 기본 월~금) + `nthProdDayAfter(day, n, prodDays)` — 부족 판단 범위 = 선택일 ~ 선택일 이후 n번째 생산 요일(금 + 2 = 월·화). 선택일이 생산 요일이 아니면 ⚠ 표시
  - 생산 분량을 리드와 분리: 생산량 = 선택일 ~ max(선택일+분량−1, 부족 시작일) 동안 **매일** 예상 재고(새 생산 없이)가 바닥 이상이 되는 최소량(`max(바닥 − 하루 끝 재고)`). 예전엔 마지막 날 합계만 맞췄음
  - 라벨: "소진 N일 전부터 생산" → "부족 N생산일 전부터 생산", 표 열 "소진 예상" → "부족 예상"
- 검증(노드): 위 예시 → 금요일 10박스 생산(부족일 월요일), 안전재고 옵션 끄면 제외, 리드 14여도 10박스(예전처럼 부풀지 않음)

### APS 자동 생성 — 여유 생산 + 여러 날 한 번에 생성 (2026-10-23)
- 사용자 요청: 재고가 1순위지만, 모든 제품 재고가 차 있어도 계획을 안 잡지 말고 일정량 잡아서 생산이 돌아가게 + 여러 날 한 번에 생성
- **여유 생산** (`computeAutoPlan`): 부족 제품(기존 로직)을 먼저 배정한 뒤 라인 시간이 남으면, 급하지 않은 제품을 **재고 일수(선택일 끝 예상 재고 ÷ 하루 평균 판매) 적은 순**으로 채움. 목표 = 재고가 하루 평균 판매 `fillDays`일치(기본 14, 안전재고가 더 크면 안전재고)가 될 때까지
  - 너무 작은 양을 매일 끼워 넣지 않도록: 모자란 양이 1시간 생산분(`FILL_MIN_HOURS`) 이상일 때만 후보, 남은 라인 시간이 30분(`FILL_MIN_PART_MS`) 미만이면 넣지 않음
  - 생산 속도가 없는 제품은 여유 생산 대상 아님. 배정은 기존 `place()`(가장 빨리 비는 라인, 점심·전환 시간 반영) 공유
  - 모든 제품이 `fillDays`일치를 넘으면(진짜 과잉 재고) 여유 생산도 안 잡힘 → 옵션 값을 올리면 됨
- **여러 날 생성** (`computeAutoPlanRange`): 선택일 + 다음 생산 요일들로 `days`일(최대 20). 앞날에 만든 계획을 가상 계획으로 넣고 다음 날 재고·라인 시간을 계산 → 중복 없이 이어짐. 제외 목록은 첫날 기준(기간 중 계획된 제품 제외)
- 모달: 옵션 "생성 기간 N생산일", "라인이 남으면 여유 생산 · 재고 최대 N일치까지"(기본 켜짐, `aps-autoplan-opts-v2`에 `fill`/`fillDays`/`days`), 표에 날짜 구분 행 + 여유 생산 행은 초록 "여유 생산 · 재고 N일치" 뱃지. 행 key = `날짜:품목id`
- 한계: 여러 날 생성에서 앞날 행 체크를 빼도 뒷날 수량은 다시 계산되지 않음(안내 문구 표시). SQL 변경 없음
- **같은 원육 묶기 (같은 날 추가)**: 사용자 요청 — 비슷한 제품끼리 이어서 생산해 전환 줄이기
  - 그룹 = 제품의 **주 원육**(BOM 직접 자식 원자재 중 `qty × (1+loss)`가 가장 큰 것). 모달이 기존 `aps_get_material_requirements`(v8) 응답의 sources에서 `groupByItem{item_id:{id,name}}` 생성 → `computeAutoPlan(..., groupByItem)`. BOM 없는 제품은 묶지 않음. SQL 변경 없음
  - ① 배정: 라인 고를 때 그 라인에 같은 원육 제품(기존 계획 포함)이 있으면 전환 시간을 "같은 원육 전환"으로 보고 비교 → 같은 원육이 한 라인에 모임(같은 시작 시각이면 같은 원육 라인 우선)
  - ② 순서: 라인마다 다시 줄 세움 — 직전과 같은 원육 중 가장 급한 것 → 없으면 남은 것 중 가장 급한 것(부족 생산이 여유 생산보다 앞). 그날 그 라인의 마지막 기존 계획 원육에서 시작. 시간 재계산 후 근무 종료를 넘는데 그게 부족 생산이면 가장 덜 급한 여유 생산을 빼고 다시 계산, 아니면 넘친 것부터 제외
  - 옵션: "같은 원육 제품 이어서 생산"(기본 켜짐) + "같은 원육끼리 전환 N분"(기본 0, 일반 "제품 전환" 분보다 크면 일반 값 사용). 결과 행은 라인 → 시작 시각 순, 품목 칸에 `🥩 원육` + `🔗 이어서`, 상단에 "제품 전환 N회"
  - 노드 검증: 1라인 5제품(원육 2종) 전환 4회 → 1회, 2라인 3회 → 0회
  - 한계: 날짜가 바뀌면 전날 마지막 원육은 이어받지 않음(매일 근무 시작부터 새로). 원육 외 기준(양념 등)은 없음

### APS — 🧮 최적 배치 계산 (자동 생성) (2026-10-29)
- 사용자 질문: Groq 토큰 한도(413: 요청 11,626 > 분당 8,000) → "내 머신러닝 AI로 대체할 수 없나" → 숫자 판단은 직접 만드는 게 낫다는 결론, 1단계로 배치 최적화
- `optimizeDayPlan` (aps.html, `computeAutoPlan` ③단계): 규칙 결과(①배정 + ②원육 순서)를 출발점으로 담금질 탐색(고정 난수 → 같은 입력이면 같은 결과). 바꾸는 것 = 라인 배정·순서·여유 생산 넣고 빼기, **수량은 규칙 그대로**
  - 점수(낮을수록 좋음): 못 넣은 부족 생산 시간 × 100 × 급한 정도(1 + 3 ÷ (1 + 부족까지 남은 날)) − 여유 생산 시간 × 2~5(재고 일수 적을수록 큼) + 제품 전환 1.5(같은 원육 0.3) + 급한 제품 늦은 시작 × 0.02
  - 움직임: 빠진 제품 넣기 / 빼기 / 같은 라인 자리 바꾸기 / 다른 라인으로 옮기기(35%는 같은 원육 묶음째). 반복 3000 + 품목×400(최대 25,000, 생성 기간 4일 이상이면 절반)
  - 시간 계산은 ②와 동일(전환 시간, 점심, 근무 종료 넘으면 들어가는 만큼, 여유 생산 30분 미만 안 넣음, ⚡ 속도 모델은 라인별 속도). 규칙 결과보다 좋아질 때만 교체, 제외 목록도 다시 만듦
  - 결과 `optInfo {improved, before, after:{sw, unmet, fill}}` — 여러 날은 합산
- 모달: 옵션 "🧮 최적 배치 계산"(기본 켜짐, `aps-autoplan-opts-v2.optimize`) + 결과 위 초록 줄 "규칙 결과 대비 못 넣은 부족 생산 14 → 0 · 제품 전환 4 → 2회"
- 노드 가짜 데이터(3라인·14~18품목·원육 3~4종): 제품 전환 4~5 → 1~2회, 같은 조건에서 못 넣던 부족 14박스 배정, 겹침·중복 0, 1일 약 30~140ms. 실제 데이터·화면 클릭 미확인. SQL 변경 없음
- 한계: 한 제품을 두 라인에 나눠 넣지 않음. 날짜를 넘나드는 최적화 아님(하루씩 차례로). 🧠 AI 검토는 여전히 규칙 초안(최적화 후 결과)을 보냄 — Groq 413 토큰 초과 문제는 아직 그대로

### APS — 🧠 AI 검토 (자동 생성 + Groq) (2026-10-28)
- 사용자 요청: 규칙만으로 계획을 짜는 것보다 AI가 같이 보면 더 정교해질 것 같다 → 무료인 Groq로 먼저 붙임 (Claude/GPT API는 유료)
- 구조: **규칙 초안 → AI 검토(제안) → 사람이 고름 → 규칙이 다시 계산**. AI는 계획을 직접 저장하지 않고, 시간·라인·점심 계산은 항상 `computeAutoPlan`이 함
- **`setup_aps_ai.sql`** (신규, 1회 실행): `pg_net` 확장 + `aps_secrets`(RLS, anon/authenticated 권한 회수) — Groq 키는 Supabase 안에만 저장(페이지 코드에 키 없음). RPC: `aps_ai_status`(키 유무·모델, 키 값은 안 돌려줌), `aps_ai_set_key`(빈 값 = 삭제), `aps_ai_request(hash, messages, max_tokens)` → `net.http_post`로 Groq `chat/completions`(기본 `openai/gpt-oss-120b`, JSON 모드, temperature 0.2, 90초) 요청 id 반환, `aps_ai_result(hash, id)` → `net._http_response` 조회(없으면 `{pending:true}`). 모두 `aps_assert_admin` 검사. 모델 변경은 `aps_secrets`에 `groq_model` 행
  - 비동기인 이유: Supabase anon 요청은 몇 초면 끊기므로 동기 HTTP 호출 대신 요청 id → 1.5초마다 결과 확인(최대 100초, `callAiJson`)
- **`aps.html`**:
  - `computeAutoPlan`에 `opts.aiAdj`(`{날짜:{품목id:{qty,reason}}}` — qty 0 = 그날 빼기, 계획에 없던 품목은 추가)와 `opts.aiLineOff`(`{날짜:[라인id]}` — 그날 자동계획에서 제외) 반영. 추가·변경 품목은 부족 생산 후보로 들어가 기존 배정·시간 검사를 그대로 거침(AI가 추가한 부족일 없는 품목은 후보 맨 뒤). 생산 속도 없는 품목은 "반영 불가", 빼기는 제외 목록 `🧠 AI 제안으로 제외`
  - `AiReviewPanel`(자동 생성 창 결과 위, 접기 상태 localStorage `aps-ai-open`): Groq 키 등록칸(비밀번호 입력, 🔑 키 변경) / "추가 지시" 입력(예: 내일 2라인 점검, 갈비 행사) / 🧠 AI 검토 요청 → 총평·제안 목록(수량 변경·빼기·추가·라인 쉬기, 체크로 켜고 끔)·확인할 점. 표 행에 `🧠 AI 130 → 120 · 이유`
  - `buildAiPlanInput`: 초안 행(재고·당일 예상·하루 평균·안전재고·부족일·속도), 제외 품목 최대 40개, 관련 품목 요일별 평균 판매, 기간 안 기존 계획, 근무·점심, 규칙 옵션, 사용자 지시를 JSON으로 전달. 시스템 지시에 "데이터에 없는 명절·행사·발주 지어내지 말 것, 입력에 있는 id만, 제안 10개 이하"
  - `validateAiPlan`: 기간 밖 날짜·후보에 없는 품목·없는 라인·이상한 수량은 "반영 안 함 — 이유"로 표시만. 초안과 같은 수량 제안은 버림. AI 검토 뒤에 옵션이 바뀌면 "다시 검토하세요" 경고
  - 가짜 데이터·가짜 AI 응답으로 계산(130→120, 빼기, 추가, 1라인 쉬기)과 화면 확인. **실제 Groq 호출은 미확인**(SQL 실행 + 키 등록 후 첫 사용 필요)
- **모델 종료 대응 (같은 날)**: 사용자 첫 사용 시 `AI 오류 404: The model llama-3.3-70b-versatile does not exist` — Groq가 이 모델을 2026-08-16에 종료(공식 대체 `openai/gpt-oss-120b`). 기본 모델을 `openai/gpt-oss-120b`로 변경 + SQL에 `aps_ai_models_request`(Groq `/models` 조회, pg_net GET) / `aps_ai_set_model` 추가. 페이지는 404·`model_not_found`·`model_decommissioned`를 받으면(`AiModelGoneError`) 모델 목록을 읽어 `GROQ_MODEL_PREF`(gpt-oss-120b → qwen3.8-27b → qwen3.6-27b → gpt-oss-20b) 순으로 골라 저장하고 한 번 더 요청, "모델이 종료돼 ○○로 바꿨습니다" 안내. 모델 이름 옆 "변경"으로 목록에서 직접 선택(음성·검열 모델 제외 `GROQ_NONCHAT`). max_tokens 2048 → 4096(gpt-oss는 생각 토큰도 포함)
  - **crawl.py도 같은 모델을 6곳에서 써서 8/16부터 AI 브리핑·종목 분석·테마 분석·재료 포착 코멘트가 실패했을 가능성** → `GROQ_MODEL` 상수(환경변수, 기본 `openai/gpt-oss-120b`)로 교체. 실제 크롤링 실행으로는 미확인
- **📒 공장 규칙 노트 + 📝 제안 피드백 (같은 날)**: 사용자 요청 "AI가 생산관리자처럼 학습하면서 커지면 좋겠다" → 모델 자체는 학습 안 되므로(파인튜닝은 이 규모에 부적합) **기억을 쌓고 매번 읽게** 하는 방식
  - SQL(setup_aps_ai.sql 끝에 추가, 재실행 안전): `aps_ai_notes`(content·enabled·source manual|ai) + `aps_ai_list_notes`/`aps_ai_upsert_note`/`aps_ai_delete_note`, `aps_ai_feedback`(day·kind change|line_off·item·line·rule_qty·ai_qty·accepted·created_qty·plan_id·ai_reason·user_note, 365일 보관) + `aps_ai_log_feedback(hash, rows)` / `aps_ai_list_feedback(hash, days, limit)`(만든 계획의 지금 수량·상태·actual_qty를 `aps_plans`와 조인)
  - 패널: `📒 규칙 노트 N` 버튼 → 한 줄씩 추가·수정·켜기/끄기·삭제. "AI가 함께 읽는 것: 규칙 노트 N개 · 최근 60일 뺀 제안 N건" 표시. 체크를 끈 제안 아래 "뺀 이유" 입력(`RejectNoteInput`)
  - 자동 생성 "선택 N건 생성" 때 유효한 AI 제안마다 수락 여부·뺀 이유·만든 계획 id·수량을 `aps_ai_log_feedback`으로 기록(실패해도 생성엔 영향 없음). 생성하지 않고 창을 닫으면 기록 안 됨
  - 프롬프트: `factory_rules`(켜진 노트 40개까지) + `past_feedback`(`aiFeedbackForPrompt` — 뺀 제안 20건(이유 포함) + 받아들였는데 나중에 관리자가 수량을 고친 계획 10건(실제 생산량 포함)). 시스템 지시에 "규칙 노트는 반드시 지키고, 관리자가 뺀 제안과 비슷한 건 그 이유가 해당 안 될 때만"
  - 가짜 데이터로 노트 추가 → 프롬프트 포함, 뺀 이유 입력, 생성 시 피드백 2건 기록(계획 id 포함) 확인. 실제 DB 미확인
  - 다음 단계(미구현): 🔁 주간 회고 — 쌓인 피드백을 AI가 보고 노트에 넣을 규칙을 제안, 관리자 승인 시 `source='ai'`로 저장
- 운영 순서: (1) Supabase에서 `setup_aps_ai.sql` 실행 → (2) console.groq.com에서 API 키 발급(크롤러용 GROQ_API_KEY 재사용 가능) → (3) 📅 생산계획 → 🤖 자동 생성 → 🧠 AI 검토에 키 저장 → 요청
- 한계: Groq 무료 한도(분당·일당 토큰)를 넘으면 429 안내. 품목이 매우 많으면 제외 목록은 40개까지만 보냄. 회의록·발주서·로스 데이터는 아직 AI에 안 보냄(필요하면 "추가 지시"에 적기). 나중에 Claude/GPT로 바꾸려면 `aps_ai_request`의 URL·모델만 교체

### APS — 🎉 행사 관리 + 🔮 수요 예측 머신러닝 (2026-10-28)
- 사용자 요청: 상황을 학습해 계획을 짜는 관리 AI의 1단계로 수요 예측 ML + 제품별 행사 입력 ("행사 품목 때문에 표준편차가 커진다")
- **`setup_aps_forecast.sql`** (신규, 1회 실행): `aps_promotions`(code·name·start/end_date·kind·discount_pct·uplift(예상 배수, NULL=자동)·memo·actual_uplift/actual_days(스크립트가 채움)), `aps_forecast`(date·code PK, qty·qty_lo·qty_hi(하위/상위 15%)·base(기존 요일 평균)·promo·model ml|base·run_id), `aps_forecast_runs`(실행 기록 + metrics JSONB). 모두 RLS + 정책 없음. RPC `aps_list_promotions`/`aps_upsert_promotion`/`aps_delete_promotion`/`aps_get_forecast(from,to)`/`aps_get_forecast_runs(limit)` (모두 `aps_assert_admin`). 쓰기는 GitHub Actions가 service key로 직접
- **`forecast_aps.py`** + **`.github/workflows/forecast.yml`**(매일 KST 05:30 + 수동 Run workflow, `SUPABASE_URL`/`SUPABASE_KEY` 기존 Secrets 사용, pip: requests numpy pandas lightgbm holidays):
  - 매출 업로드된 날만 학습(업로드됐는데 안 팔림 = 0, 파일 없는 날 = 제외). 최근 90일 판매 있는 상품만 예측, 마지막 매출일 다음날부터 28일
  - **평소 기준 = 행사일 + 설날·추석 2주 전~5일 뒤를 뺀 날** — 합성 데이터 시험에서 추석 대목·행사가 평소 평균을 부풀려 행사 배수가 두 번 곱해지던 문제 발견 후 도입
  - LightGBM(native API, scikit-learn 불필요) 한 모델로 전 상품 학습: 목표 = 판매 ÷ 평소 28일 평균(스케일), 가중치 = 스케일. 특징: 며칠 뒤(h), 요일, 같은 요일 평균(전체/평소), 14·28일 평균, 표준편차, 마지막 값, 최근 행사 비율, 행사 여부·며칠째·길이·할인율·종류·배수 힌트, 공휴일·전날/다음날(3일), 설날·추석까지/이후 일수(21일), 판매 기간. **상품코드·일·월은 뺌**(`FC_DROP`, 몇 달 데이터로는 외워버림 — 시험에서 확인)
  - 행사 배수 힌트 = 직접 입력 → 같은 상품 지난 행사 실제 배수 평균 → 전체 중간값. 실제 배수 = 행사 기간 판매 ÷ 행사 직전 평소 같은 요일 평균 → `aps_promotions.actual_uplift`에 기록
  - 정확도 비교: 마지막 4주를 모르는 척 1~14일 앞을 맞혀 오차율(Σ|예측−실제|÷Σ실제) — 기존(8주 요일 평균) / 행사반영 평균 / ML. 상품마다 ML과 행사반영 평균 중 더 정확한 쪽 사용(`model`). 행사 학습 데이터 30건 미만이면 행사일은 평균×배수. 매출 35일 미만·lightgbm 없음 → 행사반영 평균만(`baseline_only`)
  - 범위(qty_lo/hi) = 분위수 모델(0.15/0.85). 한 번도 업로드 안 된 요일(일요일 등)은 0. 실행 기록 60개 보관
  - 로컬 시험: `python forecast_aps.py --csv sales.csv --promos promos.csv --dry-run`
- **합성 데이터 시험 결과**(40상품 · 6/1~10/27 · 월~토 · 추석 · 행사 27건): 노이즈 작은 데이터 오차 기존 38.3% → 31.8%, 행사일 52.9% → 23.3% / 노이즈 큰 데이터 67.2% → 60.8%(행사일은 오히려 나빠짐 — 하루 4박스 수준 상품은 운이 지배). **실제 매출로는 아직 미실행**
- **aps.html**: 💰 매출 탭 보기에 `🎉 행사`(`PromotionsView` — 진행·예정/지난 필터, 실제 효과 ×N 표시, `PromoForm` 상품 검색·기간·종류 칩·할인율·예상 배수, 삭제는 그 자리 확인) / `🔮 예측`(`ForecastView` — 마지막 실행·학습 기간, 기존 vs 새 예측 오차·행사일 오차·범위 적중률 카드, 최근 실행 오차 추이, 상품×날짜 표 7/14/28일, 행사일 주황, 마우스 올리면 범위) 추가. localStorage `aps-sales-view`에 promo/forecast 허용. `.aps-label` CSS 추가
- **🤖 자동 생성 연동**: `computeAutoPlan`에 `demand={fc,promo}` — 하루 수요 = ML 예측(`demandOn`) → 없으면 요일 평균, 행사 기간이면 배수 곱함(예측에 이미 행사가 들어 있으면 안 곱함, 예측 뒤 새로 넣은 행사만 곱함, 예측엔 행사인데 행사가 삭제됐으면 요일 평균). 매출 요일 평균이 없어도 예측 있으면 후보. 옵션 "🔮 ML 수요 예측 사용"(기본 켜짐, `opts.useForecast`), 모달에 수요 기준·실행 시각·30일 행사 건수 안내, 표 "이날 N 🔮 🎉1+1". 🧠 AI 검토 입력에 `promotions`·`ml_forecast_daily_by_code` 추가 + 시스템 지시 1줄
- 브라우저(가짜 RPC)로 예측·행사 화면, 행사 저장 호출, 수요 계산, 자동 생성(예측·행사 있을 때 70/39박스, 없을 때 0) 확인. 실제 DB·Actions 실행은 미확인
- 운영 순서: (1) Supabase에서 `setup_aps_forecast.sql` 실행 → (2) 커밋·푸시 → GitHub Actions → APS 수요 예측 → Run workflow → (3) 💰 매출 → 🔮 예측에서 오차 비교 확인 → (4) 🎉 행사에 예정 행사 입력(예측은 다음 실행부터, 🤖 자동 생성은 즉시 배수 반영)
- 한계: 추석은 1번(2026-09)만 학습 — 설날·내년 추석은 그 1번에서 추정. 행사 배수를 모르는 첫 행사는 다른 상품 평균. 새벽 실행이라 매출을 올린 당일 예측엔 반영 안 됨(수동 Run workflow). 안전재고는 아직 예측 범위(qty_hi)를 쓰지 않음(다음 단계 후보)

### APS — ⚡ 생산 속도 예측 (관리 AI 2단계) (2026-10-28)
- 사용자 요청: 로드맵 2단계 — 라인 × 품목 × 출근 인원으로 시간당 생산량 예측, 인원이 적은 날은 계획 시간이 자동으로 늘게
- **`setup_aps_speed.sql`** (신규, 1회 실행, v10 전제): `aps_lines.staff_depts JSONB`(이 라인에서 일하는 👥 인원 부서, 비면 전체 출근 인원) + `aps_list_lines` 재정의(staff_depts 포함) + `aps_set_line_staff_depts(hash, line_id, depts)`
- **모델은 화면에서 바로 계산** (실적이 수십~수백 건이라 서버·새벽 작업 불필요): `fitSpeedModel` — 완료 계획(`aps_get_done_plans_all`) 실제 시작·종료·수량(actual_qty 우선), 작업 시간 = 종료−시작−점심 겹침. `log(시간당) = 기본 + 품목 + 라인 + β·log(출근 ÷ 라인 평소 인원) + γ·log(수량 ÷ 품목 평소 수량)` 가중(작업 시간, 8h 상한) 릿지 회귀(λ 품목 0.5 / 라인 3 / 인원·수량 0.3, 가우스 소거). β는 0~1.5, γ는 −0.5~0.5로 제한(데이터 부족 시 "인원 줄면 빨라짐" 방지). 같은 품목 중간 속도의 4배 이상 차이 나는 실적은 버튼 누르기를 잊은 것으로 보고 제외
  - 출근 인원 = 활성 직원(라인 담당 부서만) − 그날 휴무(`aps_get_attendance_range`). 퇴사 직원(비활성)은 과거에도 없던 것으로 봄
  - 시험: 최근 25% 실적(최소 5건)을 맞혀 작업 시간 오차(Σ|예측−실제|÷Σ실제)를 기존 방식(품목 Σ수량÷Σ(종료−시작) 후 점심 더함 = 계획 추가 화면과 같음)과 비교 → **모델이 같거나 나을 때만 `use`**. 실적 20건 미만이면 분석 안 함
  - `loadSpeedModel(adminHash, settings, force)` 5분 캐시, ▶/✓ 상태 변경·실적 수정 시 `invalidateSpeedModel()`
- **화면**: 📈 통계 → `⚡ 속도 분석`(`SpeedView` — 기존 vs 모델 오차, "출근 1명 줄면 N% 느려짐", "한 번에 2배 만들면 시간당 +N%", 라인별 평균 대비 속도·평소 인원·인원 기준, 품목별 기존(점심 포함) vs 모델 시간당, 휴무 기록·부서 미지정 안내, ↻ 다시 계산). 🏭 라인 탭에 "인원 부서" 칩 열(👥 인원 부서가 있을 때만, SQL 미실행이면 안내)
- **연결**: `PlanForm` 종료 시각 자동 계산 — 모델 사용 중이면 선택한 라인·시작일 출근 인원·수량으로 속도(`⚡ 속도 모델 · 2라인 · 출근 8명`), 아니면 기존 통계 속도. `computeAutoPlan`에 `speed` — 후보 속도는 첫 허용 라인 기준, `place()`에서 고른 라인·그날·수량 속도로 시간 계산(순서 재계산도 그 속도), 표에 `속도 모델 · 출근 N명`. 모달 안내 줄에 작업 시간 기준 표시
- 합성 실적 시험(8~12품목·3라인·24명·휴무 15%·실제 β 0.8): 150건 오차 20.0% → 10.7%(β 0.69 추정), 60건 28.6% → 17.4%, 실제 인원 효과 0일 때 β −0.06(≈0), 25건은 모델이 더 나빠 자동으로 미사용. 브라우저(가짜 RPC)로 속도 분석 화면, 라인 부서 저장 호출, 계획 추가 속도 표시, 자동 생성 라인별 시간 확인. 실제 DB 미확인
- 한계: 인원 효과는 👥 인원 탭에 휴무를 꾸준히 체크해야 배움. 라인 속도 차이는 품목 구성이 비슷해야 정확(특정 품목만 하는 라인은 품목 효과와 섞임). 작업자 숙련도·기계 상태·시간대(오후 피로)는 반영 안 함. 자동 생성의 라인 선택은 여전히 "가장 빨리 시작하는 라인" 기준(빠른 라인 우선 아님)

### APS — 생산계획 추가 시 종료 시각 자동 계산 (2026-10-28)
- 사용자 요청: 계획 잡을 때 통계·시간당 생산량을 참고해 시간도 입력되게
- `PlanForm`: 마운트 시 `aps_get_item_stats`(180일 + 전체) 조회 → 품목 시간당 생산량 = 최근 180일 실적 → 전체 실적 → 품목 `units_per_hour` 순(🤖 자동 생성과 같은 기준)
- 종료 시각 = 시작 + 수량 ÷ 시간당 생산량(15분 단위 올림, 최소 15분), 점심 시작 전에 시작해 점심을 넘기면 점심 길이만큼 더함
- 시간 칸 아래 안내: `⏱ 시간당 N박스 (최근 180일 실적 5건) → 약 2시간 30분 + 🍱 점심` + "종료 시각 자동 계산" 체크(새 계획은 켜짐, 수정은 꺼짐). 켜져 있으면 품목·수량·시작 시각을 바꿀 때마다 종료가 다시 계산되고, 종료 시각을 직접 고치면 꺼짐 → "계산한 종료 시각 … [이걸로]" 표시. 속도 정보가 없으면 직접 입력 안내
- 가짜 데이터로 확인(100박스 ÷ 40/h, 11:00 시작 → 14:30). SQL 변경 없음
- 한계: 근무 종료 시각을 넘어도 막지 않음(다음 날로 넘김 처리 없음). 라인별 속도 차이는 반영 안 함

### APS — ▲▼ 순서 바꾸면 시간도 맞바꿈 (2026-10-28)
- 사용자 요청: 리스트의 순서 바꾸기 버튼으로 순서를 바꾸면 시간도 같이 바뀌게
- `swapPlanTimes(a,b,settings)`: 화면에서 바로 위/아래 계획과 시간 자리를 바꿈 — 앞 시각에 시작하던 계획 자리에 다른 계획이 들어가고, 그 뒤에 원래 앞 계획이 옴. 각자 **작업 시간(점심 제외)**과 두 계획 사이 간격은 유지하고 점심은 다시 피해서 계산(예: A 08~10, B 10~11 → B 08~09, A 09~11)
- 조건: 둘 다 '계획' 상태 + 같은 날(KST) 시작. 진행중·완료·취소가 끼거나 날짜가 다르면 기존처럼 순서만 바뀜
- `movePlan(p, direction, neighbor)`: `aps_move_plan_order` 후 `aps_upsert_plan` 2번. 리스트 위에 "▲▼ 순서 바꾸면 시간도 함께 바꾸기" 체크(기본 켜짐, localStorage `aps-swap-times`)
- 노드로 계산 확인(점심 걸침·간격 포함). SQL 변경 없음
- 한계: 바꾼 두 계획 외 나머지 계획은 안 밀림(겹칠 수 있음). 서버 순서 swap은 필터에 가려진 계획까지 포함한 인접 행 기준이라, 날짜·상태 필터로 숨겨진 계획이 사이에 있으면 화면상 이웃과 다를 수 있음(기존 동작)

### APS — ⏩ 빈 시간 자동 당기기 (2026-10-28)
- 사용자 요청: A 08~10, B 10~11일 때 A를 지우면 B가 08시부터 시작하도록. 추가·삭제·자동 생성 모두 항상 유연하게
- `repackLineDay(plans, lineId, day, settings, focusId)`: 한 라인·한 날짜(시작일 기준)의 '계획' 상태 계획을 시작 순서대로 빈틈 없이 이어 붙임. 각 계획의 작업 시간(점심 제외) 유지, 점심은 다시 피함, 진행중·완료·전날부터 이어지는 계획은 그대로 두고 그 시간을 피함. 시작 = 근무 시작(오늘이면 지금 이후 15분 올림, 단 첫 계획이 그보다 이르면 그 시각 유지). 지난 날짜·라인 미지정은 안 건드림. 시작이 같으면 focusId(방금 옮긴 계획)가 앞
- `PlansTab.repackKeys(keys, focusId)`: 저장 후 `aps_list_plans`를 다시 읽어 바뀌는 계획만 `aps_upsert_plan`. 연결: 삭제 / 취소 상태 변경 / 계획 추가·수정(이전·새 라인·날짜 둘 다) / 간트 드래그 / ▲▼ 시간 맞바꾸기 / 🤖 자동 생성 후(만든 라인·날짜)
- `PlanForm`: 새 계획은 라인을 고르면 그 라인 그날 마지막 계획 뒤로 시작 시각 자동(시작 시각을 직접 고치면 멈춤) → 끝에 붙음
- 툴바(날짜 줄 오른쪽): "⏩ 빈 시간 자동 당기기" 체크(기본 켜짐, localStorage `aps-auto-pack`) + "⏩ 지금 당기기"(선택한 날짜 전체 라인, 전체 날짜 모드면 오늘 이후 전체 — 체크가 꺼져 있어도 동작)
- 노드로 계산 확인(삭제 후 당김, 점심 걸침, 완료 계획 피하기), JSX 컴파일 확인. 실제 화면 클릭 확인은 못 함(미리보기 브라우저가 로컬 서버 접속 실패). SQL 변경 없음
- 한계: 일부러 비워 둔 시간도 당겨짐(필요하면 체크 끄기). 자동 생성 창의 미리보기 시간은 당기기 전 기준. 근무 종료를 넘어도 다음 날로 넘기지 않음

### APS — 점심시간 설정 (2026-10-15)
- 사용자 요청: 점심시간을 지정해서 생산 시간에서 빼고 싶다
- `aps_settings`에 `lunch_start` / `lunch_end` ("HH:MM", 빈 값 = 점심 없음) — 기존 `aps_set_setting`/`aps_get_settings` 재사용, SQL 변경 없음
- **SettingsModal**(⚙ 근무시간): "🍱 점심 시작/종료" time 입력(15분 단위) + "점심 없음" 버튼. 둘 다 입력 or 둘 다 비우기, 종료 > 시작, 근무시간 안이어야 저장
- 헬퍼 `parseHHMM` / `getLunch(settings)` → `{s,e,label}`(시 소수) 또는 null
- **🤖 자동 생성**: 라인 커서가 점심 안이면 점심 끝으로 이동, 점심에 걸치는 작업은 종료가 점심 길이만큼 늦어짐, 근무 종료 초과 시 "들어갈 수 있는 수량"도 점심을 뺀 실제 작업 시간으로 계산. 시간 칸에 "🍱 점심 제외" 표시, 모달 상단 근무 정보에 점심 표기
- **간트**: 점심 구간 주황 빗금 음영 + 헤더 "🍱 점심" 라벨(클릭 방해 없음). **시간표**: 점심 시간 행 라벨에 "🍱 점심" + 빈 칸 빗금
- 한계: 수동으로 만든 계획이나 간트 드래그는 점심을 자동으로 피하지 않음(표시만). 점심은 하루 1구간만

### APS — 재고시트 제품 마스터 목록 Supabase 동기화 (2026-08-11)
- 사용자 보고: "재고시트탭에서 제품 목록 편집하고 저장하면 바뀌긴 하는데 제품파일을 다시 업로드하면 원래대로 돌아옴"
- 원인: 제품 마스터 목록(`template`)만 localStorage(`aps-inv-template`) 전용이고 Supabase payload(products/raws/prodName/rawName/title/dateLabel)에는 미포함 → 기기·브라우저가 바뀌거나 스토리지가 비워지면(iOS Safari 7일 스토리지 정리 포함) 코드에 박힌 `DEFAULT_PRODUCT_TEMPLATE`(37개)로 복귀. 추가로 마운트마다 기본 목록을 localStorage에 덮어쓰는 effect가 있어 "이 기기에 저장한 적 없음" 상태를 구분할 수 없었음
- **변경 1 — 목록 저장 헬퍼 신설** ([aps.html:4088](aps.html:4088)): `loadStoredTemplate()`(없으면 `null` 반환 — 빈 배열과 구분) / `saveStoredTemplate(tpl)`(저장 + `aps-inv-data-change` 이벤트 발행)
- **변경 2 — payload에 `template` 포함**: `_normalizeRemoteInv`에 `template` 필드 추가(구버전 payload는 `null`), `saveRemoteInventory`가 항상 목록을 실어 보냄. payload는 통째로 교체되므로, 이 기기에 목록이 없으면 `loadRemoteInventory`로 서버 목록을 먼저 읽어 그대로 재전송해 보존
- **변경 3 — `adoptRemoteTemplate(remote, localTs, remoteTs)`**: 이 기기에 저장된 목록이 없으면 무조건 원격 채택, 있으면 원격이 더 최신일 때만 채택. `InventorySheetTab` + `InventoryQuickPanel` 마운트 동기화에 연결
- **변경 4 — 기본 목록 자동 저장 제거**: `useState(loadStoredTemplate()||DEFAULT_PRODUCT_TEMPLATE)`로 초기화만 하고 localStorage에는 쓰지 않음(기존 `useEffect([template])` 삭제). 실제 저장은 `saveTemplate`/원격 채택 시점에만
- **변경 5 — `saveTemplate` 원격 push**: 목록 저장 시 `saveRemoteInventory({template})` 호출 + 동기화 뱃지 갱신. `clearAll`(업로드 초기화)은 원격 row 삭제 후 로컬 목록을 다시 push해 목록만 보존
- SQL 변경 없음 (`aps_inventory_sheet.payload`가 free-form JSONB)
- **적용 후 1회 필요**: 올바른 목록을 가진 기기에서 📝 제품 목록 편집 → 저장(또는 파일 업로드) 1회 → 서버에 목록이 시드됨. 이후 다른 기기는 접속 시 자동 채택
- 한계: 두 기기에서 동시에 목록을 편집하면 마지막 저장이 이김(last-write-wins, 재고 시트와 동일 정책)

### APS — 재고시트 제품 목록이 다시 원래대로 돌아가던 문제 (2026-10-20)
- 사용자 보고: "재고시트 제품목록 편집하면 자꾸 원래대로 돌아간다"
- 원인: (1) 목록(template)에 자체 편집 시각이 없어 채택 여부를 **재고 시트 저장 시각**(`savedAt`/`updated_at`)으로 판단 (2) `saveRemoteInventory`가 모든 저장(업로드·제목/날짜 변경)마다 그 기기의 localStorage 목록을 실어 보냄 (3) 재고시트 탭을 열 때마다 제목/날짜 effect가 돌아 오늘 날짜로 `savedAt`을 갱신하고 600ms 뒤 서버에 push → 옛 목록을 가진 기기(예: 모바일)가 탭을 열기만 해도 서버 목록을 옛 것으로 덮고 서버 시각이 최신이 되어, 편집한 기기도 다음 접속 때 옛 목록을 채택
- 변경:
  - `TEMPLATE_AT_KEY`(`aps-inv-template-at`) — 목록 편집 시각(ms). `saveStoredTemplate(tpl, at)`, `loadStoredTemplateAt()`
  - 원격 payload에 `templateAt`(ISO) 추가, `_normalizeRemoteInv`가 `templateAt` 파싱
  - `adoptRemoteTemplate(remote)`: 이 기기에 목록이 없거나 **원격 templateAt > 로컬 templateAt**일 때만 채택(채택 시 원격 시각도 저장)
  - `saveRemoteInventory`: 목록을 직접 넘긴 저장(편집)만 목록을 교체. 그 외 저장은 서버 목록을 다시 읽어 로컬 목록이 더 최신일 때만 로컬 것을, 아니면 서버 것을 그대로 보존
  - `saveTemplate`: `at=Date.now()`로 로컬·원격 함께 저장
  - 재고시트 탭의 제목/날짜 저장 effect는 첫 실행(탭 열기)에서는 건너뜀
- 노드 시뮬레이션(두 기기): A 편집 → B 업로드해도 서버 목록 유지, B는 새 목록 채택
- 적용 후 1회: 올바른 목록이 있는 기기에서 📝 제품 목록 편집 → 저장 1번 (기존 목록엔 편집 시각이 없어 그 저장이 기준이 됨)

### 이슈 종목 탭 → 재료 포착 TOP 10 전면 교체 (2026-08-13)
- 사용자 요청: `종목 top10 탭.txt` 프롬프트("좋은 재료가 났는데 아직 주가에 덜 반영된 종목 TOP 10")를 이슈 종목 탭에 그대로 구현
- 기존: `crawl_issue_stocks()`의 복합 점수(거래대금 50 + 등락률 10 + 테마 10 + 뉴스 10 + 섹터 10 + 상한가 10) → 사실상 "오늘 많이 오르고 많이 거래된 종목". 재료의 실체·신뢰도·미반영 여부를 판정하지 않음
- 변경: 별도 파이프라인 `crawl_catalyst_stocks()` 신설. `issue_stocks`는 그대로 유지(시장 개요 TOP 5 + analysis.html이 계속 사용)하고, **탭 화면만** 신규 `catalyst_stocks`를 렌더
- **`setup_catalyst.sql`** (신규, 1회 실행): `catalyst_stocks` 테이블 38컬럼 + 인덱스 3종 + RLS(anon SELECT)
- **DART OpenAPI 연동** (`DART_API_KEY` env, 미설정 시 뉴스만으로 graceful degradation):
  - `fetch_dart_disclosures(days_back=5)`: `list.json`을 `pblntf_ty=B`(주요사항보고)/`I`(거래소공시) × `corp_cls=Y`/`K`로 bulk 조회(페이지당 100건, 최대 30페이지, 0.12초 간격). 정기공시·지분공시·감사보고서는 애초에 미조회
  - `classify_dart_report()`: `DART_MATERIAL_TYPES` 23종 매핑(공급계약 25점 ~ 전환사채 9점 / 지속성 4~15점). `[기재정정]`은 신규 재료가 아니므로 ×0.6 감점
  - 반환: `{stock_code: [{type, title, credibility, persistence, date, url, days_ago}]}`
- **지표 계산**:
  - `load_price_history()`: `daily_prices`(낙폭 탭용으로 이미 60일 누적 중)에서 종가+거래대금 페이지네이션 로드
  - `compute_price_metrics()`: 1일/5일/20일 수익률 + 20일 평균 거래대금 대비 배수. `save_daily_close` 직후 호출되므로 오늘 행은 제외하고 계산
  - `fetch_investor_trend_multi()`: 기존 `fetch_investor_trend`의 5거래일 합산판(`pageSize=5`, 일별 `closePrice`로 억원 환산)
  - `parse_amount_eok()`: 계약 규모를 억원으로 추출(`1조 2,000억`/`3,500억원`/`2억 달러`/`5000만 달러`). USD는 당일 USD/KRW 지수로 환산. **못 찾으면 0 = 미확인** — 추정치를 만들지 않음. 시총의 20배 초과 값은 오인식으로 폐기
- **스코어링 100점** (프롬프트 배점 그대로): 뉴스 질·신뢰도 25 + 기업가치 영향 25 + 주가 미반영 20 + 거래대금 8·수급 7 + 추가 모멘텀 15
  - 후보: 시총 3,000억+ / ETF 제외 / **섹터 중립**(기존 상승섹터 가점 삭제) → (a) DART 재료성 공시 보유 전부 + (b) 거래대금 평소 2배↑ & 300억+ 급증 종목, 합계 최대 140개
  - 재료 확정: 공시 우선(원출처) → 없으면 `NEWS_MATERIAL_KEYWORDS` 12종으로 뉴스 판정(신뢰도 상한 12점). 언론사 등급(`NEWS_SOURCE_TIER`) 가중, `특징주/급등주/수혜주` 등 시세 반응 기사는 ×0.6
  - 재료 없는 종목은 아예 제외 — 이 탭의 목적이 "재료 보유 종목"이므로
  - 미반영 점수: `max(1일, 5일)` 수익률 기준 30%↑=0점 / 20%↑=4 / 12%↑=9 / 6%↑=14 / 0%↑=18 / 하락=20. 20일 수익률 60%↑면 추가 -5
  - 2패스: 1차 점수(85점)로 상위 30개만 수급 조회 → 수급 7점 더해 최종 재정렬 → TOP 10
- **`generate_catalyst_commentary()`**: Groq로 종목당 3문장(`why_now`/`catalyst_impact`/`priced_in`). 프롬프트에 "제공된 데이터에 없는 계약금액·고객사·임상 단계·목표주가 생성 금지", "규모 미확인이면 '규모 미공개'로 쓸 것" 절대 규칙. 실패해도 표는 정상 표시(빈 문자열)
- **`main()` 통합**: `ai_mode == "close"`(15:35/16:00)에서만 실행 — DART/뉴스 API 비용 + 확정 종가 필요. 당일 이미 산출됐으면 스킵. 저장은 `DELETE date=eq.TODAY` 후 INSERT(과거 보존), 90일 초과 cleanup
- **`index.html`**:
  - 탭 라벨 "이슈 종목" → "**재료 포착**" (해시 `#issues`는 유지 — 기존 공유 링크 호환)
  - `TabStocks` 전면 재작성: 8컬럼 표(순위/종목·섹터·시총/현재가/1일·5일/핵심 재료/규모/외인·기관/종합점수) + 행 클릭 시 재료 원문 카드(원출처 링크) → 점수 5축 바 → AI 3문장 → 보조 지표 5종 → 최근 공시 → 관련 뉴스
  - 갱신 시각 뱃지(`date + generated_time`), 목적 설명 인트로, 면책 고지 추가
  - 구 `TabStocks`(3축 분석 + 자금 흐름 위젯) 160줄 삭제, 그와 함께만 쓰이던 `stkAn` state + `stock_analysis` 폴링 쿼리 제거(폴링당 Supabase 쿼리 1개 절감). `analysis.html`은 `stock_analysis`를 독자적으로 읽으므로 영향 없음
  - CSS: 죽은 `.stock-*` 반응형 규칙을 `.cat-*`로 교체(index.html 인라인 + style.css 양쪽). 모바일은 4행 카드 레이아웃, 규모 셀에 `::before`로 "규모" 라벨
  - SEO fallback/`<noscript>`/meta description의 "이슈 종목 TOP 15" 문구도 갱신
- **부수 수정**: `crawl.py`에 `import time` 추가 — line 326의 Supabase 재시도 `time.sleep(wait)`가 import 없이 호출되던 잠복 NameError
- **운영 순서**: (1) [opendart.fss.or.kr](https://opendart.fss.or.kr) 가입 → 인증키 발급 → GitHub Secrets에 `DART_API_KEY` 등록 → (2) Supabase에서 `setup_catalyst.sql` 실행 → (3) 다음 close 모드(15:35) 크롤링부터 자동 채워짐
- **즉시 실행 수단 2가지** (마감 시간까지 기다리지 않고 확인):
  - `FORCE_CATALYST` env — truthy면 `ai_mode != "close"`여도 강제 산출 + 당일 중복 스킵도 무시. `crawl.yml`의 `workflow_dispatch.inputs.force_catalyst`(boolean) → `env: FORCE_CATALYST: ${{ inputs.force_catalyst }}`로 연결. 예약 실행 시에는 빈 문자열이라 자연히 false
  - **`test_catalyst.py`** (신규) — Supabase에 쓰지 않는 로컬 드라이런. 크롤링 전체를 돌리지 않고 시세 조회 → 재료 포착만 실행해 콘솔에 TOP N 출력. `SUPABASE_KEY` 없으면 공개 anon 키로 자동 폴백(`daily_prices`는 anon SELECT 허용). 옵션 `--top N`, `--no-flow`(수급 조회 생략). 스코어링 튜닝용
- **실측 성능** (2026-08-13 드라이런): 시총 3000억+ 기본 조건 통과 682종목 / `load_price_history` + 682종목 지표 계산 33초 / 섹터 매핑 캐시 미스 시 65초 추가
- **한계**: (1) Groq에 웹 검색이 없어 "원출처 직접 확인"은 DART API로만 충족 — 키가 없으면 뉴스 키워드 추정으로 격하됨. (2) 5분 실시간 갱신 불가(장 마감 후 1회). (3) DART `report_nm`에는 계약금액이 없어 규모는 뉴스 제목·요약에서만 추출 → 상당수가 "미공개"로 표시됨(의도된 동작). (4) 수급 점수는 상위 30개만 조회하므로 31위 밖 종목은 수급 0점으로 최종 순위가 소폭 보수적

### 재료 포착 성과 추적 (catalyst_track) (2026-08-13)
- 사용자 요청: "재료포착 탭 종목들을 데이터로 저장해서, 그날부터 매수했으면 실적이 어떤지 확인하고 싶다"
- 기존: `catalyst_stocks`는 이미 날짜별로 저장되고 있었으나(90일 보존) **선정 이후 주가가 어떻게 됐는지 추적하는 레이어가 없음** → 과거 추천의 적중률을 알 수 없었음
- **`setup_catalyst_track.sql`** (신규, 1회 실행): `catalyst_track` 테이블
  - 편입 스냅샷(불변): `pick_date`, `code`, `name`, `market`, `display_sector`, `rank`, `total_score`, `catalyst_type`, `catalyst_source`, `catalyst_amount`, `entry_price`(선정일 종가 = 가상 매수단가)
  - 추적 상태(매 거래일 갱신): `last_price`, `last_date`, `days_tracked`, `ret_cum`, `ret_d1`/`ret_d5`/`ret_d10`/`ret_d20`(도달 전 NULL), `max_price`/`min_price`/`max_ret`/`min_ret`(최대 낙폭), `status`(open|closed), `updated_at`
  - `UNIQUE(pick_date, code)` — 같은 날 재실행해도 중복 편입 안 됨. RLS anon SELECT 허용
- **crawl.py 상수**: `CATALYST_TRACK_MAX_DAYS=20`(추적 거래일), `CATALYST_TRACK_HORIZONS={1:"ret_d1",5:"ret_d5",10:"ret_d10",20:"ret_d20"}`, `CATALYST_TRACK_KEEP_DAYS=365`
- **`seed_catalyst_track(catalysts)`**: 재료 포착 저장 직후 호출. `entry_price = 당일 종가`. `DELETE pick_date=eq.TODAY` 선행으로 재실행 안전. 가격 0인 종목은 편입 제외
- **`update_catalyst_track(krx_data)`**: close 모드에서 **오늘 신규 편입 전에** 먼저 호출 → `status=eq.open & last_date=neq.TODAY` 인 행만 GET(최대 500) → `days_tracked+1`, 누적/최고/최저 수익률 갱신, D+1/5/10/20 도달 시 그 시점 수익률 확정 기록, 20거래일 경과 시 `status='closed'`. 행별 PATCH(최대 200건). krx_data에 시세 없는 종목(거래정지 등)은 skip
- **거래일 카운트**: close 모드가 거래일마다 1회 도는 것을 이용해 `days_tracked`를 증가시키고, `last_date != TODAY` 가드로 중복 증가를 막음. 크롤링이 하루 실패하면 그날은 카운트되지 않아 D+N이 실제 달력보다 하루씩 밀릴 수 있음(허용 오차)
- **보존 기간 변경**: `catalyst_stocks` 90일 → **365일**, `catalyst_track` 365일 (성과 이력을 남겨야 하므로). `oversold_stocks`는 90일 유지
- **index.html `TabStocks` 뷰 토글**: `◆ 오늘의 재료 포착` / `📈 성과 추적` segmented 버튼 (`view` state)
  - 신규 `CatalystTrack` 컴포넌트 — 마운트 시에만 `db("catalyst_track","order=pick_date.desc,rank.asc&limit=1000")` **lazy fetch** → 90초 폴링 루프에 쿼리를 추가하지 않음
  - 요약 카드 5개: 추적 종목 / 평균 수익률(현재) / 승률 / 최고 / 최저
  - `📐 보유 기간별 성적`: D+1·D+5·D+10·D+20·현재 각각 평균 수익률 + 승률 + 표본 수. 해당 구간에 **도달한 종목만** 집계 (미도달은 "아직 미도달")
  - `🗓 선정일별 성적`: 날짜별 접기/펼치기 카드 → 펼치면 종목 표(순위/종목·재료/진입가/현재가/누적/D+1·5·10·20/최고·최저). 종목명 클릭 시 네이버 증권
  - 종목 검색(이름·코드·재료유형·섹터), 면책 고지 포함
  - 테이블 미존재/네트워크 실패 시 `db()`가 null 반환 → "catalyst_track 테이블을 확인하세요" empty state로 graceful degradation
  - CSS: `.cat-trk-stats`(모바일 2열), `.cat-trk-horizon`(모바일 3열 wrap), `.cat-trk-row` — index.html 인라인 + style.css 양쪽. 넓은 표는 `overflow-x:auto` 컨테이너 안에서만 스크롤(페이지 가로 스크롤 없음)
- **운영 순서**: (1) Supabase에서 `setup_catalyst_track.sql` 실행 → (2) 다음 close 모드(15:35)부터 그날 TOP 10이 자동 편입 → (3) 그 다음 거래일부터 수익률 누적. D+1은 하루 뒤, D+20은 약 한 달 뒤에 채워짐
- **한계**: (1) 소급 적용 불가 — 이미 지난 추천은 진입가 스냅샷이 없으므로 SQL 실행 시점 이후 선정분부터 쌓임. (2) 수수료·세금·슬리피지·실제 체결가 미반영(선정일 종가 기준 단순 가격 수익률). (3) 코스피 대비 초과수익(벤치마크) 미계산. (4) 20거래일 이후는 마감되어 장기 성과는 추적하지 않음

### 자동 리스트 생성기 (orders.html) (2026-10-13)
- 사용자 요청: 발주서(쿠팡 ERP 엑셀) 업로드 → 제품리스트 참고해 **부착리스트(엑셀) + 적재이미지(PNG)** 자동 생성. APS와 같은 관리자 인증을 쓰는 독립 페이지
- **`setup_orders.sql`** (신규, 1회 실행, `setup_aps.sql`의 `aps_assert_admin` 재사용): 테이블 5개 `ol_box_specs` / `ol_load_methods` / `ol_products` / `ol_orders`(order_no UNIQUE) / `ol_order_items`(CASCADE). RLS + 정책 없음 → RPC만. 기본 적재방식 2개 시드(단독 40박스 / 혼적 가능 40)
  - RPC: `ol_list_masters`, `ol_upsert_product`/`ol_delete_product`, `ol_add_box_spec`/`ol_delete_box_spec`, `ol_upsert_method`/`ol_delete_method`(제품 method_ids에서도 제거), `ol_list_orders(from,to)`, `ol_list_due_dates`, `ol_save_order`(같은 발주번호면 통째로 교체), `ol_delete_order`
- **탭 3개** (URL 해시 `#products`/`#orders`/`#lists`):
  - 📦 제품리스트: 코드/제품명/이미지용 제품명/입수량/적재방식(다중 체크)/생산지점(datalist)/박스규격(드롭박스, `가로×세로×높이`)/표시색상(프리셋+피커). 박스규격·적재방식 관리 모달
  - 📄 발주서: 다중 파일 업로드, 입고예정일 날짜 목록 + 생산지점 필터, 발주서별 카드 + 개별 삭제. **미등록 상품코드는 업로드 결과 모달 + 상단 빨강 배너 + 행 강조**로 표시, 배너에서 바로 "+ 제품 등록"
  - 🗂 발주리스트: 날짜 → 생산지점 칩 → 🏷 부착리스트 / 🖼 적재이미지 서브탭. 제목 머리말("쿠팡") 편집 가능(localStorage `ol-prefix`)
- **발주서 파싱** (`parseOrderWorkbook`): C5 업체명(앞 `[코드]` 제거) / C10 발주번호 / F13 입고예정일 / C13 물류센터 고정 셀 우선, 비면 라벨 검색. 상품 표는 "상품코드" 헤더 행에서 컬럼 자동 탐지, 업체납품가능수량(H, 헤더 "납품가능" 포함 열) 사용 — 2026-10-21 발주수량(G)에서 변경, 소비기한 = 제조/유통 컬럼의 **다음 행**(U23 등)
- **파렛트 계산** (`buildPallets`): 박스 = 발주수량÷입수량(나머지 있으면 올림+⚠). 단독 방식 최대 박스로 꽉 찬 파렛트 → 자투리는 혼적 방식 있으면 혼적 풀(여러 제품 한 파렛트), 없으면 단독 1파렛트. 혼적 풀에 한 제품만 남으면 단독 취급. 적재방식 미지정 제품은 40박스 단독
  - 예시 발주서(584/720/624/80개, 입수 8)로 검증 → 7파렛트, 예시 부착리스트·적재이미지와 동일(1:40, 2:33, 3-4:보쌈40×2, 5:40, 6:38, 7: 혼적 10+10 → 3·3·4칸)
- **부착리스트 엑셀**: `xlsx-js-style@1.2.0`(SheetJS 0.18.5 포크, 읽기+스타일 쓰기)로 템플릿 재현 — 파렛트 1개 = 시트 1개, A3 `총 파렛트 수 - 번호`(예: `16 - 1`, 텍스트 셀 — 2026-10-14 `/` → ` - `로 변경, 미리보기도 동일. 적재이미지의 `7/3-4` 표기는 그대로), E3 `SUM`, E9 `D9*입수` 수식, 노랑 제목/테두리/Pretendard. 파일명 `부착리스트_{날짜}_{지점}.xlsx`. 같은 날·같은 지점에 발주서가 여러 개면 시트명 `{발주순번}-{파렛트}`
- **적재이미지**: 발주서×생산지점별 1장, "7/3-4" 연속 동일 파렛트 묶기, 혼적은 표(제품 1줄 = 칸 수로 분할), 제품 색상 적용. html2canvas PNG 저장
- 생산지점은 저장하지 않고 조회 시 제품리스트와 매칭 → 나중에 제품 등록하면 기존 발주서에도 바로 반영
- **운영 순서**: Supabase에서 `setup_orders.sql` 실행 → `orders.html` 접속(관리자 비밀번호) → 제품 등록 → 발주서 업로드
- 한계: 박스규격은 저장·표시만(파렛트 용량 자동 계산에는 미사용 — 적재방식의 최대 박스 수로 결정). 업로드 시 업체납품가능수량(H) 기준 (2026-10-21 변경, 이전엔 발주수량 G)
- **박스규격 규격명 (2026-10-13 추가)**: `ol_box_specs.name` 컬럼(`ADD COLUMN IF NOT EXISTS`), `ol_add_box_spec(hash, spec, name)` 3인자로 교체(기존 2인자 DROP) — 같은 치수가 있으면 `ON CONFLICT DO UPDATE`로 규격명만 갱신 → "이름 수정"도 이 RPC 사용. 제품은 여전히 `box_spec`에 치수 문자열을 저장하고, 표시할 때 `specLabel()`로 `규격명 (가로×세로×높이)`. 관리 모달에 규격명 입력 + 행별 이름 수정 추가
- **적재이미지 글씨 크기 조절 (2026-10-14 추가)**: 편집 모드에 크기 툴바 — 글씨 **클릭 = 선택**(주황 테두리, 더블클릭은 기존대로 글씨 수정) → "선택한 글씨 A−/A+"(±2px, 8~120px, "기본"으로 개별 크기 해제) / "전체 글씨 A−/A+"(±10%, 50~200%). 편집 저장값에 `size:{글씨id:px}`, `scale:%` 추가(기존 `ol_settings` `img:*` 키, SQL 변경 없음). `EditText`가 `base`(기본 px: 제목 28 / 총파렛 46 / 부제 13 / 단독 21 / 혼적 라벨 16 / 혼적 칸 17)를 받아 `(size[id] ?? base) × scale/100`으로 렌더, `data-tid`/`data-base` 속성으로 선택 글씨의 기본값 조회. "↺ 원래대로"는 크기까지 초기화
- **적재이미지 드래그 크기 조절 + 정렬 스냅 (2026-10-14 추가)**:
  - 블록(점선 상자) 오른쪽 아래 시안 ■ 핸들을 끌면 블록 안 글씨 전체를 같은 비율로 크기 조절, 선택한 글씨(주황 테두리) 모서리 ■은 그 글씨만. 오른쪽·아래로 끌면 커짐(비율 = (요소 높이 + 끈 거리)/요소 높이), 8~120px. 끄는 동안은 `live` state로 미리보기, 놓을 때 `ed.size`에 저장(`startScaleDrag`). A−/A+ 버튼은 그대로
  - 블록 이동 시 다른 블록의 왼쪽·가운데·오른쪽 / 위·가운데·아래 선, 이미지 가로 중앙과 6px(`SNAP_PX`) 이내면 붙고 분홍 안내선 표시. Alt 누르고 끌면 스냅 끔. 블록에 `data-bid`, 이미지 루트에 `data-imgroot`(position:relative)
  - `EditText`는 `width:fit-content` + 좌우 auto 마진으로 글씨 크기만큼만 차지(가운데 정렬 유지, 선택 테두리·핸들이 글씨 옆에 붙음). 헤더(flex) 안 제목/총파렛은 마진 0으로 덮어씀
  - `DragBlock`(점선 상자)도 `width:fit-content` + 좌우 auto 마진 → 상자가 그리드 칸/전체 폭이 아니라 글씨 범위에만 맞음(위치는 그대로 가운데). 스냅 기준선도 글씨 범위 기준이 되어 정렬이 더 정확해짐
  - 혼적 표의 칸 크기(132×128)는 고정 — 글씨만 커짐- **자투리 최대한 혼적 (2026-10-14 변경, 기존 FFD 자리 기반 혼적 대체)**: `buildPallets` → 단독 최대로 꽉 찬 파렛트를 뺀 자투리를 `mergePool`로 합침. 혼적 파렛트 수 = ⌈자투리 합 ÷ 혼적 1파렛트 최대(1자리 최대 × 6방)⌉, 파렛트끼리 고르게(`pourBalanced` — `layoutMixed`와 같은 함수, 묶음 크기 ⌊합÷n⌋/⌈합÷n⌉, 제품이 두 파렛트에 나뉘는 경우 최소화). 제품 하나가 두 혼적 파렛트에 나뉠 수 있음
  - 혼적 1파렛트보다 큰 자투리(예: 35)는 (가) 단독 유지 + 작은 것만 혼적 / (나) 전부 혼적 두 안을 비교 → 파렛트 수 적은 쪽 → 같으면 "상품 1개 소량 파렛트(혼적 최대의 절반 미만)" 적은 쪽 → 같으면 그 최소 수량이 큰 쪽. 예: A35+B10 → A23 / A12+B10 (예전 A35 / B10)
  - **같은 제품 통째로 우선 (2026-10-14 추가)**: `mergePool`이 두 후보 — `packWhole`(제품을 나누지 않고 파렛트에 통째 배정, DFS 30만 스텝 제한) / `pourBalanced`(고르게, 나뉨 최소) — 를 `binScore`로 비교: ⓪ 1자리(stack)도 안 되는 나뉜 조각 수 ① 상품 1개 소량 파렛트(cap 절반 미만) 수 ② 나뉜 제품 수 ③ 파렛트 수량 차이. 큰 자투리 포함 여부 비교(가/나)도 파렛트 수 → 작은 조각 → 소량 단독 → 나뉜 제품 수 순. 예: 10/15 3층 흑돼지왕구이 26이 25 + 1로 나뉘던 것 → 26 통째 + 갈매기살 1 혼적
  - **양념별 혼적 (2026-10-14 추가)**: `ol_products.sauce`(TEXT, 빈 값 = 양념 없음) + `ol_upsert_product`에 `p_sauce` 11번째 인자(기존 10인자 DROP). 마이그레이션 `setup_orders_sauce.sql`(setup_orders.sql에도 반영). 제품 폼에 "양념" 칩(없음/간장/고추장/기존 값) + 직접 입력, 제품표에 양념 열. SQL 실행 전이면 양념 없이 저장하고 안내 alert
    - 혼적 비교 기준에 "양념 충돌"(한 파렛트 안 서로 다른 **비어 있지 않은** 양념 수 − 1, `sauceConflict`) 추가 — 순서: 파렛트 수 → 작은 조각 → **양념 충돌** → 소량 단독 → 나뉜 제품 → 수량 차이. `packWhole`/`pourBalanced`/`binScore`/가·나 비교 모두 반영. 양념 없는 제품은 어느 쪽과 섞여도 충돌 아님. 파렛트 수를 늘리면서까지 분리하지는 않음
    - 정렬: 혼적 파렛트 안 줄은 양념(없음 → 간장 → 고추장, 가나다) → 발주서 순서, 혼적 파렛트들도 첫 줄 양념 순
  - 단독 파렛트는 발주서 순서 → 같은 제품은 수량 많은 것부터, 혼적은 맨 뒤
  - 10/14 실제 발주: 목살보쌈용 11 단독 → 삼겹보쌈용 9 + 목살보쌈용 11 혼적 (총 10파렛 동일). 파렛트 구성이 바뀐 발주는 기존 적재이미지 편집이 적용되지 않음(sig 변경)
- **소비기한 없으면 빈칸 (2026-10-14 변경)**: `expiryOf(ln)` — 발주서의 유통(소비)기한만 사용, 없으면 `""`(예전엔 입고일+6일로 채움). 부착리스트 엑셀 F열은 빈 문자열 셀(테두리 유지), 미리보기도 빈칸
- **적재이미지 글씨 추가 (2026-10-14 추가)**: 편집 툴바 "＋ 글씨 추가" → 이미지 가운데쯤(top 45%)에 "새 글씨"(24px, 굵게, 검정) 생성 + 자동 선택. 편집값 `extra:[{id:"x…", color}]`에 저장(블록 id `x…`, 글씨 id `x….t` — 이동·크기·글씨 수정은 기존 `pos/size/text` 그대로 사용). 추가 글씨 선택 시 색(COLOR_PRESETS 10색) + "🗑 글씨 삭제" 표시, 글씨를 비우고 Enter해도 삭제. `countEdits`에 포함 → "원래대로"로 함께 제거. 파렛트 구성(sig)이 바뀌면 다른 편집과 함께 무시됨
- **혼적 자리 높이 균등 분배 (2026-10-14 변경)**: `layoutMixed`(→ `layoutMixedCalc`, 결과 캐시 `_mixedCache`)가 모든 자리 높이를 ⌊전체÷자리⌋/⌈전체÷자리⌉로 맞춤(예: 26박스 6방 → 5·5·4·4·4·4, 예전엔 5·5·5·5·5·1 가능). 어느 자리를 +1로 할지(조합) × 제품 순서(6종 이하 전 순열)를 전수 탐색해 **한 자리에 두 제품이 섞이는 경우 최소화**(예: 10+10 → 4·3·3 / 4·3·3 안 섞임, 15+11 → 5·5·4 / 1+3·4·4). 셀 구조 `{parts:[{ln,n}](아래→위), ln, n}` — 섞인 자리는 위쪽 제품을 위에(2026-10-15부터 점선 구분선 없음), 글씨 14px. 글씨 id: 첫 제품 `m{n}.c{칸}.n/.c`, 다음 제품 `.p1.n/.p1.c`
  - 혼적 1자리 최대 박스(`stack`) = 혼적 방식 `max_boxes` ÷ 층당 방(예: 30÷6=5). 직전 변경에서 1단 박스 수로 나눠 3이 되던 문제 수정
- **파렛트 용량 = 적재방식 최대 박스 (2026-10-14 변경, 아래 "박스규격 기반 적재량 자동 계산"을 대체)**: 단독 1파렛트 용량은 **항상 적재방식의 `max_boxes`**(제품에 단독 방식이 여러 개면 최댓값, 단독 없으면 혼적 최솟값, 방식 미지정이면 40). 박스규격(가로×세로)은 `layerCount`로 **1단 박스 수 계산에만** 사용 → 단수 = ⌊최대 박스 ÷ 1단⌋(혼적 1자리 쌓는 높이). 박스 높이·최대 적재 높이·파렛트 자체 높이는 더 이상 계산에 안 씀(파렛트 설정 모달에서 높이 2칸 제거, 저장값은 남아 있어도 무시). 적재방식 라벨 "규격 없을 때 최대 박스" → "최대 박스 (파렛트 1개)". 표시 예: `최대 32박스 · 1단 8박스 × 4단`(나머지가 있으면 `+ N박스`)
- **적재이미지 소제목 위치 (2026-10-14 변경)**: 소제목(생산지점·센터·발주번호)을 별도 블록 `sub`에서 헤더 블록 `hd` 안으로 옮겨 제목줄(제목 + 총N파렛) 왼쪽 밑에 왼쪽 정렬로 붙임(`hd` = 세로 flex, 왼쪽 끝 정렬 — 소제목 왼쪽 끝 = 제목 왼쪽 끝, 함께 이동). 글씨 id `sub`는 유지 → 글씨 수정·크기는 그대로 적용, 예전에 `sub` 블록을 따로 옮긴 위치값은 더 이상 쓰이지 않음
- **적재이미지 편집 화면 = 용지 모양 (2026-10-14 추가)**: 편집 화면이 선택한 용지 비율(가로 √2:1)의 흰 종이 + 회색 배경으로 표시되고, 저장과 같은 계산(`contentCrop` → 여백 10mm 안에 맞춤)으로 내용을 `transform: translate+scale`해 배치 → 화면 = 저장 결과(실측 오차 ~1%). A4 가로/A3 가로는 비율이 같아 모양은 같고 여백 비율만 약간 다름(A3는 인쇄 시 글씨가 더 큼). 종이 폭은 영역 너비에 맞춤(최대 1100px, ResizeObserver). 편집 모드면 여백선(점선) 표시, 우하단에 용지 이름 표기
  - 배율은 `ed`/용지/맞춤/폰트 로딩 변경 시에만 재계산(`useLayoutEffect`) — 드래그·크기 조절 중에는 고정, 놓으면 다시 맞춤
  - `DragBlock`은 화면 배율 z(= 화면 폭/실제 폭)로 이동량을 나눠 저장 → 축소된 화면에서도 커서와 정확히 같이 움직임. 안내선 위치도 z로 환산
  - 저장 시에는 화면 밖(`left:-20000`)에 축소 없는 사본 `LoadImage`(edit=false)를 그려 캡처 → 편집 모드를 껐다 켜지 않음
- **적재이미지 "원래대로" 화면 내 확인 (2026-10-14 수정)**: 기존 `confirm()` 창이 앱 내장 브라우저 등에서 안 떠서 자동 취소 → 버튼이 무반응처럼 보였음. 버튼 클릭 시 그 자리에 "모두 되돌릴까요? [되돌리기] [취소]"를 표시하는 방식(`askReset` state)으로 교체. orders.html의 다른 `confirm()`(삭제 등 7곳)은 그대로
- **적재이미지 "용지에 맞춰 확대" (2026-10-14 추가)**: 저장 툴바 체크박스(기본 ON, localStorage `ol-fit-paper`). 켜면 모든 블록(`data-bid`)의 범위 + 6px만 잘라서 용지(여백 10mm 제외)에 꽉 차게 확대 → 글씨가 용지 크기에 비례해 커짐(A3면 더 크게). html2canvas scale은 `ceil(맞춤 배율)`을 2~8로 제한해 해상도 유지. 끄면 예전처럼 920px 이미지 전체를 맞춤. 실제 발주(10파렛) A4 가로 기준 내용 높이 64% → 86%. 배치가 세로로 길면 좌우 여백은 남음(비율 유지) — 블록을 옆으로 배치하면 가로도 더 채워짐
- **적재이미지 용지 선택 저장 (2026-10-14 추가)**: 이미지별 용지 드롭다운(**A4 가로 / A3 가로만** — 사용자 요청으로 세로 제거, `PAPER_SIZES`, 마지막 선택 localStorage `ol-paper`, 예전 세로 값이 남아 있으면 A4 가로로 대체) + "📷 PNG" / "📄 PDF" 버튼. html2canvas(scale 2~5) 결과를 300dpi 용지 캔버스(A4 가로 3508×2480, A3 가로 4961×3508) 가운데에 여백 10mm(`PAPER_MARGIN_MM`)로 비율 유지 맞춤. PDF는 `jspdf@2.5.1`(cdnjs UMD, `window.jspdf.jsPDF`)로 정확한 mm 크기 1페이지(JPEG 0.95). 파일명 끝에 `_A4가로` 등 표기. 다크 모드에서 드롭다운 옵션 안 보이던 문제로 `select.ol-input option` 배경/글씨색 지정
- **적재이미지 편집 (2026-10-14 추가)**: 이미지마다 "✏ 편집" 토글 → 점선 블록(헤더·부제·단독 블록·혼적 표)을 끌어서 이동, 글씨 더블클릭으로 수정(Enter 저장 / Shift+Enter 줄바꿈 / Esc 취소 / 비우면 숨김), "↺ 원래대로"로 초기화
  - 저장: `ol_settings`에 key `img:{발주번호}:{생산지점}`, value `{sig, pos:{블록id:{dx,dy}}, text:{글씨id:문자열}}` — 기존 `ol_set_setting` RPC 재사용(SQL 변경 없음), 모듈 캐시 `imgEditCache`로 탭 전환 후에도 즉시 반영. `sig`(파렛트 구성 요약)가 바뀌면(발주서 재업로드 등) 이전 편집 무시 + 안내
  - 이동은 원래 자리 기준 `position:relative; left/top` 오프셋 → html2canvas PNG에 그대로 반영, PNG 저장 시 편집 모드 점선은 자동으로 껐다가 복귀
  - 블록 id: `hd`, `sub`, `s{시작파렛트번호}`, `m{파렛트번호}` / 글씨 id: `title`, `total`, `sub`, `s{n}.l|.n|.q`, `m{n}.label`, `m{n}.c{칸}.n|.c`
  - 드래그는 포인터 캡처 대신 window 이벤트로 추적(캡처하면 더블클릭이 글씨까지 안 내려감), 2px 이하 이동은 클릭으로 간주
  - 한계: 삭제한 발주서의 편집값은 `ol_settings`에 남음(용량 미미). 블록 추가/삭제·글자 크기·색 변경은 미지원
- **박스규격 기반 적재량 자동 계산 (2026-10-13 변경)**: 고정 40박스 → 제품 박스규격으로 계산. `ol_settings`(key/value JSONB) 테이블 + `ol_set_setting` RPC, `ol_list_masters`가 `settings` 반환. 기본값 파렛트 1100×1100, 최대 높이 1700mm, 파렛트 자체 높이 0(최대 높이에 파렛트가 포함된 기준이면 150 등 입력) — 제품리스트 "⚙ 파렛트 설정"에서 수정
  - `layerCount(L,W,a,b)`: 1층 박스 수 = max(2구역 배치 `twoBlockCount`(한 방향 k줄 + 나머지 회전), **5구역 바람개비 배치**). 5구역은 좌하/우하/우상/좌상 네 블록이 가운데 블록을 감싸는 형태로, 분할점 x1≤x2, y1≤y2를 래스터 포인트(i·a+j·b와 그 여집합)에서 전수 탐색, 각 블록은 2구역 배치로 채움. 결과는 `_layerCache`에 메모(최대 ~20ms). 460×300 → **8**(300+300+460=1060 → 600×460 블록 2개×4), 400×300 → 9, 600×400 → 4, 550×275 → 8. 사용자 지적("300 300 460으로 1060이면 8방")으로 2구역만 쓰던 첫 구현(7)을 수정
  - `boxCapacity()`: 단수 = ⌊(최대높이−파렛트높이)/박스높이⌋, 단독 용량 = 1층 × 단수. 규격 없음/파렛트에 안 맞는 규격 → 적재방식의 `max_boxes`("규격 없을 때 최대 박스")로 fallback, 혼적 1자리 단수 = ⌊max_boxes/6⌋
  - 혼적: 자투리 필요 자리 = ⌈자투리/그 제품 단수⌉, **6자리 미만일 때만** 혼적 풀(아니면 단독 1파렛트) → 필요 자리 큰 순 First-Fit Decreasing으로 혼적 파렛트 빈자리에 배치. `layoutMixed`는 필요 자리부터 주고 남는 자리는 mm 높이가 가장 높은 제품에 → 높이 다른 제품끼리도 고르게
  - 제품리스트 표에 "단독 1파렛트 적재량"(예: `7박스 × 5단 = 35박스 · 혼적 1자리 5단`), 제품 폼에 실시간 미리보기
  - 검증: 예시 발주서 + 460×300×285 → 8×5=40박스, 7파렛트(40/33/40/40/40/38 + 혼적 3·3·4/3·3·4) — 실제 부착리스트와 동일
- **혼적 = 층당 6방 (2026-10-13 변경)**: 사용자 설명 "혼합적재는 한 층에 6박스만" → 적재이미지 표의 숫자는 **자리(방)별 쌓는 박스 수**. `ol_load_methods.per_layer`(기본 6, `ADD COLUMN IF NOT EXISTS`) 추가, `ol_upsert_method`에 `p_per_layer` 파라미터(기존 7인자 DROP). 혼적 풀 패킹 시 한 파렛트에 **제품 최대 6종**(새 제품 자리 없으면 새 파렛트), 박스 총량은 기존 `max_boxes`(40) 제한 유지. `layoutMixed()`: 제품마다 최소 1자리 → 남는 자리는 가장 높이 쌓이는 제품에 하나씩(높이 균등화) → 자리 안에서 3·3·4처럼 분배, 그리드는 가로 `cols`(3)칸으로 줄바꿈. 예시(10+10) 결과 3·3·4/3·3·4 그대로, [10,5,2] → 3·3·4 / 2·3 / 2. 적재방식 관리 모달: "이미지 칸 수" → "층당 박스 수(방)" + "이미지 가로 칸 수"
- **생산지점 드롭다운 (2026-10-13 추가)**: `ol_sites`(name UNIQUE) 테이블 신설 + 기존 제품의 지점 값 자동 이관(INSERT…SELECT DISTINCT). `ol_list_masters`가 `sites`도 반환. RPC `ol_add_site` / `ol_rename_site`(그 지점을 쓰던 제품의 `site`도 함께 변경, 중복 이름이면 `site_exists`) / `ol_delete_site`(목록에서만 삭제, 제품 값 유지 → 폼에 "(목록에 없음)"으로 표시). 제품 폼의 지점 입력칸 → `<select>` + 관리 버튼, 제품리스트 툴바에 "🏭 생산지점 관리". 제품은 여전히 `site`에 이름 텍스트 저장 → 발주서·발주리스트 그룹핑 로직 변경 없음
- **추가 발주 합치기 + 업체별 제목색 (2026-10-14 추가)**:
  - `buildSiteGroups`: 같은 입고일 안에서 **업체명 + 센터 + 생산지점**이 같으면 발주번호가 달라도 한 리스트로 합침(센터가 다르면 실제로 다른 곳에 납품하므로 분리 유지). 같은 상품코드·같은 소비기한은 수량을 합쳐 한 줄로 → 파렛트를 같이 채움. 대표 발주(`mergeOrders`)의 `order_no`는 `"200, 201"`처럼 연결 → 부착리스트 B6·적재이미지 부제·파일명에 그대로 표시. 그룹에 `orders`(원본 목록)·`vendor` 필드 추가, 화면에 "발주서 N건 합침" 뱃지
  - 적재이미지 편집 키 `img:{발주번호}:{지점}`은 합쳐지면 `img:200, 201:지점`으로 바뀌어 이전 편집이 적용되지 않음(단일 발주는 기존 키 그대로)
  - 부착리스트 제목(A1) 배경색 = 업체별 색. `TITLE_COLORS` 8색(노랑/연두/하늘/주황/보라/분홍/청록/회색), `ol_settings` key `vendor_colors` = `{업체명: "RRGGBB"}`. 처음 보는 업체는 안 쓴 색을 자동 배정해 저장(`assignVendorColors`, 첫 업체 = 노랑) → 다음날에도 같은 업체는 같은 색. 부착리스트 화면 상단 "업체별 제목 색" 드롭다운으로 변경 가능. 드롭다운 맨 아래 **"배경색 없음"**(값 `"none"`, `TITLE_NONE`) → 엑셀 A1에 채우기 없음, 미리보기는 흰 배경. 자동 배정에는 쓰이지 않음. SQL 변경 없음
- **➕ 추가 발주 탭 (2026-10-14 추가)**: 작업이 끝난 뒤 들어온 추가 발주서를 따로 올려 따로 적재. `ol_orders.is_extra` 컬럼 + `ol_list_orders`/`ol_list_due_dates`에 `p_extra`(기본 FALSE), `ol_save_order`에 `p_is_extra`(기본 FALSE, 응답에 `moved` — 같은 발주번호를 다른 탭에서 올리면 그 탭으로 옮겨짐). 마이그레이션 `setup_orders_extra.sql`(setup_orders.sql에도 반영, retention 이후 실행)
  - 일반 발주서·발주리스트 탭은 `is_extra=false`만, 추가 발주 탭은 `true`만 보여 서로 안 섞임. 1달 보관 정리는 공통
  - App: `useOrderData(adminHash, extra, onErr)` 훅으로 입고일/선택일/발주서 상태를 일반·추가 따로 관리, 탭 이동 시 해당 데이터 재조회. 해시 `#extra`, 안에 서브탭 📄 추가 발주서(`OrdersTab extra`) / 🗂 추가 발주리스트(`ListsTab extra`) — 기존 컴포넌트 재사용, 서브탭 localStorage `ol-extra-sub`
  - 추가 발주는 `buildSiteGroups(..., {separate:true})` → 같은 업체·센터라도 **발주번호끼리 합치지 않고** 발주서마다 따로 적재·번호(`orderKey`=order id를 버킷·번호 연결 키 앞에). 같은 발주서의 다른 생산지점끼리는 번호 연결 유지
  - SQL 실행 전: 일반 탭은 `p_extra` 없이 재호출로 기존대로 동작(콘솔 404는 정상), 추가 발주 업로드는 "setup_orders_extra.sql 실행 필요" 오류
- **혼적 제품이 6종 넘을 때 적재이미지 깨짐 수정 (2026-10-15)**: 적재이미지가 `layoutMixed(lines, max(slots, 제품 수))`로 자리를 제품 수만큼 늘려(예: 8종 → 8자리) 3번째 줄이 생기며 깨졌음. 자리 수는 항상 층당 방 수(`p.slots`, 6)로 고정 → 제품이 많으면 한 자리에 여러 제품을 나눠 쌓음(`pourBalanced`)
  - 한 자리에 3개 이상 제품이면 글씨 12px(4개+ 11px) + 이름·수량 한 줄(flex wrap)
  - 한 자리에 여러 제품이 섞일 때 제품 사이 점선 구분선 제거(사용자 요청) — 4px 간격만 둠
  - `pourBalanced`: 7개 이상 항목은 정렬 2종 + 고정 시드 섞기 최대 400가지(묶음 조합 수에 따라 `20000/조합수`로 제한) 시도 → 나뉘는 제품 최소화(예전엔 2가지 순서만 시도해 1박스 제품도 두 자리로 나뉨). 결과는 결정적(같은 입력 → 같은 배치)
  - `imageSig`: 제품 수 > 자리 수인 혼적 파렛트에 `~s` 표식 → 해당 이미지의 예전 편집(깨진 배치 기준)은 무시
- **적재이미지 편집 되돌리기/다시 실행 (2026-10-15 추가)**: `LoadImageCard`의 `persist(next, fromHistory)`가 저장 직전 상태를 `undoRef`(최대 100단계)에 쌓고 `redoRef`를 비움 → 이동·글씨 수정·크기·전체 배율·글씨 추가/삭제/색·원래대로 모두 되돌릴 수 있음. 편집 모드에서 Ctrl+Z(Mac ⌘Z) 되돌리기, Ctrl+Y / Ctrl+Shift+Z 다시 실행(글씨 입력·input 포커스 중엔 브라우저 기본 동작), 툴바 "↶ 되돌리기 / ↷ 다시" 버튼. 되돌린 상태도 `ol_set_setting`으로 저장. 기록은 화면 메모리에만 있어 새로고침·파렛트 구성(sig) 변경 시 초기화. 키 핸들러는 편집 모드인 카드만 등록(여러 이미지를 동시에 편집 중이면 모두 반응)
- **혼적 표 안 글씨 이동 (2026-10-15 추가)**: 적재이미지 편집 모드에서 혼적 칸 안의 제품 글씨(이름+수량 묶음)와 파렛트 라벨(`26-18`)을 따로 끌어서 이동. `DragBlock`에 `inner` prop — 안쪽 블록을 누르면 `stopPropagation`으로 그 블록만 이동(표는 빈 공간·테두리를 잡으면 이동), 옅은 점선, 블록 크기 핸들 없음(글씨 클릭 → 글씨 모서리 핸들로 크기 조절은 그대로). 스냅 기준선에서 자기 안쪽·바깥 블록은 제외. 블록 id: 제품 글씨 `m{n}.c{칸}.m`(섞인 자리 다음 제품 `.p1.m`), 라벨 `m{n}.lb` — 기존 `ed.pos`에 저장, SQL 변경 없음
- **적재이미지 여러 글씨 선택 + 혼적 표 칸 크기 조절 (2026-10-21 추가)**:
  - 선택이 글씨 1개 → 목록(`selArr`). Shift/Ctrl+클릭으로 추가·해제, 용지 화면 빈 곳을 끌거나 Shift 누르고 아무 곳이나 끌면 사각형 범위 선택(글씨는 걸치면, 혼적 표는 통째로 들어와야 선택, Shift/Ctrl이면 기존 선택에 추가), Esc·"선택 해제" 버튼으로 해제. 드래그 직후 click은 한 번 막아 선택이 안 바뀜. `DragBlock`은 Shift 누르면 이동 대신 범위 선택으로 넘김
  - A−/A+: 글씨 1개면 ±2px, 여러 개(또는 표 칸)면 각각 ±10%. 선택한 글씨 모서리 ■을 끌면 선택한 것 전부 같은 비율. "기본"은 선택한 것 전부 초기화
  - 혼적 표 칸(132×128, 라벨 위치, 안쪽 여백)이 `size["m{n}.box"]`(%, 30~300, 기본 100) × 전체 글씨 배율을 따름 → 블록 ■ 크기 조절·전체 글씨 A−/A+ 때 칸도 같이 커지고 작아짐. 표에 `data-tid`/`data-kind="box"`를 달아 기존 크기 조절 경로 재사용(`scaleItemOf`가 항목별 최소·최대 전달). 선 굵기(1.5px)는 고정
  - 이미 전체 배율을 100%가 아닌 값으로 저장한 이미지는 혼적 표 칸 크기가 그 배율만큼 바뀌어 보임. SQL 변경 없음
- **발주서 수량 편집 (2026-10-15 추가)**: 📄 발주서(➕ 추가 발주서 포함) 카드마다 "✏ 수량 편집" → 발주수량 칸이 입력칸으로 바뀌고 박스 수가 실시간 재계산 → "💾 수량 저장"(Enter 저장 / Esc 취소, 한 번에 카드 하나만 편집). 바뀐 품목만 `ol_update_order_items(hash, order_id, items JSONB [{id,qty}])` RPC로 일괄 저장 → 발주리스트(부착리스트·적재이미지)에 바로 반영
  - `ol_order_items.orig_qty`(NUMERIC NULL) — 처음 편집 전 원래 수량 보관, 원래 값으로 되돌리면 NULL. `ol_list_orders` 응답에 `orig_qty` 추가. 편집된 품목은 주황 굵은 수량 + 원래 수량 취소선 표시. 같은 발주번호를 다시 업로드하면 품목이 새로 들어가 편집 초기화
  - 마이그레이션 `setup_orders_qtyedit.sql`(setup_orders.sql에도 반영). 실행 전 저장 시 안내 alert
  - 수량이 바뀌면 파렛트 구성(sig)이 바뀌어 해당 적재이미지의 기존 위치·글씨 편집은 무시됨
- **발주서 날짜별 전체 삭제 (2026-10-21 추가)**: 📄 발주서 / ➕ 추가 발주서 탭에서 선택한 입고일 제목 옆 "🗑 이 날짜 전체 삭제" → 그 자리에서 "N건을 모두 삭제할까요? [모두 삭제] [취소]" 확인(앱 내장 브라우저에서 `confirm()`이 안 뜨는 문제 회피). 그 날짜(해당 탭 — 일반/추가 따로)의 발주서를 기존 `ol_delete_order`로 하나씩 삭제(생산지점 필터와 무관하게 전부), 끝나면 다음 입고일(없으면 마지막 날짜)로 이동. SQL 변경 없음. 실패한 건이 있으면 개수 알림 후 남은 발주서 다시 표시
- **발주서 압축파일 업로드 (2026-10-14 추가)**: `jszip@3.10.1`(cdnjs) 추가. 업로드 input `accept`에 `.zip`, `handleFiles`가 `.zip`이면 `unzipOrderFiles()`로 안의 `.xlsx/.xls`를 꺼내 기존 파싱 흐름으로 처리(하위 폴더·압축 안의 압축 2단계까지, `__MACOSX`·`~$` 임시파일·숨김파일 제외, 파일명 순 정렬). 윈도우 zip의 CP949 한글 파일명은 `decodeZipName`이 UTF-8 실패 시 EUC-KR로 디코딩. 결과/`file_name`은 `압축.zip › 파일.xlsx`로 표기. 엑셀 없는 압축은 결과 모달에 오류
- **제품 냉장/냉동 구분 (2026-10-14 추가)**: `ol_products.storage`('chilled' 기본 | 'frozen') + `ol_upsert_product` 12번째 인자 `p_storage`(기존 11인자 DROP). 마이그레이션 `setup_orders_storage.sql`(setup_orders.sql에도 반영) — 컬럼을 처음 만들 때만 생산지점 이름에 '냉동'이 들어간 기존 제품을 frozen으로 초기화. 제품 폼에 "보관" 버튼(🧊 냉장 / ❄ 냉동), 제품표에 보관 열. SQL 실행 전이면 냉장/냉동 없이 저장(냉동 선택 시 안내 alert, 양념 fallback과 체인)
  - `buildSiteGroups` 버킷 키에 storage 추가 → 같은 생산지점이라도 냉장·냉동은 별도 그룹(별도 적재). 파렛트 번호 연결도 업체+센터+**보관** 단위(냉장끼리, 냉동끼리 합계). 정렬: 업체 → 센터 → 보관(chilled → frozen) → 생산지점
  - 냉동 제품은 부착리스트 소비기한(F열·미리보기) 항상 빈칸 (`expiryOf`)
  - 부착리스트 A1 제목 `(신선)`/`(냉동)`, E4 `( {센터}(신선) 센터 )` / `( {센터}(냉동) 센터 )` — 엑셀·미리보기 동일. 발주리스트 그룹 헤더에 냉장/❄ 냉동 뱃지
  - 같은 생산지점에 냉장·냉동이 함께 있으면(`splitStorage`) 적재이미지 부제에 `(냉장)/(냉동)` 표기 + 편집 키 `img:{발주번호}:{지점}:{storage}`로 구분(아니면 기존 키 그대로)
- **같은 업체 생산지점 간 파렛트 번호 연결 (2026-10-14 추가)**: `buildSiteGroups` 끝에서 업체명+센터가 같은 그룹(생산지점만 다름)을 묶어 `total` = 합계, `no`를 생산지점 순서(이름 숫자 정렬: 2층 → 3층 → 3층 냉동 → 4층 …)대로 이어 붙임. 적재(파렛트 구성)는 생산지점별 그대로. 부착리스트 A3·적재이미지 "총N파렛"·라벨이 모두 합계 기준(예: 3층 `22 - 1`~`22 - 10`, 4층 `22 - 11`~). 그룹에 `center` 필드 추가. `imageSig`에 번호가 1부터가 아니거나 total≠파렛트 수면 `#{첫번호}/{총}|` 접두 → 번호가 바뀌면 이전 적재이미지 편집은 무시(블록 id가 번호 기준). 업체명이 글자 하나라도 다르면 별개 업체로 취급
- **혼적 최대 단수 설정 (2026-10-14 변경)**: 혼적 1자리 높이(`stack`)를 "혼적 방식 최대 박스 ÷ 6" → 파렛트 설정의 **`mix_layers`(혼적 최대 단수, 기본 6)**로 변경(`ol_settings`, ⚙ 파렛트 설정에서 수정, SQL 변경 없음). 원인: `mergePool`이 풀 안 최솟값 stack을 쓰는데 30박스 혼적 방식(5단) 제품 하나만 섞여도 혼적 전체가 5단(30박스)으로 묶였음. 실제 10/16 3층 냉동: 10파렛 → 9파렛. 단독 파렛트 용량(적재방식 최대 박스)은 그대로
- **혼적 적재방식별 1자리 최대 단수 (2026-10-15 추가)**: 박스가 높아 6단까지 못 쌓는 제품용. `ol_load_methods.mix_layers`(INT NULL, NULL = 파렛트 설정 `mix_layers` 사용) + `ol_upsert_method` 9번째 인자 `p_mix_layers`(기존 8인자 DROP). 마이그레이션 `setup_orders_mixlayers.sql`(setup_orders.sql에도 반영). SQL 실행 전이면 단수 없이 저장 + 안내 alert
  - 적재방식 관리 폼(혼적일 때) "1자리 최대 단수" 입력(비우면 파렛트 설정값 placeholder), 목록 "혼적 구성" 열 = `6방 × 4단 · 가로 3`(기본값이면 "(기본)")
  - `boxCapacity`: 제품의 혼적 방식들 중 설정된 `mix_layers` 최솟값 → 없으면 `cfg.mix_layers`
  - `mergePool`: 풀 안 단수가 여러 개면 (가) 전부 한 풀(`mergePoolOne` — 가장 낮은 단수 × 방 수가 혼적 1파렛트 최대) / (나) 단수별로 따로 혼적 → `palletScore`(buildPallets 비교 점수를 최상위 함수로 분리) 낮은 쪽. 예: 6단 A10 + 4단 B10 → 한 혼적(자리 높이 ≤4), 6단 A30 + 4단 B20 → 각각 단독 2파렛
- **부착리스트 엑셀 발주번호 크기 (2026-10-14 수정)**: B6 발주번호가 28pt(+6행 높이 48)로 미리보기보다 훨씬 크게 나오던 것 → 다른 정보 칸과 같은 16pt 굵게(`XS_INFO_VAL`), 6행 높이 28
- **발주서 1달 보관 (2026-10-14 추가)**: `ol_cleanup_old_orders()`(내부 전용, anon 실행 권한 회수) — 입고예정일(`due_date`)이 오늘(KST) − 1달보다 이전인 `ol_orders` 삭제(품목은 CASCADE) + 남은 발주번호와 무관해진 적재이미지 편집값(`ol_settings` `img:*`)도 정리. `ol_list_due_dates`(페이지 열 때)와 `ol_save_order`(업로드 때) 첫머리에서 자동 호출 → 별도 스케줄러 없음. 마이그레이션 `setup_orders_retention.sql`(setup_orders.sql에도 반영, 실행 시 1회 즉시 정리). 업로드 안내 문구에 표기. 한계: 업로드일이 아니라 입고예정일 기준이라, 1달 넘게 지난 입고일의 발주서를 올리면 다음 조회 때 바로 지워짐. 제품리스트·박스규격·적재방식 등 마스터는 대상 아님
- **🚚 출고장 탭 (2026-10-20 추가)**: 사용자 요청 — `출고리스트.xlsx` 양식처럼 입고일 하루치 발주서를 한 장으로 정리. 별도 업로드 없이 📄 발주서 탭에 올린 데이터 사용 (해시 `#ship`, SQL 변경 없음)
  - `buildShipList`: 업체·센터·발주번호가 달라도 같은 상품코드 + 같은 소비기한이면 수량 합산. 냉장은 생산지점별(이름 숫자 정렬: 2층 → 3층) 묶음, 냉동은 하나의 목록(생산지점 → 발주서 순서). 제품명 표기 = `{제품명} / {입수량}ea`
  - 박스수량 = 총 팩수량 ÷ 입수량 (나누어떨어지지 않으면 빨강 + 경고). 생산지점마다 박스 합계(노랑 굵은 칸) + 지점 합계 행, 지점이 2개 이상이면 냉장 총합계
  - 냉장 소비기한 = 발주서의 유통(소비)기한, 연속된 같은 날짜는 칸 병합 · 냉동 유통기한 = 발주서 값, 없으면 입고일 + N일(기본 182, localStorage `ol-ship-frozen-days`)
  - 옵션: 발주 없는 제품도 표시(`ol-ship-all`, 0으로 표시) / 추가 발주 포함(`ol-ship-extra`, 기본 켜짐 — 같은 입고일의 `p_extra:true` 발주서 별도 조회) / 업체가 2곳 이상이면 업체 칩으로 필터. 제목 머리말은 발주리스트와 공유(`ol-prefix`)
  - `downloadShipXlsx`: 원본 서식 재현(A~F 열 폭, 18~24pt, 노랑 채우기, 박스·소비기한 굵은 테두리, `yyyy/mm/dd"이후"` 날짜, `C/입수량`·`SUM` 수식) → `출고리스트_{날짜}[_{업체}].xlsx`
  - 한계: 날짜 목록은 일반 발주서의 입고일만 표시(추가 발주만 있는 날짜는 안 보임). 원본처럼 지점 순서를 3층 → 2층으로 바꾸는 설정은 없음
  - **가독성 개편 (같은 날)**: 사용자 요청 "조금 더 깔끔하게" → 원본 양식 복제 대신 정돈된 표로 변경(화면·엑셀 동일 구성, `shipSections` 공통)
    - 열: 제품명(왼쪽 정렬) / 입수(`6ea`, 별도 열) / 총 팩수량 / 박스수량(연노랑) / 소비·유통기한. 숫자 오른쪽 정렬
    - 생산지점은 세로 병합 열 대신 **띠 행**(`🏭 3층 · N품목 · N팩` + 오른쪽 박스 합계). 냉동도 지점 띠로 묶음
    - 섹션 색: 냉장 청록 / 냉동 파랑. 제목 옆에 `냉장 N박스 · 냉동 N박스 · 총 N박스` 요약, 섹션 끝에 합계 행(굵은 윗선)
    - 엑셀: A~E 5열, 회색 얇은 테두리, 섹션 제목은 색 채우기 흰 글씨, 박스 합계는 `SUM` 수식, 날짜 `yyyy/mm/dd"이후"`
  - **발주수량 0 품목 숨김 (같은 날)**: 사용자 보고 "발주 없는 제품이 흐리게 보인다" — 원인은 체크박스가 아니라 발주서에 줄은 있는데 발주수량이 0인 품목(취소·미발주)이 그대로 들어간 것. `buildShipList`에서 수량 0 줄을 지우고, "발주 없는 제품도 표시"를 켰을 때만 보이게 함
  - **층별 분리 (같은 날)**: 사용자 요청 "층별로 공간이 있어야 할 것 같다, 헷갈린다" → 화면: 생산지점마다 별도 카드(~~왼쪽 굵은 색 띠~~ 2026-10-29 사용자 요청으로 제거, 1px 회색 테두리만 + 큰 지점명 + 오른쪽 `N박스` 뱃지 + 자체 열 제목), 카드 사이 16px 간격, 지점이 2개 이상일 때만 섹션 합계 줄. 엑셀: 지점마다 굵은 지점 행(16pt, 박스 합계 칸 색 채움) → 열 제목 행 → 품목 → 빈 줄
  - **이미지 저장 (같은 날)**: 처음엔 A4 쪽 나눔(PNG 여러 장/PDF)으로 만들었으나 사용자 요청 "그냥 길게 하나로 저장되거나 층별로 저장되게"로 교체 → `🖼 한 장으로 저장`(전체를 세로로 긴 PNG 1장) / `🏭 층별로 저장 (N장)`(생산지점마다 PNG 1장, 제목·박스 요약은 그 층 기준, 파일명 `출고리스트_{날짜}_{층}.png`). `saveShipPng`: 화면 밖 700px 고정 폭 사본(`ShipSheetPreview print`)을 html2canvas(scale 3)로 캡처. 쪽 나눔·PDF 없음
  - **A4 세로 저장 (2026-10-21)**: 사용자 요청 "A4 세로에 맞게" → 저장 버튼을 `A4로 저장 (이어서)`(선택한 층을 이어 붙여 쪽 나눔) / `🏭 층별 A4로 저장`(층마다 새 쪽)으로 변경 + 형식 칩 🖼 PNG / 📄 PDF(localStorage `ol-ship-fmt`). 사본 폭 718px(= 794 − 여백 38×2), `shipA4Pages`가 한 번 캡처(scale 3) 후 `data-shipcut` 위치(섹션·층 카드·소비기한 병합 구간이 시작하는 줄)에서 잘라 794×1123 종이에 붙임 → 합친 소비기한 칸은 쪽 사이에서 잘리지 않음. 1.2쪽 이하는 한 쪽에 축소, 여러 쪽이면 아래에 `n / 전체`. PNG는 쪽마다 파일(`_1쪽`…), PDF는 jsPDF A4 한 파일(층별은 `_층별.pdf`). 이어지는 쪽에는 층 머리·열 제목이 다시 나오지 않음. `saveShipPng`(긴 PNG 1장)는 냉동재고에서만 사용
  - **아래 여백 자르기 (2026-10-22)**: PNG 형식일 때 툴바에 "아래 여백 자르기" 체크박스(기본 켜짐, localStorage `ol-ship-trim`). 켜면 `shipA4Pages(el,{trim:true})`가 종이 높이를 내용 끝 + 아래 여백 10mm(여러 쪽이면 쪽 번호 자리 포함)로 잘라 저장 → 한 층만 저장해도 아래 빈 공간 없음. 폭은 A4(794px) 그대로, 꽉 찬 쪽은 그대로 A4. PDF는 항상 A4 크기 유지
  - **저장할 층 선택 (같은 날)**: 툴바 아래 `저장할 층` 체크박스(층마다, 냉동은 ❄) + 전체 선택/해제. 두 저장 버튼 모두 체크된 층만 저장(한 장 저장도 선택한 층만 이어 붙임, 선택 0개면 비활성). 해제한 층만 localStorage `ol-ship-off-floors`(`chilled|3층` 형식)에 기억 → 새로 나온 층은 기본 선택. ~~화면 미리보기는 항상 전체~~ → 2026-10-22부터 화면 미리보기도 선택한 층만 표시(라벨 "표시·저장할 층", 0개 선택 시 안내 문구). 엑셀은 여전히 전체
  - **모바일 최적화 (2026-10-28)**: 600px 이하에서만 적용(CSS `.ol-ship*`, PC 화면 변화 없음)
    - 입고일 목록 = 가로로 넘기는 날짜 칩 줄(세로 목록 220px 대신), 기간 합계 날짜 입력 2칸 나란히 + 빠른 버튼 아래 줄
    - 저장 버튼 2열 격자(A4로 저장은 한 줄 전체), 제목 머리말·발주 없는 제품·추가 발주·냉동 유통기한·안내 문구는 "⚙ 옵션"으로 접음(기본 접힘), 층 선택은 가로 스크롤 한 줄
    - 화면 미리보기 표: 최소 폭(600/640px) 해제 + 고정 열 폭(팩 50 / 박스 46 / 기한 76px), 글씨·여백 축소 → 가로 스크롤 없음. 저장용 사본(`print`)에는 `ol-ship-sheet` 클래스를 안 붙여 저장 이미지는 그대로
    - PNG 저장: 터치 기기(`pointer:coarse`)에서 2장 이상이면 냉동재고와 같은 `FrozenShotsSheet` 창(한 번에 공유 저장 / 장마다 ⬇ 저장, 라벨 = 날짜_층) — 연속 다운로드가 막혀 1장만 받아지던 문제 해결. 1장이면 바로 다운로드. PDF는 원래대로 한 파일
  - **출고장용 제품명 (같은 날)**: 사용자 요청 "출고장용 제품명도 따로" → `ol_products.ship_name`(TEXT, 빈 값 = 제품명 그대로) + RPC `ol_set_product_ship_name(hash, id, name)`. `ol_upsert_product` 시그니처는 그대로 두고 저장 직후 별도 호출(값이 바뀐 경우만). 마이그레이션 `setup_orders_shipname.sql`(setup_orders.sql에도 반영)
    - 제품 폼: 이미지용 제품명 아래 "출고장용 제품명" 칸. SQL 미실행이면 폼을 닫지 않고 빨간 안내(제품은 저장됨, 다시 저장해도 중복 추가 안 되게 `savedId` 사용)
    - 제품표: 제품명 아래 `🚚 {출고장용 이름}` 작게 표시, 검색에도 포함. 출고장 화면·이미지·엑셀은 `shipNameOf(p)` = 출고장용 이름 → 없으면 제품명
  - **입수량을 제품명 옆에 (같은 날)**: 사용자 요청 "입수량 열 따로 말고 이름 옆에 / 입수량" → 화면·이미지는 `{출고장 이름} / 6ea`(입수 부분 회색), 입수 열 삭제. 엑셀도 4열(A 제품명 / 입수 · B 총 팩수량 · C 박스수량 `=B/입수` · D 기한)
  - **제품명 숫자 강조 (같은 날)**: 화면·이미지에서 출고장 제품명 안의 숫자와 바로 뒤 g/kg 단위(`500g`, `1.5kg`, `1 kg`, 대소문자 무관)만 굵게(900)·검정으로 — `boldDigits`. 뒤의 `/ 6ea`(입수량)도 같은 굵기·검정(처음엔 회색이었음). 엑셀은 셀 일부만 굵게 하는 서식(리치 텍스트)을 xlsx-js-style이 지원하지 않아 그대로
    - 소비기한 표기 `2026/11/01` → `2026.11.01` (html2canvas가 "/"에서 글자를 나눠 그려 간격이 어긋남)
  - **제품명 글꼴 나눔스퀘어 (2026-10-21)**: 화면·이미지의 제품명 칸만 `NanumSquare`(jsdelivr `moonspam/NanumSquare@2.0`, 로드 실패 시 Pretendard). 굵기는 400/700/800만 있어 숫자 강조(900)는 800으로 표시. 엑셀은 그대로
  - **제품명·수량 가운데 정렬 (같은 날)**: 화면·이미지의 제품명 열(제목 + 칸)을 왼쪽 → 가운데, 총 팩수량·박스수량 열을 오른쪽 → 가운데 정렬. 엑셀은 그대로
  - **🗓 기간 합계 (같은 날)**: 사용자 요청 "기간 동안 발주가 얼마나 들어왔는지 합쳐서 보기" → 출고장 상단 `📅 하루 (입고일) / 🗓 기간 합계` 토글 (localStorage `ol-ship-mode`, 기간 `ol-ship-from`/`ol-ship-to`)
    - 기간 모드: 시작~종료 날짜 입력 + 빠른 버튼(최근 7/14/30일 — 종료일 기준, 저장된 전체). 입고예정일이 기간 안인 발주서를 `ol_list_orders(from,to)`로 일반 + 추가(체크 시) 모두 조회해 합침. SQL 변경 없음
    - `buildShipList(..., {merge:true})`: 소비기한을 무시하고 제품코드로만 합산 → 소비기한 열 없음(화면·이미지·엑셀 모두 3열). 냉동 기본 유통기한 옵션은 숨김
    - 제목 `쿠팡 10/14 (화) ~ 10/20 (월) 발주 합계`, 파일명 `출고리스트_{시작}~{종료}`. 층별 저장·업체 필터·저장할 층 선택은 그대로 동작
    - 왼쪽 입고일 목록을 누르면 하루 모드로 돌아감
    - 한계: 발주서는 입고일 기준 1달만 보관되므로 그보다 이전 기간은 합산 불가
- **❄ 냉동재고 탭 (2026-10-21 추가)**: 사용자 요청 — 냉동 재고를 수량·소비기한·위치로 관리 (해시 `#frozen`, 🚚 출고장 오른쪽)
  - **`setup_orders_frozen.sql`** (신규, 1회 실행 — setup_orders.sql 끝에도 반영): `ol_frozen_lots`(제품코드·제품명·수량·단위·소비기한·위치·입고일·메모 = 로트 1행) + `ol_frozen_txns`(입고/출고/수정/이동/삭제 이력, 로트 삭제돼도 남음, 365일 지나면 조회 때 정리). RLS + 정책 없음 → RPC만
  - RPC: `ol_list_frozen`(lots + 최근 이력 200건), `ol_upsert_frozen_lot`(p_id NULL = 입고 등록 — 같은 제품·소비기한·위치 로트가 있으면 수량 합침), `ol_frozen_change_qty`(＋입고/－출고, 출고로 0이 되면 로트 삭제, 재고 초과 출고 거부 `not_enough_stock`), `ol_frozen_relocate`(일부 수량만 옮기면 로트 분할, 도착 위치에 같은 로트 있으면 합침), `ol_delete_frozen_lot`
  - 화면: 요약 카드 5개(제품 수 / 총 수량(단위별) / 위치 수 / 소비기한 30일 이내 / 기한 지남 — 뒤 두 개는 클릭 시 필터) + 보기 전환 📦 제품별(제품 카드 + 소비기한 빠른 순 로트표, 제품 합계) / 📍 위치별 / ⏳ 소비기한순(localStorage `ol-fz-view`) + 기한·위치 칩 필터 + 검색 + 📥 엑셀(`냉동재고_{날짜}.xlsx`) + 접이식 🧾 입출고 이력
  - 소비기한 상태: 지남(빨강, 행 배경) / 30일 이내(주황) / 90일 이내(노랑) / 여유(초록), `D-n` 뱃지 (`FZ_SOON`/`FZ_WARN` 상수)
  - 행 버튼: ＋입고 / －출고(전량 버튼, 메모) / ⇄위치 이동(일부 수량 가능) / ✏수정 / 🗑삭제(confirm 대신 그 자리 확인)
  - 입고 등록 폼: 제품리스트에서 검색 선택(냉동 제품 먼저) 또는 이름 직접 입력, 단위 박스/팩/kg/개, 위치는 기존 위치 자동완성
  - **표시 이름 = 출고장용 이름 (같은 날)**: 제품코드가 제품리스트와 연결된 재고는 `shipNameOf(p)`(출고장용 이름 → 없으면 제품명)로 표시 — 카드·표·출고 창·이력·엑셀·정렬·입고 폼 검색 목록 모두. 불러올 때 `disp_name`을 붙이고 `fzName(l)`로 읽음. DB에는 원래 제품명 그대로 저장(이름은 제품리스트에서 바꾸면 바로 반영). 코드 없이 직접 입력한 재고는 입력한 이름 그대로
  - **이름 / 입수량 + 이력 2주 보관 (같은 날)**: 표시 이름을 `{출고장용 이름} / {입수}ea`(예: `한우양념불고기 800g / 10ea`)로 변경, 따로 있던 "입수 N" 보조 표시는 제거. 입출고 이력 보관 365일 → **14일**(`ol_list_frozen`의 정리 조건, 이력 헤더 "최근 2주"). 이미 SQL을 실행했다면 `setup_orders_frozen.sql`을 다시 실행해야 2주 정리가 적용됨(재실행 안전)
  - **🖼 이미지 저장 (같은 날)**: 툴바 버튼 → 화면 밖에 `FrozenPrintSheet`(820px 흰 종이, 버튼·메모·입고일·배경색 없음)를 그려 `saveShipPng`(html2canvas scale 3)로 `냉동재고_{날짜}.png` 저장. 지금 보기(제품별/위치별/소비기한순)와 필터·검색을 그대로 따름(필터가 있으면 제목 아래에 표기). 머리: "냉동재고 현황" + 날짜(요일) 기준 + 오른쪽 총 수량·제품 수·위치 수. 표: 회색 띠 = 제품(또는 위치) + 합계, 줄 = 소비기한 / 남은 기간 / 위치(또는 제품) / 수량. 색은 기한 지남(빨강 "지남 (D+n)")·30일 이내(주황)만, 나머지 D-n은 회색. 아래에 범례
  - **A4 세로 + 남은 기간 열 제거 (같은 날)**: `FrozenPrintSheet` → `FrozenPrintPages`. 쪽마다 794×1123px(A4 세로) 흰 종이, scale 3 → 쪽마다 PNG(`냉동재고_{날짜}_1쪽.png`…, 1쪽이면 번호 없음). 줄 높이 고정(`FZP` — 띠 46 / 줄 40px)으로 `fzPaginate`가 쪽 나눔: 띠는 다음 줄과 같은 쪽에만 두고, 쪽 첫머리가 제품(위치) 중간이면 띠를 "(이어서)"로 다시 표시. 2쪽부터는 작은 머리글 + 아래에 `n / 전체`. 남은 기간 열 삭제 → 기한 지남은 날짜 빨강 + "지남", 30일 이내는 주황. 긴 제품명·위치는 한 줄 말줄임
  - **이미지 긴 한 장으로 변경 (2026-10-23)**: 사용자 보고 "1페이지만 저장됨"(쪽마다 PNG를 연달아 내려받을 때 브라우저가 두 번째 파일부터 막은 것으로 추정) → A4 쪽 나눔(`fzPaginate`) 삭제, 폭 794px·높이는 내용만큼인 PNG 1장(`냉동재고_{날짜}.png`). 쪽 번호·"(이어서)" 머리글 없음. 너무 길면 캔버스 한도(약 32,000px)를 넘지 않게 배율을 3 → 최소 1까지 낮춤
    - 같은 날 사용자 요청으로 쪽별 저장도 복구: 버튼 2개 `🖼 긴 한 장` / `📄 쪽별로`. 쪽별은 `fzPaginate`(A4 세로 높이 기준 쪽 나눔, 2쪽부터 "(이어서)" 머리글 + `n / 전체`)로 나누되 쪽 높이를 고정하지 않아 내용이 짧은 쪽(마지막 쪽 등)은 아래 공백 없이 잘림. 파일 `냉동재고_{날짜}_{n}쪽.png`, 연달아 받을 때 브라우저 차단을 피하려고 700ms 간격. `FrozenPrintPages`에 `paged` prop
    - 모바일 대응 (같은 날): 사용자 보고 "모바일은 1쪽만" — 모바일 브라우저는 탭 한 번에 파일 하나만 받게 함. 터치 기기(`pointer:coarse`)에서 여러 쪽이면 이미지를 먼저 만든 뒤 `FrozenShotsSheet` 창 표시: `📤 N장 한 번에 저장`(Web Share API `navigator.share({files})`, 지원 기기에서만 — 공유 창에서 "이미지 저장") + 쪽마다 미리보기·⬇ 저장 버튼(길게 눌러 저장도 가능). PC는 기존대로 연달아 다운로드. 실제 휴대폰에서의 공유 동작은 미검증(PC 브라우저 모바일 흉내로 창·이미지 2장만 확인)
  - **수량 클릭 바로 수정 (2026-10-22)**: 세 보기의 수량 칸이 버튼(`FrozenQtyCell`) → 클릭하면 숫자 입력칸, Enter/바깥 클릭 저장, Esc 취소. 차이만큼 기존 `ol_frozen_change_qty`로 입고(+)/출고(−) 기록(메모 "수량 직접 수정"), 0으로 하면 로트 삭제. SQL 변경 없음
  - **입고 등록 위치 자동 입력 (2026-10-23)**: 위치 칩으로 특정 위치(예: 1층)를 보고 있을 때 ＋ 입고 등록을 누르면 위치 칸에 그 위치가 미리 채워짐(📍 전체 위치·위치 미지정이면 빈칸). 폼에서 바꿀 수 있음
  - **입고 폼 기존 소비기한 선택 (2026-10-23)**: 제품을 고르면 소비기한 칸 아래에 그 제품 재고에 이미 있는 소비기한이 칩으로 표시(빠른 날짜순, `2027.09.06 · 138박스`, 지금 위치에도 있으면 "· 이 위치", 위치 목록은 툴팁). 누르면 입력, 다시 누르면 해제. 직접 입력한 이름은 코드 없는 같은 이름 재고 기준. 수정 시엔 자기 로트 제외. `FrozenLotForm`에 `lots` prop 추가
  - **🗑 전체 삭제 (2026-10-22)**: 툴바 버튼 → 그 자리 확인("재고 N건을 모두 삭제할까요?") → 모든 로트를 기존 `ol_delete_frozen_lot`으로 5개씩 나눠 삭제(진행 N/M 표시, 필터와 무관하게 전체). 실패 건이 있으면 개수 알림 후 남은 재고 다시 표시. SQL 변경 없음. 입출고 이력은 남음(14일 후 자동 정리)
  - 한계: 발주서·출고장과 자동 연동 없음(출고는 수동). 여러 사람이 동시에 같은 로트를 출고하면 서버에서 수량 검증(FOR UPDATE)만 함
- **📤 냉동 출고 탭 (2026-10-28 추가)**: 사용자 요청 — 냉동재고와 발주서를 연동해 어떤 로트에서 몇 박스 나갈지 자동 계산 (해시 `#fzout`, ❄ 냉동재고 오른쪽, SQL 변경 없음)
  - 입고일(왼쪽 날짜 목록) 발주서 중 제품리스트 보관이 ❄ 냉동인 품목만, 상품코드별 합산 → 발주 수량(박스) = 팩수량 ÷ 입수량. 추가 발주 포함 옵션(`ol-ship-extra` 출고장과 공유), 업체 칩 필터
  - 재고 = `ol_list_frozen` 로트 중 같은 제품코드. 로트 단위가 박스면 그대로, 팩·개면 ÷입수량, kg 등은 배정 제외(회색)
  - 자동 배정 `buildFzOutPlan`: (먼저 꺼낼 위치 칩) → 소비기한 빠른 순. "한 로트에서 다 나가게 우선"(기본 켜짐)이면 혼자 다 채울 수 있는 첫 로트만 사용, 없으면 빠른 순으로 나눠 출고. "기한 지난 재고 제외"(기본 켜짐). 옵션 localStorage `ol-fzout-whole`/`ol-fzout-skipexp`/`ol-fzout-only`/`ol-fzout-loc`
  - 표(`FzOutSheet`, 이미지 양식 그대로): 냉동제품·발주 수량(노랑, 병합) | 소비기한 | 위치(위치별 색) | 재고 | 출고 수량. 부족이면 발주 칸에 "부족 N" + 상단 경고, 재고 없는 제품은 "냉동재고에 이 제품 재고 없음"
  - 출고 수량 칸 클릭 → 직접 수정(최대 = 로트 재고). 합계가 발주 수량을 넘으면 다른 로트(소비기한 늦은 것부터)에서 덜어냄 → 로트를 옮기는 것처럼 동작. 날짜별 localStorage `ol-fzout-man:{날짜}` = `{제품코드:{로트id:박스}}`, 제품별 ↺ / "모두 자동 배정"으로 되돌림
  - 저장: 🖼 이미지(A4, 아래 여백 자름) / 📄 PDF — 출고장 `shipA4Pages` 재사용(제품마다 `data-shipcut`, 제품 중간에서 쪽이 안 잘림), 📥 엑셀(`냉동출고_{날짜}.xlsx`, A·B 병합)
  - ✅ 출고 확정: 그 자리 확인 후 배정된 로트마다 `ol_frozen_change_qty`(−수량, 메모 "M/D 입고 발주 출고")로 차감 → 재고 다시 읽음. 확정 기록 `ol-fzout-done:{날짜}`(브라우저별)로 "이미 차감함" 안내 — 두 번 누르면 두 번 빠짐
  - **🏭 생산지점별 보기 (같은 날)**: 툴바 `📦 제품별 / 🏭 생산지점별` 전환(localStorage `ol-fzout-view`). 처음엔 재고 위치(1층·4층) 기준 층별로 만들었다가 사용자 요청으로 **제품리스트의 생산지점**(예: 3층 냉동 / 4층 냉동) 기준으로 변경. `fzOutSiteGroups`가 제품을 생산지점별로 묶음(`siteCmp` 순, 지점 없음은 맨 뒤) → 지점마다 카드(🏭 지점명 + 제품 수·출고·부족 + 발주 박스) 안에 제품별 보기와 같은 표(`FzOutTable` — 제품별 보기와 공통, 위치 열·출고 수량 클릭 수정 그대로). "표시·저장할 생산지점" 체크(끈 지점만 `ol-fzout-off`에 기억), 2곳 이상이면 `🖼 지점별로 저장 (N장)` = 지점마다 A4 이미지(제목에 지점명). 엑셀에 "생산지점별" 시트(생산지점 | 제품 | 발주 | 소비기한 | 위치 | 출고 + 지점 합계) 추가
  - **생산지점 카드 왼쪽 파란 선 제거 (2026-10-29)**: 사용자 요청 "너무 눈에 띈다" → `FzOutFloorSheet` 지점 카드의 `borderLeft:6px solid #1d4ed8` 삭제(다른 테두리와 같은 1px 회색). 화면·저장 이미지 모두 적용
  - **직접 수정·숨김 서버 저장 (2026-10-29)**: 사용자 보고 "고친 출고 수량이 커밋하거나 뭘 추가하면 원래대로 돌아간다" — 원인: 직접 수정(`ol-fzout-man:{날짜}`)·숨긴 제품(`ol-fzout-hidden`)이 브라우저 localStorage에만 있고 로트 id로만 기억 → 다른 주소(localhost 포트·배포 사이트)·기기에서 안 보이고, 로트가 다시 만들어지면(전체 삭제 후 재등록·위치 이동 분할) id가 바뀌어 사라짐
    - `ol_settings`에 `fzout_man:{날짜}` / `fzout_hidden` 저장(기존 `ol_set_setting`, SQL 변경 없음), 모듈 캐시 `fzManCache`로 탭 이동 후 바로 반영, localStorage는 사본(서버 값이 없을 때 예전 값 사용). 서버 저장 실패 시 ⚠ 안내
    - 직접 수정 값에 `__lots:{로트id:"소비기한|위치"}`를 함께 저장 → 로트 id가 없어지면 같은 제품·소비기한·위치 로트로 연결(`manualEff`). 수량 수정·되돌리기는 연결된 값 기준으로 다시 저장
    - 한계: 서버 값은 페이지를 열 때(마스터 로드) 읽음 — 다른 기기에서 고친 건 새로고침해야 보임. `fzout_man:*` 키는 날짜마다 쌓이고 1달 정리 대상 아님(용량 미미). 미리보기에서 저장 호출만 가로채 확인(실제 서버 저장·다른 기기 확인은 안 함)
  - **생산지점 카드 위 파란 층 머리줄 제거 (2026-10-29)**: 사용자 요청 → `FzOutFloorSheet` 지점 카드 위의 연파랑 배경 줄(🏭 층 이름 · N개 제품 · 출고/부족 · 파란 "발주 N박스" 뱃지) 삭제. 카드는 표만 남음. 층 이름은 지점별 저장 이미지 제목(`… · 3층 냉동`)에만 표시 — 여러 지점을 한 장으로 저장하면 지점 구분 글씨가 없음
  - **🙈 제품 숨기기 (2026-10-28)**: 화면 표의 제품명 옆 "🙈 숨기기" → 그 제품코드를 localStorage `ol-fzout-hidden`에 기억(날짜와 무관, 브라우저별). `fullPlan`(전체)에서 숨긴 제품을 뺀 `plan`을 표·생산지점별·이미지·PDF·엑셀·부족 경고·✅ 출고 확정 모두에 사용 → 숨긴 제품은 재고 차감도 안 됨. 표 위 "🙈 숨긴 제품 N개" 칩(👁 누르면 다시 보이기, 모두 보이기). 저장 이미지에는 숨기기 버튼 없음. SQL 변경 없음
  - 실데이터 10/31 확인: 사용자 예시 4제품 중 3개 자동 결과 일치, 구이용 13mm는 자동 = 8.23 1층(소비기한 순) / 예시 = 9.30 4층 → 직접 수정으로 맞춤. 출고 확정·이미지 저장은 실제 실행 안 함(재고 변경·다운로드 발생)
- **💰 판매가 (제품리스트 탭 안, 2026-10-22 추가)**: 사용자 요청 — 쿠팡 판매가·할인가가 자주 바뀌어 `고급진,에프앤비 쿠팡 판매링크.xlsx`를 손으로 고치던 것을 시스템으로
  - **자동 수집 불가 확인**: 쿠팡 상품 페이지 서버 요청 403(Akamai 차단), 스마트스토어 429 → 크롤러 대신 사람 브라우저에서 읽는 방식. 차단 우회는 하지 않음
  - **`setup_orders_prices.sql`** (신규, 1회 실행 — setup_orders.sql 끝에도 반영): `ol_prices`(업체·냉장/냉동·순서·SKU·상품명·바코드·입수·쿠팡링크·공급가·판매가·현재 할인가(NULL=할인 없음)·스토어링크·스토어가·메모·`price_checked_at`) + `ol_price_history`(가격 칸별 이전→변경, 방법 manual/import/capture, 180일 보관). 내부 함수 `ol__num`/`ol__apply_prices`(바뀐 칸만 이력 기록)/`ol__apply_info`, RPC `ol_list_prices`, `ol_upsert_price(hash,id,row JSONB)`, `ol_set_price_values(hash,id,values JSONB,source)`, `ol_import_prices(hash,rows)`, `ol_delete_price`
  - 엑셀 가져오기 매칭: (업체·보관·상품명) 같으면 갱신 → 없으면 SKU ID(엑셀·DB에서 하나뿐일 때만) → 없으면 추가. 원본 엑셀에 SKU 54737386이 서로 다른 선물세트 2개에 중복돼 있어 SKU 우선 매칭 시 덮어쓰기 발생 → 상품명 우선으로 변경, 겹치는 SKU는 업로드 메시지에 ⚠ 표시
  - 화면: 제품리스트 탭 오른쪽 위 `📦 제품 정보 / 💰 판매가` 전환(localStorage `ol-prod-view`, 기존 화면은 `ProductInfoView`로 이름만 변경). 요약 카드(판매 상품/할인 중(클릭 필터)/오늘 확인/7일 넘게 미확인), 시트 칩(업체(냉장/냉동)), 시트별 표 — 공급가·판매가·현재 할인가·스토어가는 **클릭 수정**(`PriceCell`, Enter/바깥 클릭 저장), 할인액·할인율 자동, 14일 안에 바뀐 가격 ▲(빨강)/▼(파랑), 확인일, 쿠팡↗/스토어↗ 링크, 수정 모달(이 상품 이력), 접이식 가격 변경 이력
  - `parsePriceWorkbook`: 시트명 `업체(냉장|냉동)`, '상품명' 있는 제목 행에서 칸 자동 탐지(첫 '판매가' = 쿠팡, 스토어 링크 뒤 '판매가' = 스토어가, 할인가 칸 없는 시트는 할인가 안 건드림). 원본 파일 4시트 66개 확인
  - `downloadPriceXlsx`: 원본과 같은 12칸(할인액 `=I-H` 수식, 링크 하이퍼링크, 할인 없으면 할인가 = 판매가) → `판매가_{날짜}.xlsx`. 왕복(내보내기→가져오기) 값 일치 확인
  - **🔖 가격 가져오기 버튼(북마클릿)**: `priceBookmarklet(현재 주소)` — 쿠팡/스마트스토어 상품 페이지에서 누르면 가격을 읽어(쿠팡: `.sales-price-amount`·`.prod-sale-price .total-price`·`.original-price-amount` 등 여러 선택자 + JSON-LD, 스토어: `discountedSalePrice`/`salePrice`) `orders.html?pricecap=…` 작은 창을 띄움 → `PriceCapture`가 링크의 vendorItemId → itemId → productId(스토어는 상품번호)로 상품을 찾고, 판매가/할인가를 확인·수정 후 Enter 저장(`source=capture`) → `BroadcastChannel("ol-prices")`로 열려 있는 판매가 탭 자동 새로고침, 창 자동 닫힘. 못 찾으면 상품 선택 + 그 링크를 상품에 저장 옵션
  - 한계: 북마크는 설치한 주소(실제 사이트)로 창을 띄우므로 localhost에서 설치하면 안 됨. 상품마다 페이지를 열고 버튼을 눌러야 함 → 아래 크롬 확장으로 보완
  - **쿠팡 가격 위치 (2026-10-22 실제 페이지 확인)**: `.price-container` 안 `.sales-price-amount` = 쿠팡판매가 → **판매가**, `.final-price-amount` = 와우할인 등 최종가 → **현재 할인가**, `.original-price-amount`(줄 그어진 기준가)는 사용 안 함. 할인 없는 상품은 최종가 칸만 있음 → 판매가 = 할인가 = 최종가. 엑셀 값과 3건 일치(닭갈비 13,800/12,800, 부채살 29,900/29,900, 돌돌말이 800g 13,970). 옵션 상품은 URL의 itemId로 해당 옵션 가격이 표시됨. 북마크 버튼도 이 규칙으로 수정(payload `sale`/`disc`)
  - **🔄 쿠팡 가격 전체 갱신 — 크롬 확장 프로그램 (같은 날)**: 서버 크롤링은 403으로 막혀 있고 우회는 하지 않으므로, 사용자 크롬이 페이지를 여는 방식
    - **`extensions/coupang-price/`** (MV3): `manifest.json`(권한 `scripting` + `https://www.coupang.com/*`, content script는 `ainsightlab.kr/orders.html`·localhost:8000), `bridge.js`(페이지 `postMessage({__olpage})` ↔ 확장 포트 `olprice`, 응답은 `{__olext}`), `background.js`(작업 목록을 하나씩 `chrome.tabs.create({active:false})` → 로드 완료 대기 → `executeScript(extractCoupangPrice)` 최대 6초 재시도 → 탭 닫기 → 간격(2~30초) 대기)
    - 보안 확인 감지(제목·본문 "Access Denied", captcha 요소) 시 그 탭을 앞으로 띄우고 `stopped/blocked`로 멈춤 — 자동으로 넘기지 않음. 요청 itemId와 열린 페이지 itemId가 다르면(옵션 품절 등) 저장하지 않고 실패 처리
    - 가격 저장은 확장이 아니라 페이지가 함(`ol_set_price_values`, source `capture`) → 확장에 Supabase 키 없음
    - 판매가 탭: 확장 감지(ping/pong), "🔄 쿠팡 가격 전체 갱신 (N개)" 카드(지금 보이는 필터 기준, 간격 2/3/5/8초 — localStorage `ol-price-gap`, 예상 시간), 진행 카드(진행 막대·읽는 중 상품·성공/가격 바뀜/실패, 중지, 보안 확인 시 "이어서 갱신", 바뀐 가격 전→후·실패 사유 목록), `ExtensionHelp`(파일 3개를 JSZip으로 묶어 `쿠팡가격갱신_확장프로그램.zip` 다운로드 + 설치 순서)
    - 검증: 추출 함수를 실제 쿠팡 페이지에서 실행해 값 일치 확인, 페이지 쪽은 가짜 확장 메시지로 66개 갱신·실패·보안 확인 멈춤·이어서 갱신 흐름 확인. 실제 확장 설치 상태의 동작은 미검증(사용자 크롬에서 첫 실행 필요)
    - **v1.1.0 — 쿠팡 접속 차단 대응 (같은 날)**: 사용자 보고 "✗ 가격을 찾지 못했습니다"가 다수 → 확인해 보니 3초 간격 연속 접속 후 쿠팡이 이 IP를 **"요청하신 페이지의 사용권한이 없습니다"** 화면(제목 "쿠팡!", Ref 번호)으로 일시 차단 — 잘 열리던 상품도 같은 화면. v1.0은 이 화면을 차단으로 인식 못 해 계속 다음 상품을 열었음. 변경: 차단 판정에 `/사용권한이\s*(없습니다|제한된)/` 추가, 상품 페이지가 아니면(메인으로 이동) "판매중지·링크 변경" 실패, **연속 3번 실패 시 멈춤**(`reason:"fails"`), 최소 간격 5초·기본 8초(선택 5/8/15/30초, localStorage `ol-price-gap2`). 페이지: 차단 시 "몇십 분~몇 시간 뒤 간격 15초 이상으로 이어서 갱신" 안내, 확장 버전이 `EXT_LATEST`보다 낮으면 새 파일 받으라는 경고, 설치 안내에 웨일(`whale://extensions`)·엣지 추가. 차단을 피하는 위장·우회 기능은 넣지 않음
    - 한계: PC 크롬이 켜져 있고 orders.html 판매가 탭이 열려 있어야 함(탭을 닫으면 중지). zip 받기는 `extensions/` 폴더가 배포(GitHub Pages)된 뒤에 동작. 쿠팡 화면 구조가 바뀌면 선택자 수정 필요(`extractCoupangPrice`)
  - **🔍 시장조사 (2026-10-22)**: 판매가 표에서 상품명 클릭 → 비슷한 쿠팡 상품들의 가격 비교 창(`MarketModal`). 쿠팡 공식 Open API(Wing)는 내 상품만 조회되고 할인가(와우·쿠폰 최종가)를 주지 않아(상품/프로모션 API 문서 확인) 확장 프로그램 방식 사용
    - **확장 v1.2.0**: `bridge.js`가 `{type:"search",query,reqId}`를 `chrome.runtime.sendMessage`로 넘기고 `searchResult`로 답함. `background.js` `readSearch`가 `https://www.coupang.com/np/search?q=…&listSize=36`을 뒤쪽 탭으로 열어 `extractCoupangSearch` 실행 후 닫음(검색 1번 = 페이지 1장, 동시에 1건만). 차단 화면이면 그 탭을 띄우고 `blocked`
    - `extractCoupangSearch`: 클래스명에 기대지 않고 `#product-list`(없으면 main) 안의 `/vp/products/` 링크 → 감싼 `li`(카드)에서 읽음. 가격 = "원"이 붙은 숫자 중 줄 안 그은 것 중 **글씨가 가장 큰 것**, 정상가 = 줄 그은 가격(DEL·line-through·base-price), `NN%` 할인율, `(1,234)` 리뷰 수, 와우/쿠폰 문맥 가격, `(100g당 1,234원)` 단위가격, 로켓 뱃지 alt, AD/광고, 품절. 숫자 바로 앞이 "당"/"배송비"/"적립"이면 제외. 상품을 못 찾으면 페이지 글씨 앞부분(`sample`)을 돌려줘 화면에 표시 — **실제 쿠팡 검색 화면으로는 아직 검증 못 함**(앱 내장 브라우저는 쿠팡이 차단, Claude in Chrome 미연결) → 흉내 낸 예시 화면 2종으로만 확인
    - **`setup_orders_market.sql`** (신규, 1회 실행 — setup_orders.sql 끝에도 반영): `ol_prices.market_query`(검색어) + `market_excluded`(JSONB, 제외한 쿠팡 productId) 컬럼, `ol_market_snaps`(price_id·query·items JSONB·created_at, 180일 보관, 상품 삭제 시 CASCADE). RPC `ol_save_market_snap`(저장 + 검색어 기억), `ol_list_market_snaps`(최근 30회), `ol_delete_market_snap`, `ol_set_market_prefs`(검색어/제외 목록 — NULL이면 안 바꿈). SQL 실행 전이면 결과는 화면에만 보이고 "저장 안 됨" 안내
    - 검색어 기본값 `defaultMarketQuery(name, vendor)`: 대괄호·괄호, 중량·수량, 기호, **내 업체명**(브랜드)을 빼고 앞 4단어. 창에서 고치면 상품별로 저장, ↺로 다시 만들기
    - 100g당 가격 `per100g`: 쿠팡 단위가격이 g/kg이면 그것, 아니면 `parseWeightG`(상품명 `500g, 2개`/`1kg*4`/`300g x 3팩`/`1,000g` → 총 g). 내 상품도 같은 방식(내 가격 = 할인가 ?? 판매가) → "N개 중 K위(싼 순)", 경쟁 상품 100g당이 내 것보다 싸면 빨강/비싸면 초록
    - 화면: 내 판매가·중량·100g당 / 검색어 + 🔍 쿠팡 검색 / 검색 기록 날짜 칩(기록 삭제) / 100g당 최저·중간값·판매가 범위 / 정렬(검색 순위·100g당·판매가·리뷰) + 광고 숨기기 / 표(순위·광고, 썸네일, 상품명↗·배송·품절·NEW·평점, 중량, 정상가, 판매가·할인율·전 검색 대비 ▲▼·와우/쿠폰가, 100g당, 리뷰, 제외/포함). 내 쿠팡 링크와 productId가 같으면 ★ 내 상품. 정렬·광고 숨기기는 localStorage `ol-mkt-sort`/`ol-mkt-noads`
    - **v1.2.1 (같은 날)**: 사용자 보고 "Could not establish connection. Receiving end does not exist." — `chrome.runtime.sendMessage`를 받는 백그라운드 리스너가 없을 때 나는 오류(백그라운드가 예전 파일이거나 다시 로드되지 않은 상태로 추정, 원인 미확정). 검색도 가격 갱신과 같은 **포트 연결**(`chrome.runtime.connect({name:"olsearch"})`, background `onConnect`)로 변경 + 연결이 끊기면 "chrome://extensions에서 ↻ 새로고침 후 페이지 새로고침" 안내를 표시. 페이지의 `EXT_LATEST`/`MARKET_EXT_MIN` = 1.2.1
    - 한계: 검색 결과 1페이지(최대 36개)만. 쿠팡 화면 구조가 바뀌면 `extractCoupangSearch` 수정 필요. 중량이 상품명에 없으면 100g당 계산 불가. 네이버 쇼핑(스마트스토어) 비교는 다음 단계
  - **시장조사 가격 기준 변경 (2026-10-26, 확장 v1.4.0)**: 사용자 보고 "가격을 잘못 불러온다" → 최종가 = **와우할인가**만 인정, 와우가 아닌 할인(즉시할인·쿠폰 등)은 무시하고 **정상가**로 봄
    - `extractCoupangSearch`: 와우 판단을 카드 전체가 아니라 그 가격만 들어 있는 가장 작은 묶음의 글씨(`와우`, 단 "로켓와우" 제외)·와우 뱃지 이미지·`wow` 클래스로 좁힘. 정상가 `base` = **와우가 아닌 판매가(크게 보이는 가격)** — 줄 그은 가격(예: 42,420원)은 쿠팡 "기준가"라 쓰지 않음(`listPrice`로만 보관, 사용자 확인: 고급진 시즈닝 부채살 판매가 = 정상가 = 29,900). `price` = 와우가 ?? 정상가, `rate` = 정상가 대비 와우 할인율(와우 없으면 null), 참고용 `salePrice`·`shownRate`
    - `soldOut`이 "품절임박"까지 품절로 잡던 문제 수정(`품절(?!임박)`)
    - 실제 쿠팡 검색 화면(비로그인)으로 14개 상품 확인 — 판매가 정상 추출. 비로그인이라 와우가 표시된 카드는 확인 못 함
    - orders.html: 판매가 칸에 와우면 "와우할인가" 표시, 정상가 취소선은 최종가가 더 쌀 때만. 중량은 쿠팡 단위가격 ÷ `salePrice`로 구하고 100g당은 최종가로 계산. 빠른 확인 "할인 없음" 판정도 새 필드에 맞춤
    - `EXT_LATEST`·`MARKET_EXT_MIN` = 1.4.0 → 확장 파일 다시 받아 설치해야 시장조사 동작. 예전 검색 기록은 옛 기준이라 다음 검색 때 ▲▼가 한 번 크게 나올 수 있음
  - **품절 확인 (2026-10-26, 확장 v1.5.0)**: 사용자 요청 — 판매가 탭에서 쿠팡 품절 상품 확인
    - **`setup_orders_stock.sql`** (신규, 1회 실행 — setup_orders.sql 끝에도 반영): `ol_prices.sold_out`(BOOLEAN, NULL = 미확인) / `sold_out_at`(처음 품절 확인 시각, 품절이 풀리면 NULL) / `stock_left`(품절임박 N개) / `stock_checked_at` + RPC `ol_set_price_stock(hash, id, sold_out, stock_left)`. `ol_list_prices`는 `row_to_json`이라 변경 없음
    - 확장 `extractCoupangPrice`: ① 페이지 데이터(`__next_f`)의 `"itemId":N … "soldOut":true/false` ② schema.org Offer `availability`(InStock/OutOfStock) ③ 구매 버튼(`.prod-buy-footer`/`.prod-buy-btn`) "일시품절" 순. 링크에 itemId가 없으면 JSON-LD `sku`(`상품번호-옵션번호`)에서 옵션 번호를 얻음. "품절임박•N개" 글씨 → `stock_left`. 품절이라 가격이 없으면 오류 대신 `{sale_price:null, sold_out:true}` 전달
    - 페이지: 🔄 쿠팡 가격 전체 갱신 결과에 `sold_out`이 있으면 `ol_set_price_stock` 저장(가격이 없으면 가격은 안 건드림). SQL 미실행이면 한 번만 안내. 요약 카드 "품절 N개 · 임박 N"(클릭 = 품절+임박만 보기), 상품명 옆 `⛔ 품절 · N일째` / `품절임박 N개` 뱃지, 품절 행 옅은 빨강, 시트 헤더 품절 수, 진행 카드에 "품절 N" + 품절됨/계속 품절/품절 풀림 줄
    - 확인: 실제 쿠팡 상품 페이지(판매 중, 품절임박 8개)에서 `soldOut:false`·`stockLeft:8`, itemId 없는 링크도 동일. 품절 상태는 데이터의 false를 true로 바꾼 흉내로만 확인 — **실제 품절 상품 페이지는 미검증**. 페이지는 저장 호출을 가로챈 가짜 결과로 확인
    - 한계: ⚡ 빠른 확인으로 "변동 없음" 처리된 상품은 품절 여부를 다시 확인하지 않음. 옵션이 품절돼 쿠팡이 다른 옵션으로 넘기면 기존처럼 "다른 옵션 페이지로 바뀌었습니다" 실패로 표시(품절로 저장 안 함)
  - **판매가가 와우할인가로 덮이던 문제 (2026-10-27, 확장 v1.5.1)**: 사용자 보고 — 쿠팡 8524135262(판매가 9,700 / 와우 8,700)가 판매가·할인가 모두 8,700. 가격 이력상 10/26엔 정상(9,700/8,700), 10/27 갱신에서 판매가만 8,700으로 바뀜 → 쿠팡판매가 칸(`.sales-price-amount`)이 와우할인 칸보다 늦게 그려졌을 때 최종가만 읽고 판매가를 최종가로 채운 것으로 판단
    - `extractCoupangPrice`: 페이지 데이터에서 `"salesPrice":{"displayType":"SALES",…"price":N` → 없으면 `"nonWowMemberPrice":{"price":N`을 `dataSales`로 읽음
    - `readPrice`: 최종가만 보이면 바로 끝내지 않고 3초(6회)까지 더 기다림. 판매가 = 화면 판매가 → `dataSales`(최종가 이상일 때만) → 최종가
    - 실제 페이지에서 판매가 칸이 없다고 가정해도 9,700/8,700 확인. 같은 날 다른 상품(id 32 등)도 판매가가 낮아졌으면 같은 원인일 수 있음 → 확장 다시 설치 후 갱신 필요
  - **예전 버전 확장으로 갱신 막기 (2026-10-28)**: 사용자 요청 — 확장 버전이 `EXT_LATEST`보다 낮으면(`extOld`) 🔄 전체 갱신·이어서 갱신·⚡ 빠른 확인을 시작하지 않고 🧩 설치 안내 창을 띄움. 창 맨 위에 빨간 "예전 버전이라 가격 갱신을 할 수 없습니다 + 새 파일 받아 덮어쓰기 → ↻ → 페이지 새로고침" 안내, 갱신 카드의 주황 경고도 빨강 "갱신이 막혀 있습니다"로. 🔍 시장조사는 기존 `MARKET_EXT_MIN` 기준 그대로. 확장 파일을 고칠 때마다 `EXT_LATEST`를 manifest 버전과 맞춰야 함(안 올리면 막히지 않고, 잘못 높이면 전원 막힘). JSX 컴파일만 확인(미리보기 브라우저 로컬 접속 실패)
  - **⚡ 빠른 확인 (2026-10-22, 확장 v1.3.0)**: 사용자 질문 "시장조사는 빠른데 전체 갱신은 왜 오래 걸리나" — 전체 갱신은 상품마다 페이지 1장 + 8초 간격(차단 방지)이라 66개 ≈ 13분, 검색은 페이지 1장에 수십 개
    - 흐름: 업체명(또는 "⚡ 빠른 확인 검색어" 칸, 쉼표 구분, localStorage `ol-fast-queries`)으로 쿠팡 검색 결과를 검색어당 최대 2페이지(`FAST_PAGES`, listSize 72, 페이지 사이 5초 `FAST_GAP_MS`) 읽음 → 내 상품을 쿠팡 productId로 맞춤 → **변동 없음**은 `ol_set_price_values(p_values:{}, source capture)`로 확인 시각만 갱신(값이 같으면 이력·가격은 안 바뀜, SQL 변경 없음) → 나머지만 "🔄 필요한 N개만 페이지 확인"(기존 전체 갱신 흐름 재사용)
    - **저장하는 가격은 항상 상품 페이지 값** — 검색 결과 값은 "바뀌었을 수 있는 상품"을 고르는 데만 사용. 검색 화면의 줄 그은 가격이 쿠팡판매가인지 기준가인지 확인할 수 없어(실제 쿠팡 미검증) 매핑을 가정하지 않는 방식으로 설계
    - 판정 `fastJudge`: 같은 링크를 여러 행이 공유 → 페이지 확인 / 검색에서 못 찾음·품절 표시 → 페이지 확인 / **기억된 검색 표시**(가격·정상가·와우·쿠폰·할인율·품절 `fastSigOf`)와 저장된 판매가·할인가가 지난번과 같음 → 변동 없음 / 할인 없음 + 검색에 가격 하나만 보이고 저장값과 같음 → 변동 없음 / 그 외 → 페이지 확인
    - 검색 표시 기억: localStorage `ol-fast-sig` `{행 id: {sig, S, D, at}}` — 빠른 확인 직후 페이지 확인에 성공하면 그때의 검색 표시를 기억(`fastFound` ref) → 다음부터 할인 상품도 바뀐 것만 확인. 브라우저별 저장이라 다른 PC에서는 처음부터
    - 확장: `readSearch(query, limit, page)` — `&page=N` 추가, bridge가 `page` 전달. `EXT_LATEST`·`FAST_EXT_MIN` = 1.3.0 (`MARKET_EXT_MIN`은 1.2.1 유지)
    - 실데이터 확인 결과: 판매가 66개 링크 모두 옵션 번호(itemId) 없음, 7개 productId를 2~3행이 공유(15행 — 예: 돌돌말이 우삼겹 500g/800g/1kg). 이 행들은 검색으로 구분할 수 없고, **상품 페이지 확인도 기본 옵션 가격 하나를 읽으므로 행마다 다른 가격이 맞게 들어가는지 의심됨** → 링크에 `?itemId=`를 붙이는 게 근본 해결(미조치)
    - 가짜 확장 응답으로 시험: 고급진 50개 중 46개 매칭, 변동 없음 24 / 페이지 확인 42, 페이지 확인 결과 1건 후 재실행 시 그 상품이 "변동 없음"으로 바뀜
- **비밀번호 없이 접근 (2026-10-13 변경)**: 사용자 요청으로 로그인 화면 제거. `setup_orders.sql`의 모든 `ol_*` RPC에서 `aps_assert_admin` 호출 삭제(`p_admin_hash` 파라미터는 시그니처 호환용으로만 남기고 무시), 클라이언트는 `""` 전달. 이미 이전 버전 SQL을 실행했다면 **파일 전체를 다시 실행**해야 함(재실행 안전). 결과: URL을 아는 누구나 제품/발주서 조회·수정·삭제 가능 — anon 키는 shared.js에 공개되어 있으므로 RPC 직접 호출도 가능

## 알려진 이슈
- KRX API (`data.krx.co.kr`) 차단됨 — fallback으로만 사용
- 네이버 섹터 매핑 첫 실행 시 ~60초 소요 (79개 업종 페이지 순차 조회)
- 테마 순위가 장 마감 후에도 변동됨 (뉴스 갱신 때문)
- 과대 낙폭 탭은 평일 15:00(장중, 현재 시세 기준) + close 모드(15:35/16:00, 확정 종가)에 갱신됨. 그 외 시간대에는 마지막 갱신 데이터 표시
- 재료 포착 탭은 close 모드(15:35/16:00) 하루 1회만 산출됨. 장중에는 전 거래일 데이터가 표시되며, `DART_API_KEY` 미설정 시 공시 원출처 없이 뉴스 추정으로만 동작
- 성과 추적(`catalyst_track`)은 `setup_catalyst_track.sql` 실행 이후 선정분부터만 쌓임 — 과거 추천은 진입가 스냅샷이 없어 소급 집계 불가

## 개발 서버
- `python -m http.server 8000` (launch.json 설정됨)
