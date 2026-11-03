-- =============================================
-- 급등 종목 AI (surge_ai.py → index.html "급등 AI" 탭)
--
-- 1) AI 브리핑 데이터 완전 삭제 (ai_summary 테이블 DROP)
-- 2) surge_stocks      : 매일 +5% 이상 & 거래대금 3,000억 이상 종목 (거래대금 상위 10)
--                        상승 원인(시황·차트) + 딥러닝 예측 + 이후 실제 수익률
-- 3) surge_model_runs  : 모델 학습·시험 성적 기록
--
-- 1회 실행. 재실행 안전.
-- 쓰기는 GitHub Actions(service role)만, 읽기는 anon 허용.
-- =============================================

-- ── 1) AI 브리핑 데이터 삭제 ──
DROP TABLE IF EXISTS ai_summary CASCADE;

-- ── 2) 급등 종목 ──
CREATE TABLE IF NOT EXISTS surge_stocks (
    id BIGSERIAL PRIMARY KEY,
    date TEXT NOT NULL,                     -- 선정일 (YYYY-MM-DD)
    rank INT DEFAULT 0,                     -- 그날 거래대금 순위
    code TEXT NOT NULL,
    name TEXT DEFAULT '',
    market TEXT DEFAULT '',
    display_sector TEXT DEFAULT '',
    price NUMERIC DEFAULT 0,                -- 선정일 종가
    change_pct NUMERIC DEFAULT 0,
    trading_value BIGINT DEFAULT 0,         -- 원
    market_cap BIGINT DEFAULT 0,            -- 원
    vol_ratio NUMERIC DEFAULT 0,            -- 거래량 ÷ 20일 평균
    surge_type TEXT DEFAULT '',             -- 개별 재료형 / 테마 동반형 / 섹터 동반형 / 시장 동반형 / 기술적 돌파형
    main_cause TEXT DEFAULT '',             -- 한 줄 요약
    causes JSONB DEFAULT '[]'::jsonb,       -- [{group:"시황"|"차트", kind, label, detail, weight}]
    chart_tags JSONB DEFAULT '[]'::jsonb,
    themes JSONB DEFAULT '[]'::jsonb,       -- [{name, avg_pct, up5, count}]
    news JSONB DEFAULT '[]'::jsonb,
    disclosures JSONB DEFAULT '[]'::jsonb,
    flow JSONB DEFAULT '{}'::jsonb,         -- 외국인/기관/개인 순매수(억원)
    market_ctx JSONB DEFAULT '{}'::jsonb,   -- 지수·섹터 등락
    ohlcv JSONB DEFAULT '[]'::jsonb,        -- 최근 80일 [날짜, 시, 고, 저, 종, 거래량]
    pred JSONB DEFAULT '{}'::jsonb,         -- {d1:{p_up,q10,q50,q90}, d5:..., d20:...}
    similar_cases JSONB DEFAULT '{}'::jsonb,      -- {cases:[...], summary:{...}}
    ai_comment TEXT DEFAULT '',
    model_version TEXT DEFAULT '',
    generated_time TEXT DEFAULT '',
    ret_d1 NUMERIC,                         -- 실제 결과 (도달 전 NULL)
    ret_d5 NUMERIC,
    ret_d20 NUMERIC,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (date, code)
);
CREATE INDEX IF NOT EXISTS idx_surge_stocks_date ON surge_stocks (date DESC, rank);
ALTER TABLE surge_stocks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "surge_stocks anon read" ON surge_stocks;
CREATE POLICY "surge_stocks anon read" ON surge_stocks FOR SELECT USING (true);

-- ── 3) 모델 성적 ──
CREATE TABLE IF NOT EXISTS surge_model_runs (
    id BIGSERIAL PRIMARY KEY,
    date TEXT NOT NULL,
    version TEXT DEFAULT '',
    metrics JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_surge_model_runs_id ON surge_model_runs (id DESC);
ALTER TABLE surge_model_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "surge_model_runs anon read" ON surge_model_runs;
CREATE POLICY "surge_model_runs anon read" ON surge_model_runs FOR SELECT USING (true);
