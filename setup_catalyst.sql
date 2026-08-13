-- =============================================
-- 재료 포착 TOP 10 (이슈 종목 탭 대체) 테이블
--
-- 목적: '좋은 종목'이 아니라
--       '좋은 재료가 발생했는데 아직 주가에 충분히 반영되지 않은 종목' 을 찾는다.
--
-- 산출 시점: 장 마감 후 close 모드(15:35 / 16:00) 1회
-- 데이터 소스: DART 공시(원출처) + 네이버 뉴스 + daily_prices(수익률/거래대금) + 네이버 투자자 동향
-- =============================================

CREATE TABLE IF NOT EXISTS catalyst_stocks (
    id BIGSERIAL PRIMARY KEY,
    date TEXT NOT NULL,                      -- 산출일 (YYYY-MM-DD)
    rank INT NOT NULL,                       -- 종합점수 순위 (1~10)

    -- ── 종목 기본 ──
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    market TEXT DEFAULT '',                  -- KOSPI / KOSDAQ
    display_sector TEXT DEFAULT '',          -- 디스플레이 섹터
    tags JSONB DEFAULT '[]'::jsonb,          -- 테마/섹터 태그
    market_cap BIGINT DEFAULT 0,             -- 시가총액 (원)
    price NUMERIC DEFAULT 0,                 -- 현재가(종가)

    -- ── ③ 주가 반영 정도 ──
    ret_1d NUMERIC DEFAULT 0,                -- 1일 수익률 (%)
    ret_5d NUMERIC DEFAULT 0,                -- 5거래일 수익률 (%)
    ret_20d NUMERIC DEFAULT 0,               -- 20거래일 수익률 (%)

    -- ── ④ 거래대금/거래량 ──
    trading_value BIGINT DEFAULT 0,          -- 당일 거래대금 (원)
    tv_avg20 BIGINT DEFAULT 0,               -- 20일 평균 거래대금 (원)
    tv_ratio NUMERIC DEFAULT 0,              -- 평소 대비 배수 (당일 / 20일 평균)

    -- ── ⑤ 수급 (최근 5거래일 누적, 억원) ──
    foreign_net_5d NUMERIC DEFAULT 0,        -- 외국인 순매수
    institution_net_5d NUMERIC DEFAULT 0,    -- 기관 순매수
    individual_net_5d NUMERIC DEFAULT 0,     -- 개인 순매수
    foreign_ratio NUMERIC DEFAULT 0,         -- 외국인 보유비율 (%)

    -- ── ①② 재료 (원출처 우선) ──
    catalyst_type TEXT DEFAULT '',           -- 공급계약 / 수주 / 설비투자 / M&A / 임상 / 기술이전 ...
    catalyst_title TEXT DEFAULT '',          -- 공시명 또는 뉴스 제목
    catalyst_source TEXT DEFAULT '',         -- DART공시 / 거래소공시 / 언론 / 미확인
    catalyst_date TEXT DEFAULT '',           -- 재료 발생일 (YYYY-MM-DD)
    catalyst_url TEXT DEFAULT '',            -- 원출처 링크 (DART 뷰어 또는 기사)
    catalyst_amount NUMERIC DEFAULT 0,       -- 계약/투자 규모 (억원). 0 = 미확인
    catalyst_amount_src TEXT DEFAULT '',     -- 금액 출처 문장 (검증용). 빈 값 = 미확인
    disclosures TEXT DEFAULT '[]',           -- 최근 5일 재료성 공시 목록 (JSON)
    news_list TEXT DEFAULT '[]',             -- 관련 뉴스 목록 (JSON)

    -- ── 점수 (100점 만점) ──
    score_news NUMERIC DEFAULT 0,            -- 뉴스의 질/신뢰도 (25)
    score_value NUMERIC DEFAULT 0,           -- 기업가치에 미치는 영향 (25)
    score_unpriced NUMERIC DEFAULT 0,        -- 주가 미반영 정도 (20)
    score_flow NUMERIC DEFAULT 0,            -- 거래대금/수급 (15)
    score_momentum NUMERIC DEFAULT 0,        -- 향후 추가 모멘텀 (15)
    total_score NUMERIC DEFAULT 0,

    -- ── AI 설명 (종목당 3문장) ──
    why_now TEXT DEFAULT '',                 -- 왜 지금 이 종목을 보는지
    catalyst_impact TEXT DEFAULT '',         -- 어떤 뉴스가 주가를 움직일 수 있는지
    priced_in TEXT DEFAULT '',               -- 이미 얼마나 주가에 반영됐는지

    generated_time TEXT DEFAULT ''           -- 산출 시각 (KST, HH:MM)
);

CREATE INDEX IF NOT EXISTS idx_catalyst_date_rank ON catalyst_stocks(date, rank);
CREATE INDEX IF NOT EXISTS idx_catalyst_date ON catalyst_stocks(date);
CREATE INDEX IF NOT EXISTS idx_catalyst_code ON catalyst_stocks(code);

ALTER TABLE catalyst_stocks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read" ON catalyst_stocks;
CREATE POLICY "Allow anon read" ON catalyst_stocks
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Allow service role full access" ON catalyst_stocks;
CREATE POLICY "Allow service role full access" ON catalyst_stocks
    FOR ALL USING (true) WITH CHECK (true);
