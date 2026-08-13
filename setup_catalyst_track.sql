-- =============================================
-- 재료 포착 종목 성과 추적 (catalyst_track)
--
-- 목적: "그날 재료 포착 TOP 10에 뜬 종목을 그날 종가에 샀다면
--        지금 수익률이 얼마인가" 를 종목별로 누적 기록한다.
--
-- 시드:  close 모드에서 재료 포착 TOP 10 산출 직후 (entry_price = 당일 종가)
-- 갱신:  이후 매 close 모드마다 현재가로 누적 수익률/최고/최저 갱신
-- 마감:  추적 20거래일 경과 시 status='closed' (그 뒤로는 갱신 안 함)
-- =============================================

CREATE TABLE IF NOT EXISTS catalyst_track (
    id BIGSERIAL PRIMARY KEY,

    -- ── 편입 시점 스냅샷 (이후 절대 변하지 않음) ──
    pick_date TEXT NOT NULL,                 -- 재료 포착에 선정된 날 (YYYY-MM-DD)
    code TEXT NOT NULL,
    name TEXT DEFAULT '',
    market TEXT DEFAULT '',
    display_sector TEXT DEFAULT '',
    rank INT DEFAULT 0,                      -- 그날의 순위 (1~10)
    total_score NUMERIC DEFAULT 0,           -- 그날의 종합 점수
    catalyst_type TEXT DEFAULT '',           -- 공급계약 / 수주 / 임상 ...
    catalyst_source TEXT DEFAULT '',         -- DART공시 / 거래소공시 / 언론 ...
    catalyst_amount NUMERIC DEFAULT 0,       -- 계약 규모 (억원). 0 = 미확인
    entry_price NUMERIC NOT NULL,            -- 선정일 종가 = 가상 매수단가

    -- ── 추적 상태 (매 거래일 갱신) ──
    last_price NUMERIC DEFAULT 0,            -- 최근 종가
    last_date TEXT DEFAULT '',               -- 최근 갱신일 (중복 갱신 방지 키)
    days_tracked INT DEFAULT 0,              -- 선정일 이후 경과 거래일 수

    ret_cum NUMERIC DEFAULT 0,               -- 진입가 대비 누적 수익률 (%)
    ret_d1 NUMERIC,                          -- D+1 수익률 (도달 전 NULL)
    ret_d5 NUMERIC,                          -- D+5
    ret_d10 NUMERIC,                         -- D+10
    ret_d20 NUMERIC,                         -- D+20

    max_price NUMERIC DEFAULT 0,             -- 추적 중 최고가
    min_price NUMERIC DEFAULT 0,             -- 추적 중 최저가
    max_ret NUMERIC DEFAULT 0,               -- 최고 수익률 (%) — 언제 팔았으면 최선이었나
    min_ret NUMERIC DEFAULT 0,               -- 최저 수익률 (%) — 최대 낙폭(MDD)

    status TEXT DEFAULT 'open',              -- open | closed (20거래일 경과)
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 같은 날 같은 종목이 중복 편입되지 않도록 (재실행 안전)
CREATE UNIQUE INDEX IF NOT EXISTS idx_catalyst_track_pick_code
    ON catalyst_track(pick_date, code);
CREATE INDEX IF NOT EXISTS idx_catalyst_track_pick_date
    ON catalyst_track(pick_date DESC);
CREATE INDEX IF NOT EXISTS idx_catalyst_track_status
    ON catalyst_track(status);
CREATE INDEX IF NOT EXISTS idx_catalyst_track_code
    ON catalyst_track(code);

ALTER TABLE catalyst_track ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read" ON catalyst_track;
CREATE POLICY "Allow anon read" ON catalyst_track
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Allow service role full access" ON catalyst_track;
CREATE POLICY "Allow service role full access" ON catalyst_track
    FOR ALL USING (true) WITH CHECK (true);
