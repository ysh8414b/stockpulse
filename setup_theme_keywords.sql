-- =============================================
-- theme_keywords 테이블 생성
-- 테마별 뉴스 매칭 키워드를 DB에서 관리
-- =============================================

CREATE TABLE IF NOT EXISTS theme_keywords (
    id BIGSERIAL PRIMARY KEY,
    theme TEXT NOT NULL,           -- 테마명 (예: "방산", "반도체")
    keyword TEXT NOT NULL,         -- 키워드 (예: "이란", "우크라이나")
    enabled BOOLEAN DEFAULT true,  -- 활성/비활성 토글
    memo TEXT DEFAULT '',          -- 메모 (왜 추가했는지 등)
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(theme, keyword)         -- 중복 방지
);

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_theme_keywords_theme ON theme_keywords(theme);
CREATE INDEX IF NOT EXISTS idx_theme_keywords_enabled ON theme_keywords(enabled);

-- RLS 비활성화 (service_role key 사용하므로)
ALTER TABLE theme_keywords ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow service role full access" ON theme_keywords
    FOR ALL USING (true) WITH CHECK (true);

-- =============================================
-- 초기 데이터: 코드에 없는 추가 키워드만 INSERT
-- (코드의 NEWS_THEME_KEYWORDS와 DB가 병합되므로
--  여기엔 "추가분"만 넣으면 됨)
-- =============================================

-- 방산: 지정학 이슈 키워드
INSERT INTO theme_keywords (theme, keyword, memo) VALUES
    ('방산', '이란', '미국-이란 분쟁 2026'),
    ('방산', '중동', '중동 분쟁 시 방산주 연동'),
    ('방산', '전쟁', '전쟁 키워드 - 방산 트리거'),
    ('방산', '휴전', '휴전/종전 뉴스도 방산 관련'),
    ('방산', '북한', '북한 도발 시 방산주 급등'),
    ('방산', '핵실험', '북한 핵실험 방산 트리거'),
    ('방산', '안보', '안보 관련 뉴스')
ON CONFLICT (theme, keyword) DO NOTHING;


-- =============================================
-- all_themes 테이블 생성
-- 전체 테마 데이터 (인기 TOP 10 + 나머지 테마)
-- =============================================

CREATE TABLE IF NOT EXISTS all_themes (
    id BIGSERIAL PRIMARY KEY,
    rank INT,                          -- 등락률 순위
    name TEXT NOT NULL,                -- 테마명
    change_pct TEXT,                   -- 평균 등락률 ("+2.35%")
    up_count INT DEFAULT 0,            -- 상승 종목 수
    flat_count INT DEFAULT 0,          -- 보합 종목 수
    down_count INT DEFAULT 0,          -- 하락 종목 수
    leading_stocks TEXT,               -- 상위 종목 ("name:code:pct, ...")
    stock_count INT DEFAULT 0,         -- 전체 종목 수
    trend TEXT DEFAULT 'flat',         -- "up" | "flat" | "down"
    is_top BOOLEAN DEFAULT false,      -- 인기 TOP 10 여부
    date DATE,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_all_themes_date ON all_themes(date);
CREATE INDEX IF NOT EXISTS idx_all_themes_is_top ON all_themes(is_top);

ALTER TABLE all_themes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow service role full access" ON all_themes
    FOR ALL USING (true) WITH CHECK (true);


-- =============================================
-- stock_analysis 테이블 생성
-- 일간 종목 리포트 (AI 3축 분석)
-- =============================================

CREATE TABLE IF NOT EXISTS stock_analysis (
    id BIGSERIAL PRIMARY KEY,
    date DATE NOT NULL,                -- 분석 날짜
    market_context TEXT,               -- 시장 맥락 한 줄
    stocks JSONB,                      -- 종목별 분석 JSON 배열
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stock_analysis_date ON stock_analysis(date);

ALTER TABLE stock_analysis ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow service role full access" ON stock_analysis
    FOR ALL USING (true) WITH CHECK (true);
