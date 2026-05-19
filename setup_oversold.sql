-- =============================================
-- 과대낙폭 탭용 테이블 SQL
-- 1) daily_prices: 종목별 일별 종가/거래대금/시총 누적 (MA20 계산용)
-- 2) oversold_stocks: 매일 close 모드에서 MA20 대비 -20% 이하 낙폭 종목 저장
-- =============================================

-- ─────────────────────────────────────────
-- daily_prices: 일별 종가 히스토리
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS daily_prices (
    code TEXT NOT NULL,                  -- 종목코드 (6자리)
    date TEXT NOT NULL,                  -- 거래일 (YYYY-MM-DD)
    close NUMERIC NOT NULL,              -- 종가
    trading_value BIGINT DEFAULT 0,      -- 거래대금 (원)
    market_cap BIGINT DEFAULT 0,         -- 시가총액 (원)
    PRIMARY KEY (code, date)
);

CREATE INDEX IF NOT EXISTS idx_daily_prices_code_date ON daily_prices(code, date DESC);
CREATE INDEX IF NOT EXISTS idx_daily_prices_date ON daily_prices(date);

ALTER TABLE daily_prices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read" ON daily_prices;
CREATE POLICY "Allow anon read" ON daily_prices
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Allow service role full access" ON daily_prices;
CREATE POLICY "Allow service role full access" ON daily_prices
    FOR ALL USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────
-- oversold_stocks: MA20 대비 -20% 이하 낙폭 종목 (close 모드에서 산출)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS oversold_stocks (
    id BIGSERIAL PRIMARY KEY,
    date TEXT NOT NULL,                  -- 산출일
    rank INT NOT NULL,                   -- 거래대금 순위 (1부터)
    code TEXT NOT NULL,                  -- 종목코드
    name TEXT NOT NULL,                  -- 종목명
    price NUMERIC NOT NULL,              -- 현재가 (종가)
    ma20 NUMERIC NOT NULL,               -- 20일 이동평균
    deviation NUMERIC NOT NULL,          -- 이격률 (%): (price - ma20) / ma20 * 100
    change_pct NUMERIC DEFAULT 0,        -- 당일 등락률 (%)
    trading_value BIGINT DEFAULT 0,      -- 거래대금 (원)
    market_cap BIGINT DEFAULT 0,         -- 시가총액 (원)
    market TEXT DEFAULT '',              -- KOSPI / KOSDAQ
    display_sector TEXT DEFAULT '',      -- 디스플레이 섹터
    tags JSONB DEFAULT '[]'::jsonb       -- 종목 태그 (테마/섹터)
);

CREATE INDEX IF NOT EXISTS idx_oversold_date_rank ON oversold_stocks(date, rank);
CREATE INDEX IF NOT EXISTS idx_oversold_date ON oversold_stocks(date);

ALTER TABLE oversold_stocks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read" ON oversold_stocks;
CREATE POLICY "Allow anon read" ON oversold_stocks
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Allow service role full access" ON oversold_stocks;
CREATE POLICY "Allow service role full access" ON oversold_stocks
    FOR ALL USING (true) WITH CHECK (true);
