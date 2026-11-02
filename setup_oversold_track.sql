-- =============================================
-- 과대 낙폭 종목 성과 추적 (oversold_track)
--
-- 목적: "엔벨로프 20 하단을 깬 종목(종가가 MA20 대비 -20% 이하 +
--        그날 거래대금 1,000억 이상)을 그날 종가에 샀다면
--        +10% 익절 / -10% 손절 중 어느 쪽에 먼저 닿았나" 를 기록한다.
--
-- 편입:  close 모드(15:35/16:00)에서 과대 낙폭 산출 직후 (entry_price = 당일 종가)
-- 갱신:  이후 매 거래일 close 모드에서 종가 기준 수익률 계산
-- 마감:  종가 수익률 +10% 이상 → result='win'(익절)
--        종가 수익률 -10% 이하 → result='loss'(손절)
--        → status='closed', close_date / close_ret / hold_days 기록
--
-- 1회 실행. 재실행 안전 (IF NOT EXISTS).
-- =============================================

CREATE TABLE IF NOT EXISTS oversold_track (
    id BIGSERIAL PRIMARY KEY,

    -- ── 편입 시점 스냅샷 (이후 변하지 않음) ──
    pick_date TEXT NOT NULL,                 -- 선정일 (YYYY-MM-DD)
    code TEXT NOT NULL,
    name TEXT DEFAULT '',
    market TEXT DEFAULT '',
    display_sector TEXT DEFAULT '',
    rank INT DEFAULT 0,                      -- 그날 과대 낙폭 순위 (거래대금 순)
    ma20 NUMERIC DEFAULT 0,                  -- 선정일 MA20
    deviation NUMERIC DEFAULT 0,             -- 선정일 MA20 이격률 (%)
    trading_value BIGINT DEFAULT 0,          -- 선정일 거래대금 (원)
    market_cap BIGINT DEFAULT 0,
    entry_price NUMERIC NOT NULL,            -- 선정일 종가 = 가상 매수단가

    -- ── 추적 상태 (매 거래일 갱신) ──
    last_price NUMERIC DEFAULT 0,            -- 최근 종가
    last_date TEXT DEFAULT '',               -- 최근 갱신일 (중복 갱신 방지 키)
    days_tracked INT DEFAULT 0,              -- 선정일 이후 경과 거래일 수
    ret_cum NUMERIC DEFAULT 0,               -- 현재(마감 시 마감) 수익률 (%)
    max_ret NUMERIC DEFAULT 0,               -- 추적 중 최고 종가 수익률 (%)
    min_ret NUMERIC DEFAULT 0,               -- 추적 중 최저 종가 수익률 (%)

    -- ── 마감 결과 ──
    status TEXT DEFAULT 'open',              -- open | closed
    result TEXT,                             -- win(익절) | loss(손절) | NULL(진행 중)
    close_date TEXT,                         -- 마감일
    close_price NUMERIC,                     -- 마감 종가
    close_ret NUMERIC,                       -- 마감 수익률 (%)
    hold_days INT,                           -- 보유 거래일 수

    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_oversold_track_pick_code
    ON oversold_track(pick_date, code);
CREATE INDEX IF NOT EXISTS idx_oversold_track_pick_date
    ON oversold_track(pick_date DESC);
CREATE INDEX IF NOT EXISTS idx_oversold_track_status
    ON oversold_track(status);

ALTER TABLE oversold_track ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read" ON oversold_track;
CREATE POLICY "Allow anon read" ON oversold_track
    FOR SELECT USING (true);
-- 쓰기는 크롤러의 service role 키로만 (service role은 RLS를 우회하므로 별도 정책 불필요).
-- anon(공개 키)에 쓰기 정책을 만들지 않는다.
