-- =============================================
-- 주도주 배팅 성과 추적 (leader_track)
--
-- 주도 테마: 같은 테마 안에 '당일 +10% 이상 · 거래대금 1,000억 이상' 종목이
--            대장 포함 3개 이상 (= 개별 종목이 아니라 테마가 통째로 오른 날)
-- 주도주:    그 테마에서 상승률 + 거래대금 점수가 가장 높은 종목 (대장)
-- 편입:      주도 테마를 강한 순으로 최대 3개, 테마마다 대장 1종목
--            (close 모드 15:35/16:00, entry_price = 당일 종가)
-- 마감:      매 거래일 종가가 10일 이동평균선 아래로 내려가면 매도 (익절·손절선 없음)
--            매도 시 수익률 > 0 이면 win(익절), 아니면 loss(손절)
--
-- 1회 실행. 재실행 안전 (IF NOT EXISTS).
-- =============================================

CREATE TABLE IF NOT EXISTS leader_track (
    id BIGSERIAL PRIMARY KEY,

    -- ── 편입 시점 스냅샷 ──
    pick_date TEXT NOT NULL,                 -- 선정일 (YYYY-MM-DD)
    code TEXT NOT NULL,
    name TEXT DEFAULT '',
    market TEXT DEFAULT '',
    display_sector TEXT DEFAULT '',
    rank INT DEFAULT 0,                      -- 그날 주도 테마 순위 (1~3)
    change_pct NUMERIC DEFAULT 0,            -- 선정일 등락률 (%)
    trading_value BIGINT DEFAULT 0,          -- 선정일 거래대금 (원)
    market_cap BIGINT DEFAULT 0,
    theme_name TEXT DEFAULT '',              -- 주도 테마
    theme_count INT DEFAULT 0,               -- 조건 충족 동반 상승 종목 수 (대장 포함)
    theme_avg_pct NUMERIC DEFAULT 0,         -- 충족 종목 평균 등락률 (%)
    theme_stocks JSONB DEFAULT '[]'::jsonb,  -- 충족 종목 [{name, code, change_pct, trading_value}]
    other_themes JSONB DEFAULT '[]'::jsonb,  -- 같은 대장이 이끈 다른 주도 테마 이름들
    news_list JSONB DEFAULT '[]'::jsonb,     -- 선정일 테마 뉴스 [{title, url}] (최대 5건)
    entry_price NUMERIC NOT NULL,            -- 선정일 종가 = 가상 매수단가

    -- ── 추적 상태 (매 거래일 갱신) ──
    last_price NUMERIC DEFAULT 0,
    last_date TEXT DEFAULT '',
    days_tracked INT DEFAULT 0,
    ret_cum NUMERIC DEFAULT 0,
    max_ret NUMERIC DEFAULT 0,
    min_ret NUMERIC DEFAULT 0,
    last_ma NUMERIC,                         -- 최근 갱신일의 10일 이동평균 (매도 기준선)

    -- ── 마감 결과 ──
    status TEXT DEFAULT 'open',              -- open | closed
    result TEXT,                             -- win(익절) | loss(손절) | NULL
    close_date TEXT,
    close_price NUMERIC,
    close_ret NUMERIC,
    hold_days INT,

    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 이미 예전 버전으로 테이블을 만들었다면 컬럼만 추가 (재실행 안전)
ALTER TABLE leader_track ADD COLUMN IF NOT EXISTS last_ma NUMERIC;

CREATE UNIQUE INDEX IF NOT EXISTS idx_leader_track_pick_code
    ON leader_track(pick_date, code);
CREATE INDEX IF NOT EXISTS idx_leader_track_pick_date
    ON leader_track(pick_date DESC);
CREATE INDEX IF NOT EXISTS idx_leader_track_status
    ON leader_track(status);

ALTER TABLE leader_track ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read" ON leader_track;
CREATE POLICY "Allow anon read" ON leader_track
    FOR SELECT USING (true);
-- 쓰기는 크롤러의 service role 키로만 (RLS 우회). anon 쓰기 정책은 만들지 않는다.
