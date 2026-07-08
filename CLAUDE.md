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

## 알려진 이슈
- KRX API (`data.krx.co.kr`) 차단됨 — fallback으로만 사용
- 네이버 섹터 매핑 첫 실행 시 ~60초 소요 (79개 업종 페이지 순차 조회)
- 테마 순위가 장 마감 후에도 변동됨 (뉴스 갱신 때문)
- 과대 낙폭 탭은 평일 15:00(장중, 현재 시세 기준) + close 모드(15:35/16:00, 확정 종가)에 갱신됨. 그 외 시간대에는 마지막 갱신 데이터 표시

## 개발 서버
- `python -m http.server 8000` (launch.json 설정됨)
