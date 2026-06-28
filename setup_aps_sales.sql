-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 매출 일보 (Sales Daily)
-- ─ 매출.xlsx 업로드 → 1년치 누적 → 월평균 자동 계산
-- ─ 재고시트의 제품코드와 매칭하여 "한달평균 안전재고" 표시
-- 전제: setup_aps.sql 실행 완료 (board_admins / aps_assert_admin 필요)
-- Supabase SQL Editor에서 1회 실행
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS aps_sales_daily (
  date  DATE NOT NULL,
  code  TEXT NOT NULL,
  name  TEXT NOT NULL DEFAULT '',
  qty   NUMERIC NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (date, code)
);
CREATE INDEX IF NOT EXISTS idx_aps_sales_code  ON aps_sales_daily(code);
CREATE INDEX IF NOT EXISTS idx_aps_sales_date  ON aps_sales_daily(date DESC);

ALTER TABLE aps_sales_daily ENABLE ROW LEVEL SECURITY;
-- 정책 없음 → REST 직접 접근 차단, RPC만 허용

-- ───────────────────────────────────────────
-- 업로드 배치 (해당 날짜 범위는 덮어쓰기 — 재업로드 idempotent)
-- p_rows: [{"date":"2026-06-15","code":"B0000006","name":"치즈 400g*16","qty":1.0}, ...]
-- 같은 (date, code) 여러 건은 클라이언트가 미리 sum 해서 보내야 함
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_upsert_sales_batch(
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

  -- 업로드된 행 중 최소/최대 날짜
  SELECT MIN((r->>'date')::DATE), MAX((r->>'date')::DATE)
    INTO v_min, v_max
    FROM jsonb_array_elements(p_rows) AS r;

  -- 같은 범위의 기존 데이터 삭제 (재업로드 idempotent)
  DELETE FROM aps_sales_daily WHERE date BETWEEN v_min AND v_max;

  -- 신규 INSERT
  INSERT INTO aps_sales_daily(date, code, name, qty, updated_at)
  SELECT
    (r->>'date')::DATE,
    r->>'code',
    COALESCE(r->>'name', ''),
    COALESCE((r->>'qty')::NUMERIC, 0),
    now()
  FROM jsonb_array_elements(p_rows) AS r
  WHERE r->>'code' IS NOT NULL AND r->>'code' <> ''
  ON CONFLICT (date, code) DO UPDATE
    SET qty = aps_sales_daily.qty + EXCLUDED.qty,
        name = CASE WHEN EXCLUDED.name <> '' THEN EXCLUDED.name ELSE aps_sales_daily.name END,
        updated_at = now();

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN json_build_object('inserted', v_inserted, 'min_date', v_min, 'max_date', v_max);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 품목별 통계 (최근 p_days 일)
-- avg_daily   = total_qty / p_days  (전체 기간 기준, 거래 없는 날도 0으로 평균)
-- avg_weekly  = avg_daily * 7   (주평균 안전재고 추천값)
-- avg_monthly = avg_daily * 30  (참고용 — 한달평균)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_sales_stats(
  p_admin_hash TEXT,
  p_days       INT DEFAULT 30
)
RETURNS JSON AS $$
DECLARE
  v_cutoff DATE;
  v_today  DATE := CURRENT_DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days IS NULL OR p_days < 1 THEN p_days := 30; END IF;
  v_cutoff := v_today - (p_days - 1);

  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'code',           code,
      'name',           name,
      'total_qty',      total_qty,
      'days_with_sales',days_with_sales,
      'avg_daily',      ROUND((total_qty / p_days)::NUMERIC, 0),
      'avg_weekly',     ROUND((total_qty / p_days * 7)::NUMERIC, 0),
      'avg_monthly',    ROUND((total_qty / p_days * 30)::NUMERIC, 0),
      'first_date',     first_date,
      'last_date',      last_date,
      'period_days',    p_days
    ) ORDER BY total_qty DESC), '[]'::json)
    FROM (
      SELECT
        s.code,
        MAX(s.name) AS name,
        SUM(s.qty)  AS total_qty,
        COUNT(DISTINCT s.date) AS days_with_sales,
        MIN(s.date) AS first_date,
        MAX(s.date) AS last_date
      FROM aps_sales_daily s
      WHERE s.date >= v_cutoff
      GROUP BY s.code
    ) sub
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- DB 메타: 전체 row 수, 보유 기간
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_sales_meta(p_admin_hash TEXT)
RETURNS JSON AS $$
DECLARE
  v_total INT;
  v_min   DATE;
  v_max   DATE;
  v_codes INT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT COUNT(*), MIN(date), MAX(date), COUNT(DISTINCT code)
    INTO v_total, v_min, v_max, v_codes
    FROM aps_sales_daily;
  RETURN json_build_object(
    'total_rows',    COALESCE(v_total, 0),
    'distinct_codes',COALESCE(v_codes, 0),
    'min_date',      v_min,
    'max_date',      v_max
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 매출 평균 → aps_items.safety_stock 자동 동기화
-- 최근 p_days 일 매출의 주평균(avg_weekly = total/days*7) 값을
-- 같은 코드의 aps_items.safety_stock 에 일괄 업데이트.
-- 매출 데이터 없는 품목은 건드리지 않음.
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_sync_safety_from_sales(
  p_admin_hash TEXT,
  p_days       INT DEFAULT 30
)
RETURNS JSON AS $$
DECLARE
  v_cutoff DATE;
  v_updated INT := 0;
  v_matched INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days IS NULL OR p_days < 1 THEN p_days := 30; END IF;
  v_cutoff := CURRENT_DATE - (p_days - 1);

  -- 매칭 가능한 행 수 먼저 카운트 (참고용)
  SELECT COUNT(*)
    INTO v_matched
    FROM aps_items i
    JOIN (
      SELECT code FROM aps_sales_daily WHERE date >= v_cutoff GROUP BY code
    ) s ON s.code = i.code;

  -- 실제 update (값이 다를 때만 — 불필요한 updated_at 갱신 회피)
  WITH stats AS (
    SELECT code, ROUND((SUM(qty) / p_days * 7)::NUMERIC, 0) AS avg_weekly
      FROM aps_sales_daily
     WHERE date >= v_cutoff
     GROUP BY code
  )
  UPDATE aps_items i
     SET safety_stock = s.avg_weekly,
         updated_at   = now()
    FROM stats s
   WHERE i.code = s.code
     AND i.safety_stock IS DISTINCT FROM s.avg_weekly;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN json_build_object(
    'updated',     v_updated,
    'matched',     v_matched,
    'period_days', p_days
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 365일 초과 데이터 정리
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_cleanup_sales(
  p_admin_hash TEXT,
  p_days       INT DEFAULT 365
)
RETURNS JSON AS $$
DECLARE
  v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days IS NULL OR p_days < 30 THEN p_days := 365; END IF;
  DELETE FROM aps_sales_daily WHERE date < CURRENT_DATE - p_days;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- 전체 삭제 (수동 초기화용)
-- ※ Supabase/PostgREST 안전 정책상 WHERE 없는 DELETE 가 막혀 있어 WHERE true 사용
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_clear_sales(p_admin_hash TEXT)
RETURNS JSON AS $$
DECLARE
  v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_sales_daily WHERE TRUE;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
