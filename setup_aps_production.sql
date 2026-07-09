-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 생산일보 (Production Daily Log)
-- ─ 생산일보(집계).xlsx 업로드 → 날짜별 누적
-- ─ 원육(raw meat) → 상품(product) 페어를 그대로 로우 단위 저장
-- ─ 로스탭에서 참고 파이썬 로직으로 재계산, 품목탭에서 제품별 원육 이력 조회
-- 전제: setup_aps.sql 실행 완료 (board_admins / aps_assert_admin 필요)
-- Supabase SQL Editor에서 1회 실행
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS aps_production_log (
  id            BIGSERIAL PRIMARY KEY,
  date          DATE NOT NULL,
  sheet_name    TEXT NOT NULL DEFAULT '',
  row_index     INT  NOT NULL DEFAULT 0,   -- 시트 내 순서 (재현용)
  chain_id      INT  NOT NULL DEFAULT 0,   -- 같은 원육을 공유하는 상품 그룹
  is_chain_start   BOOLEAN NOT NULL DEFAULT FALSE, -- 새 원육이 등장한 행
  is_inherited     BOOLEAN NOT NULL DEFAULT FALSE, -- 원육 없이 이전 원육 상속
  is_loss_summary  BOOLEAN NOT NULL DEFAULT FALSE, -- XXXXXXXX 로스량 합계 행

  -- 원육 정보 (chain_start=true 인 행에만 채워짐)
  raw_meat_code   TEXT DEFAULT '',
  raw_meat_name   TEXT DEFAULT '',
  raw_meat_origin TEXT DEFAULT '',
  raw_meat_grade  TEXT DEFAULT '',
  raw_meat_boxes  NUMERIC DEFAULT 0,
  raw_meat_kg     NUMERIC DEFAULT 0,
  raw_meat_unit   TEXT DEFAULT 'Kg',
  raw_meat_amount NUMERIC DEFAULT 0,

  -- 상품 정보 (loss_summary=false 인 데이터 행에 채워짐)
  product_code   TEXT DEFAULT '',
  product_name   TEXT DEFAULT '',
  product_origin TEXT DEFAULT '',
  product_grade  TEXT DEFAULT '',
  product_boxes  NUMERIC DEFAULT 0,
  product_kg     NUMERIC DEFAULT 0,
  product_unit   TEXT DEFAULT 'Kg',
  product_amount NUMERIC DEFAULT 0,

  -- 로스 요약 (is_loss_summary=true 인 행에만 채워짐 — 시트 원본 검증용)
  loss_reported_kg     NUMERIC DEFAULT 0,
  loss_reported_amount NUMERIC DEFAULT 0,
  loss_reported_rate   NUMERIC DEFAULT 0,

  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_aps_prod_date     ON aps_production_log(date DESC);
CREATE INDEX IF NOT EXISTS idx_aps_prod_prod     ON aps_production_log(product_code);
CREATE INDEX IF NOT EXISTS idx_aps_prod_raw      ON aps_production_log(raw_meat_code);
CREATE INDEX IF NOT EXISTS idx_aps_prod_date_row ON aps_production_log(date, row_index);

ALTER TABLE aps_production_log ENABLE ROW LEVEL SECURITY;
-- 정책 없음 → REST 직접 접근 차단, RPC로만 접근

-- ───────────────────────────────────────────
-- 업로드 배치 (날짜별 덮어쓰기 — 재업로드 idempotent)
-- p_rows 각 원소:
--   {"date":"2026-06-15","sheet_name":"20260615","row_index":1,"chain_id":1,
--    "is_chain_start":true,"is_inherited":false,"is_loss_summary":false,
--    "raw_meat_code":"40000039","raw_meat_name":"...","raw_meat_boxes":0,"raw_meat_kg":888,...
--    "product_code":"40000038","product_name":"...","product_boxes":0,"product_kg":37.9,...}
-- 업로드 전에 클라이언트가 시트 순회하며 chain_id/플래그 결정
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_upsert_production_batch(
  p_admin_hash TEXT,
  p_rows       JSONB
)
RETURNS JSON AS $$
DECLARE
  v_min DATE;
  v_max DATE;
  v_inserted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RETURN json_build_object('inserted', 0, 'min_date', NULL, 'max_date', NULL);
  END IF;

  SELECT MIN((r->>'date')::DATE), MAX((r->>'date')::DATE)
    INTO v_min, v_max
    FROM jsonb_array_elements(p_rows) AS r;

  DELETE FROM aps_production_log WHERE date BETWEEN v_min AND v_max;

  INSERT INTO aps_production_log(
    date, sheet_name, row_index, chain_id,
    is_chain_start, is_inherited, is_loss_summary,
    raw_meat_code, raw_meat_name, raw_meat_origin, raw_meat_grade,
    raw_meat_boxes, raw_meat_kg, raw_meat_unit, raw_meat_amount,
    product_code, product_name, product_origin, product_grade,
    product_boxes, product_kg, product_unit, product_amount,
    loss_reported_kg, loss_reported_amount, loss_reported_rate,
    updated_at
  )
  SELECT
    (r->>'date')::DATE,
    COALESCE(r->>'sheet_name', ''),
    COALESCE((r->>'row_index')::INT, 0),
    COALESCE((r->>'chain_id')::INT, 0),
    COALESCE((r->>'is_chain_start')::BOOLEAN, FALSE),
    COALESCE((r->>'is_inherited')::BOOLEAN, FALSE),
    COALESCE((r->>'is_loss_summary')::BOOLEAN, FALSE),
    COALESCE(r->>'raw_meat_code', ''),
    COALESCE(r->>'raw_meat_name', ''),
    COALESCE(r->>'raw_meat_origin', ''),
    COALESCE(r->>'raw_meat_grade', ''),
    COALESCE((r->>'raw_meat_boxes')::NUMERIC, 0),
    COALESCE((r->>'raw_meat_kg')::NUMERIC, 0),
    COALESCE(r->>'raw_meat_unit', 'Kg'),
    COALESCE((r->>'raw_meat_amount')::NUMERIC, 0),
    COALESCE(r->>'product_code', ''),
    COALESCE(r->>'product_name', ''),
    COALESCE(r->>'product_origin', ''),
    COALESCE(r->>'product_grade', ''),
    COALESCE((r->>'product_boxes')::NUMERIC, 0),
    COALESCE((r->>'product_kg')::NUMERIC, 0),
    COALESCE(r->>'product_unit', 'Kg'),
    COALESCE((r->>'product_amount')::NUMERIC, 0),
    COALESCE((r->>'loss_reported_kg')::NUMERIC, 0),
    COALESCE((r->>'loss_reported_amount')::NUMERIC, 0),
    COALESCE((r->>'loss_reported_rate')::NUMERIC, 0),
    now()
  FROM jsonb_array_elements(p_rows) AS r;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN json_build_object('inserted', v_inserted, 'min_date', v_min, 'max_date', v_max);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 특정 날짜의 시트 원본 로우 (row_index 순)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_production_by_date(
  p_admin_hash TEXT,
  p_date       DATE
)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id,
      'date', date,
      'sheet_name', sheet_name,
      'row_index', row_index,
      'chain_id', chain_id,
      'is_chain_start',  is_chain_start,
      'is_inherited',    is_inherited,
      'is_loss_summary', is_loss_summary,
      'raw_meat_code',   raw_meat_code,
      'raw_meat_name',   raw_meat_name,
      'raw_meat_origin', raw_meat_origin,
      'raw_meat_grade',  raw_meat_grade,
      'raw_meat_boxes',  raw_meat_boxes,
      'raw_meat_kg',     raw_meat_kg,
      'raw_meat_unit',   raw_meat_unit,
      'raw_meat_amount', raw_meat_amount,
      'product_code',    product_code,
      'product_name',    product_name,
      'product_origin',  product_origin,
      'product_grade',   product_grade,
      'product_boxes',   product_boxes,
      'product_kg',      product_kg,
      'product_unit',    product_unit,
      'product_amount',  product_amount,
      'loss_reported_kg',     loss_reported_kg,
      'loss_reported_amount', loss_reported_amount,
      'loss_reported_rate',   loss_reported_rate
    ) ORDER BY row_index ASC), '[]'::json)
    FROM aps_production_log
    WHERE date = p_date
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 저장된 날짜 목록 + 날짜별 요약
-- 좌측(A-H) = 생산 제품 (chain_start에만 존재), 우측(I-P) = 투입 원육 (모든 데이터 행에 존재)
-- product_rows = chain_start 수 (제품 종류 수)
-- total_prod_kg = Σ product_kg (chain_start)
-- total_raw_kg  = Σ raw_meat_kg (모든 non-summary)
-- total_loss_kg = total_raw_kg − total_prod_kg (음수·0은 0)
-- loss_rate     = total_loss_kg / total_raw_kg * 100
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_production_dates(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    WITH per_date AS (
      SELECT
        date,
        SUM(CASE WHEN is_chain_start AND product_code <> '' THEN 1 ELSE 0 END) AS product_rows,
        SUM(CASE WHEN NOT is_loss_summary THEN raw_meat_kg ELSE 0 END) AS total_raw_kg,
        SUM(CASE WHEN is_chain_start THEN product_kg ELSE 0 END) AS total_prod_kg
      FROM aps_production_log
      GROUP BY date
    ),
    with_loss AS (
      SELECT
        date, product_rows, total_raw_kg, total_prod_kg,
        GREATEST(total_raw_kg - total_prod_kg, 0) AS total_loss_kg
      FROM per_date
    )
    SELECT COALESCE(json_agg(json_build_object(
      'date',           date,
      'product_rows',   product_rows,
      'total_raw_kg',   ROUND(total_raw_kg, 2),
      'total_prod_kg',  ROUND(total_prod_kg, 2),
      'total_loss_kg',  ROUND(total_loss_kg, 2),
      'loss_rate',      CASE WHEN total_raw_kg > 0
                             THEN ROUND(total_loss_kg / total_raw_kg * 100, 2)
                             ELSE 0 END
    ) ORDER BY date DESC), '[]'::json)
    FROM with_loss
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 특정 제품의 원육 사용 이력 — 품목탭 상세 모달용
-- 로직: product_code로 chain_start 로우 찾음 → 같은 (date, chain_id)의
--       모든 데이터 로우에서 raw_meat_kg 합산 (chain_start + continuation 모두 포함)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_raw_meat_history_by_product(
  p_admin_hash  TEXT,
  p_product_code TEXT,
  p_days_back   INT DEFAULT 365
)
RETURNS JSON AS $$
DECLARE
  v_cutoff DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days_back IS NULL OR p_days_back < 1 THEN p_days_back := 365; END IF;
  v_cutoff := CURRENT_DATE - p_days_back;

  RETURN (
    WITH prod_chains AS (
      -- 이 제품이 chain_start로 등장한 (date, chain_id) 집합
      SELECT date, chain_id, product_kg, product_amount
        FROM aps_production_log
       WHERE product_code = p_product_code
         AND is_chain_start
         AND NOT is_loss_summary
         AND date >= v_cutoff
    ),
    raws_used AS (
      -- 그 chain의 모든 원육 로우 (chain_start + continuation)
      SELECT
        p.date,
        p.chain_id,
        p.product_kg AS chain_product_kg,
        p.product_amount AS chain_product_amount,
        r.raw_meat_code,
        r.raw_meat_name,
        r.raw_meat_origin,
        r.raw_meat_grade,
        r.raw_meat_kg,
        r.raw_meat_amount
      FROM prod_chains p
      JOIN aps_production_log r
        ON r.date = p.date
       AND r.chain_id = p.chain_id
       AND NOT r.is_loss_summary
       AND r.raw_meat_code <> ''
       AND r.raw_meat_kg > 0
    ),
    per_raw AS (
      -- 원육 코드별 총 사용량 집계
      SELECT
        raw_meat_code,
        MAX(raw_meat_name)   AS raw_meat_name,
        MAX(raw_meat_origin) AS raw_meat_origin,
        COUNT(DISTINCT date) AS use_days,
        SUM(raw_meat_kg)     AS total_raw_kg,
        SUM(raw_meat_amount) AS total_raw_amount,
        MIN(date) AS first_date,
        MAX(date) AS last_date
      FROM raws_used
      GROUP BY raw_meat_code
    ),
    daily_details AS (
      -- 일자별 상세 (한 날짜에 여러 chain이 있을 수 있음 → chain별 원육 리스트)
      SELECT
        date,
        json_agg(json_build_object(
          'raw_meat_code',   raw_meat_code,
          'raw_meat_name',   raw_meat_name,
          'raw_meat_origin', raw_meat_origin,
          'raw_meat_grade',  raw_meat_grade,
          'raw_meat_kg',     ROUND(raw_meat_kg, 2),
          'product_kg',      ROUND(chain_product_kg, 2),
          'chain_id',        chain_id
        ) ORDER BY chain_id, raw_meat_code) AS raws
      FROM raws_used
      GROUP BY date
    )
    SELECT json_build_object(
      'summary', COALESCE((SELECT json_agg(json_build_object(
        'raw_meat_code',    raw_meat_code,
        'raw_meat_name',    raw_meat_name,
        'raw_meat_origin',  raw_meat_origin,
        'use_days',         use_days,
        'total_raw_kg',     ROUND(total_raw_kg, 2),
        'total_raw_amount', ROUND(total_raw_amount, 0),
        'first_date',       first_date,
        'last_date',        last_date
      ) ORDER BY total_raw_kg DESC) FROM per_raw), '[]'::json),
      'daily', COALESCE((SELECT json_agg(json_build_object(
        'date', date,
        'raws', raws
      ) ORDER BY date DESC) FROM daily_details), '[]'::json)
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- DB 메타
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_production_meta(p_admin_hash TEXT)
RETURNS JSON AS $$
DECLARE
  v_total INT;
  v_dates INT;
  v_min DATE;
  v_max DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT COUNT(*), COUNT(DISTINCT date), MIN(date), MAX(date)
    INTO v_total, v_dates, v_min, v_max
    FROM aps_production_log;
  RETURN json_build_object(
    'total_rows',   COALESCE(v_total, 0),
    'total_dates',  COALESCE(v_dates, 0),
    'min_date',     v_min,
    'max_date',     v_max
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 365일 초과 데이터 정리
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_cleanup_production(
  p_admin_hash TEXT,
  p_days       INT DEFAULT 365
)
RETURNS JSON AS $$
DECLARE
  v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days IS NULL OR p_days < 30 THEN p_days := 365; END IF;
  DELETE FROM aps_production_log WHERE date < CURRENT_DATE - p_days;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 전체 삭제 (수동 초기화)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_clear_production(p_admin_hash TEXT)
RETURNS JSON AS $$
DECLARE
  v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_production_log WHERE TRUE;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 특정 날짜 하나만 삭제
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_delete_production_date(
  p_admin_hash TEXT,
  p_date       DATE
)
RETURNS JSON AS $$
DECLARE
  v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'date_required';
  END IF;
  DELETE FROM aps_production_log WHERE date = p_date;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted, 'date', p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
