-- =============================================
-- theme_history 테이블 생성
-- 매일 인기 테마 TOP 10을 보존하여 캘린더 뷰 제공
-- =============================================

CREATE TABLE IF NOT EXISTS theme_history (
    id BIGSERIAL PRIMARY KEY,
    date TEXT NOT NULL,              -- 날짜 (YYYY-MM-DD)
    rank INT NOT NULL,               -- 순위 (1~10)
    name TEXT NOT NULL,              -- 테마명
    change_pct TEXT DEFAULT '0.00%', -- 평균 등락률
    trend TEXT DEFAULT 'flat',       -- up / down / flat
    leading_stocks TEXT DEFAULT '',  -- 대장주 상위 3개 (Name:Code:±X.XX%, ...)
    up_count INT DEFAULT 0,          -- 상승 종목 수
    down_count INT DEFAULT 0,        -- 하락 종목 수
    flat_count INT DEFAULT 0         -- 보합 종목 수
);

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_theme_history_date_rank ON theme_history(date, rank);
CREATE INDEX IF NOT EXISTS idx_theme_history_date ON theme_history(date);

-- RLS
ALTER TABLE theme_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow anon read" ON theme_history
    FOR SELECT USING (true);
CREATE POLICY "Allow service role full access" ON theme_history
    FOR ALL USING (true) WITH CHECK (true);
