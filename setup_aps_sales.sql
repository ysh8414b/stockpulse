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
-- 품목별 통계
-- 평균: **데이터 전체에서 가장 최근 4 ISO 주의 단순 평균** (기간 필터 무관)
--   → 시즌·추세 변동을 빨리 반영. 오래된 데이터는 평균에 영향 X.
-- 기간 필터(p_days): total_qty / days_with_sales / first_date / last_date 표시용
-- recent_week_count: 평균에 실제로 들어간 주 수 (데이터 부족 시 1~3)
-- avg_weekly  = AVG(week_qty) over last 4 ISO weeks
-- avg_daily   = avg_weekly / 7      (참고)
-- avg_monthly = avg_weekly * 30 / 7 (참고)
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
    WITH all_weekly AS (
      -- 전체 데이터의 코드별 ISO 주 합계 (기간 필터 무관)
      SELECT s.code,
             DATE_TRUNC('week', s.date) AS week_start,
             SUM(s.qty) AS week_qty
        FROM aps_sales_daily s
       GROUP BY s.code, DATE_TRUNC('week', s.date)
    ),
    ranked AS (
      SELECT code, week_start, week_qty,
             ROW_NUMBER() OVER (PARTITION BY code ORDER BY week_start DESC) AS rn
        FROM all_weekly
    ),
    recent4 AS (
      -- 가장 최근 4 ISO 주의 단순 평균
      SELECT code,
             AVG(week_qty)::NUMERIC AS avg_weekly,
             COUNT(*)::INT          AS recent_week_count
        FROM ranked
       WHERE rn <= 4
       GROUP BY code
    ),
    period_stat AS (
      -- 선택 기간 집계 (표시용)
      SELECT s.code,
             MAX(s.name) AS name,
             SUM(s.qty)  AS total_qty,
             COUNT(DISTINCT s.date) AS days_with_sales,
             COUNT(DISTINCT DATE_TRUNC('week', s.date)) AS week_count,
             MIN(s.date) AS first_date,
             MAX(s.date) AS last_date
        FROM aps_sales_daily s
       WHERE s.date >= v_cutoff
       GROUP BY s.code
    )
    SELECT COALESCE(json_agg(json_build_object(
      'code',              p.code,
      'name',              p.name,
      'total_qty',         p.total_qty,
      'days_with_sales',   p.days_with_sales,
      'week_count',        p.week_count,
      'recent_week_count', COALESCE(r.recent_week_count, 0),
      'avg_weekly',        ROUND(COALESCE(r.avg_weekly, 0), 0),
      'avg_daily',         ROUND(COALESCE(r.avg_weekly, 0) / 7.0, 1),
      'avg_monthly',       ROUND(COALESCE(r.avg_weekly, 0) * 30.0 / 7.0, 0),
      'first_date',        p.first_date,
      'last_date',         p.last_date,
      'period_days',       p_days
    ) ORDER BY p.total_qty DESC), '[]'::json)
    FROM period_stat p
    LEFT JOIN recent4 r USING (code)
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
-- 데이터 전체에서 가장 최근 4 ISO 주(월~일)의 평균을 안전재고로 갱신.
--   → 시즌·추세 변동을 빠르게 반영 (오래된 데이터는 평균에 반영 X)
-- p_days 파라미터는 호환성 위해 시그니처에 남겨두나 평균 산식에 영향 없음.
-- 매출 데이터 없는 품목은 건드리지 않음.
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_sync_safety_from_sales(
  p_admin_hash TEXT,
  p_days       INT DEFAULT 30
)
RETURNS JSON AS $$
DECLARE
  v_updated INT := 0;
  v_matched INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days IS NULL OR p_days < 1 THEN p_days := 30; END IF;

  -- 매칭 가능한 품목 수 (매출 데이터 있는 코드 ∩ aps_items)
  SELECT COUNT(*)
    INTO v_matched
    FROM aps_items i
    JOIN (SELECT DISTINCT code FROM aps_sales_daily) s ON s.code = i.code;

  -- 최근 4 ISO 주 평균 → safety_stock
  WITH all_weekly AS (
    SELECT code,
           DATE_TRUNC('week', date) AS week_start,
           SUM(qty) AS week_qty
      FROM aps_sales_daily
     GROUP BY code, DATE_TRUNC('week', date)
  ),
  ranked AS (
    SELECT code, week_start, week_qty,
           ROW_NUMBER() OVER (PARTITION BY code ORDER BY week_start DESC) AS rn
      FROM all_weekly
  ),
  stats AS (
    SELECT code,
           ROUND(AVG(week_qty)::NUMERIC, 0) AS avg_weekly
      FROM ranked
     WHERE rn <= 4
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
