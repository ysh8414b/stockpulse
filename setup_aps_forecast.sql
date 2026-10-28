-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 🎉 행사 관리 + 🔮 수요 예측(ML)
-- Supabase SQL Editor에서 1회 실행 (재실행 안전)
-- 전제: setup_aps.sql (aps_assert_admin) + setup_aps_sales.sql
--
-- 1) aps_promotions   : 제품별 행사 기간 (할인·1+1·기획전 등)
-- 2) aps_forecast     : 매일 밤 forecast_aps.py(GitHub Actions)가 채우는 날짜×상품 예측
-- 3) aps_forecast_runs: 예측 실행 기록 + 정확도(기존 요일 평균 vs ML)
-- 쓰기는 GitHub Actions(service key)가 하고, 화면은 아래 RPC로 읽기만 함
-- ═══════════════════════════════════════════

-- ═══ 1. 행사 ═══
CREATE TABLE IF NOT EXISTS aps_promotions (
  id            BIGSERIAL PRIMARY KEY,
  code          TEXT NOT NULL,              -- 매출 상품코드 (= 품목 코드)
  name          TEXT NOT NULL DEFAULT '',   -- 표시용 상품명
  start_date    DATE NOT NULL,
  end_date      DATE NOT NULL,
  kind          TEXT NOT NULL DEFAULT '할인', -- 할인 / 1+1 / 기획전 / 타임딜 / 기타
  discount_pct  NUMERIC NULL,               -- 할인율 % (모르면 NULL)
  uplift        NUMERIC NULL,               -- 예상 배수 (평소 대비, 모르면 NULL)
  memo          TEXT NOT NULL DEFAULT '',
  actual_uplift NUMERIC NULL,               -- 지난 행사의 실제 배수 (forecast_aps.py가 계산)
  actual_days   INT NULL,                   -- 실제 배수 계산에 쓴 매출 일수
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date)
);
CREATE INDEX IF NOT EXISTS idx_aps_promo_code  ON aps_promotions(code);
CREATE INDEX IF NOT EXISTS idx_aps_promo_dates ON aps_promotions(start_date, end_date);
ALTER TABLE aps_promotions ENABLE ROW LEVEL SECURITY;

-- ═══ 2. 예측 결과 ═══
CREATE TABLE IF NOT EXISTS aps_forecast (
  date    DATE NOT NULL,
  code    TEXT NOT NULL,
  name    TEXT NOT NULL DEFAULT '',
  qty     NUMERIC NOT NULL,        -- 예상 판매 (박스)
  qty_lo  NUMERIC NULL,            -- 적게 팔릴 때 (하위 15%)
  qty_hi  NUMERIC NULL,            -- 많이 팔릴 때 (상위 15%)
  base    NUMERIC NULL,            -- 같은 날 기존 방식(요일 평균) 값 — 비교용
  promo   BOOLEAN NOT NULL DEFAULT FALSE,
  model   TEXT NOT NULL DEFAULT 'ml', -- ml | base (그 상품은 기존 방식이 더 정확해서 기존 방식 사용)
  run_id  BIGINT NULL,
  PRIMARY KEY (date, code)
);
CREATE INDEX IF NOT EXISTS idx_aps_forecast_code ON aps_forecast(code);
ALTER TABLE aps_forecast ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS aps_forecast_runs (
  id         BIGSERIAL PRIMARY KEY,
  run_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  data_start DATE NULL,
  data_end   DATE NULL,           -- 학습에 쓴 마지막 매출 날짜
  n_days     INT NULL,            -- 매출이 올라온 날짜 수
  n_products INT NULL,
  horizon    INT NULL,
  status     TEXT NOT NULL DEFAULT 'ok', -- ok | baseline_only | error
  message    TEXT NOT NULL DEFAULT '',
  metrics    JSONB NOT NULL DEFAULT '{}'::jsonb
);
ALTER TABLE aps_forecast_runs ENABLE ROW LEVEL SECURITY;

-- ═══ 3. 행사 RPC ═══
CREATE OR REPLACE FUNCTION aps_list_promotions(p_admin_hash TEXT, p_from DATE DEFAULT NULL, p_to DATE DEFAULT NULL)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(p) ORDER BY p.start_date DESC, p.id DESC), '[]'::json)
    FROM aps_promotions p
    WHERE (p_from IS NULL OR p.end_date >= p_from)
      AND (p_to   IS NULL OR p.start_date <= p_to)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_upsert_promotion(
  p_admin_hash TEXT, p_id BIGINT, p_code TEXT, p_name TEXT,
  p_start DATE, p_end DATE, p_kind TEXT DEFAULT '할인',
  p_discount_pct NUMERIC DEFAULT NULL, p_uplift NUMERIC DEFAULT NULL, p_memo TEXT DEFAULT ''
) RETURNS JSON AS $$
DECLARE v_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF COALESCE(TRIM(p_code), '') = '' THEN RAISE EXCEPTION 'code_required'; END IF;
  IF p_start IS NULL OR p_end IS NULL THEN RAISE EXCEPTION 'date_required'; END IF;
  IF p_end < p_start THEN RAISE EXCEPTION 'bad_range'; END IF;
  IF p_uplift IS NOT NULL AND p_uplift <= 0 THEN p_uplift := NULL; END IF;
  IF p_id IS NULL THEN
    INSERT INTO aps_promotions(code, name, start_date, end_date, kind, discount_pct, uplift, memo)
    VALUES (TRIM(p_code), COALESCE(p_name, ''), p_start, p_end, COALESCE(NULLIF(TRIM(p_kind), ''), '할인'),
            p_discount_pct, p_uplift, COALESCE(p_memo, ''))
    RETURNING id INTO v_id;
  ELSE
    UPDATE aps_promotions SET
      code = TRIM(p_code), name = COALESCE(p_name, ''), start_date = p_start, end_date = p_end,
      kind = COALESCE(NULLIF(TRIM(p_kind), ''), '할인'), discount_pct = p_discount_pct,
      uplift = p_uplift, memo = COALESCE(p_memo, ''), updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'not_found'; END IF;
  END IF;
  RETURN json_build_object('id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_delete_promotion(p_admin_hash TEXT, p_id BIGINT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_promotions WHERE id = p_id;
  RETURN json_build_object('deleted', p_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 4. 예측 RPC (읽기 전용) ═══
CREATE OR REPLACE FUNCTION aps_get_forecast(p_admin_hash TEXT, p_from DATE DEFAULT NULL, p_to DATE DEFAULT NULL)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'date', f.date, 'code', f.code, 'name', f.name, 'qty', f.qty,
      'qty_lo', f.qty_lo, 'qty_hi', f.qty_hi, 'base', f.base, 'promo', f.promo, 'model', f.model
    ) ORDER BY f.code, f.date), '[]'::json)
    FROM aps_forecast f
    WHERE (p_from IS NULL OR f.date >= p_from)
      AND (p_to   IS NULL OR f.date <= p_to)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 최근 실행 기록 (기본 10개, 맨 앞이 최신)
CREATE OR REPLACE FUNCTION aps_get_forecast_runs(p_admin_hash TEXT, p_limit INT DEFAULT 10)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.run_at DESC), '[]'::json)
    FROM (SELECT * FROM aps_forecast_runs ORDER BY run_at DESC LIMIT GREATEST(COALESCE(p_limit, 10), 1)) r
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
