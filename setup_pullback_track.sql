-- =============================================
-- 급등주 급락 매수 성과 추적 (pullback_track)
--
-- 목적: "+10% 이상 · 거래대금 3,000억 이상 터진 종목이 이후 20거래일 안에
--        그 급등일 시가보다 아래(종가 기준)로 내려오면 그 종가에 매수 →
--        +10% 익절 / -10% 손절 중 어느 쪽에 먼저 닿았나" 를 기록한다.
--
-- 1) 감시(watch): close 모드에서 오늘 조건 충족 종목을 등록 (signal_open = 급등일 시가)
-- 2) 진입(open):  이후 거래일 종가 < signal_open 이면 그 종가에 매수 (pick_date = 진입일)
-- 3) 만료(expired): 20거래일 동안 진입 조건이 안 나오면 감시 종료
-- 4) 마감(closed): 진입 후 종가 수익률 +10% 이상 win / -10% 이하 loss
--
-- 1회 실행. 재실행 안전 (IF NOT EXISTS).
-- =============================================

CREATE TABLE IF NOT EXISTS pullback_track (
    id BIGSERIAL PRIMARY KEY,

    -- ── 급등일(신호) 스냅샷 ──
    signal_date TEXT NOT NULL,               -- 급등일 (YYYY-MM-DD)
    code TEXT NOT NULL,
    name TEXT DEFAULT '',
    market TEXT DEFAULT '',
    display_sector TEXT DEFAULT '',
    rank INT DEFAULT 0,                      -- 그날 신호 순위 (거래대금 순)
    signal_open NUMERIC NOT NULL,            -- 급등일 시가 = 진입 기준선
    signal_close NUMERIC DEFAULT 0,          -- 급등일 종가
    signal_change NUMERIC DEFAULT 0,         -- 급등일 등락률 (%)
    trading_value BIGINT DEFAULT 0,          -- 급등일 거래대금 (원)
    market_cap BIGINT DEFAULT 0,
    watch_days INT DEFAULT 0,                -- 급등일 이후 지난 거래일 수 (감시 중 / 진입까지)

    -- ── 진입 (status=open 부터) ──
    pick_date TEXT,                          -- 진입일 (NULL = 아직 감시 중 / 만료)
    entry_price NUMERIC,                     -- 진입일 종가 = 가상 매수단가

    -- ── 추적 상태 ──
    last_price NUMERIC DEFAULT 0,
    last_date TEXT DEFAULT '',               -- 최근 갱신일 (중복 갱신 방지 키)
    days_tracked INT DEFAULT 0,              -- 진입 이후 경과 거래일 수
    ret_cum NUMERIC DEFAULT 0,
    max_ret NUMERIC DEFAULT 0,
    min_ret NUMERIC DEFAULT 0,

    -- ── 결과 ──
    status TEXT DEFAULT 'watch',             -- watch | open | closed | expired
    result TEXT,                             -- win | loss | NULL
    close_date TEXT,
    close_price NUMERIC,
    close_ret NUMERIC,
    hold_days INT,

    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pullback_track_sig_code
    ON pullback_track(signal_date, code);
CREATE INDEX IF NOT EXISTS idx_pullback_track_pick_date
    ON pullback_track(pick_date DESC);
CREATE INDEX IF NOT EXISTS idx_pullback_track_status
    ON pullback_track(status);

ALTER TABLE pullback_track ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read" ON pullback_track;
CREATE POLICY "Allow anon read" ON pullback_track
    FOR SELECT USING (true);
-- 쓰기는 크롤러의 service role 키로만.
