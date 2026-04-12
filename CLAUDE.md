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

## 알려진 이슈
- KRX API (`data.krx.co.kr`) 차단됨 — fallback으로만 사용
- 네이버 섹터 매핑 첫 실행 시 ~60초 소요 (79개 업종 페이지 순차 조회)
- 테마 순위가 장 마감 후에도 변동됨 (뉴스 갱신 때문)

## 개발 서버
- `python -m http.server 8000` (launch.json 설정됨)
