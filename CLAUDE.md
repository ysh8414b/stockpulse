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

## 알려진 이슈
- KRX API (`data.krx.co.kr`) 차단됨 — fallback으로만 사용
- 네이버 섹터 매핑 첫 실행 시 ~60초 소요 (79개 업종 페이지 순차 조회)
- 테마 순위가 장 마감 후에도 변동됨 (뉴스 갱신 때문)
- 과대 낙폭 탭은 평일 15:00(장중, 현재 시세 기준) + close 모드(15:35/16:00, 확정 종가)에 갱신됨. 그 외 시간대에는 마지막 갱신 데이터 표시

## 개발 서버
- `python -m http.server 8000` (launch.json 설정됨)
