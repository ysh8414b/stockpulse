-- ═══════════════════════════════════════════
-- STOCKPULSE APS v10 — 생산계획 자동 생성
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + v2 ~ v9 + setup_aps_sales.sql 실행 완료
-- 목적:
--   1) 품목별 생산 가능 라인(line_ids) + 수동 시간당 생산량(units_per_hour)
--   2) 라인별 자동계획 허용 여부(auto_plan)
--   3) 매출 요일별 평균(aps_get_sales_dow) — 요일 추이 기반 수요 예측
-- 안전: IF NOT EXISTS / OR REPLACE 패턴, 재실행 안전. 기존 데이터 보존.
-- ═══════════════════════════════════════════

-- ═══ 1. 컬럼 추가 ═══
-- line_ids: 이 품목을 생산할 수 있는 라인 id 배열. 예: [1, 3]
-- units_per_hour: 시간당 생산량(수동). 완료 실적(통계)이 없을 때만 자동계획에 사용
ALTER TABLE aps_items ADD COLUMN IF NOT EXISTS line_ids JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE aps_items ADD COLUMN IF NOT EXISTS units_per_hour NUMERIC NULL;
ALTER TABLE aps_lines ADD COLUMN IF NOT EXISTS auto_plan BOOLEAN NOT NULL DEFAULT FALSE;

-- ═══ 2. aps_list_items 재정의 (line_ids, units_per_hour 포함) ═══
CREATE OR REPLACE FUNCTION aps_list_items(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'code', code, 'name', name, 'type', type,
      'unit', unit, 'spec', spec,
      'safety_stock', safety_stock, 'lead_time_days', lead_time_days,
      'memo', memo,
      'match_keywords', match_keywords,
      'line_ids', line_ids,
      'units_per_hour', units_per_hour,
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY type, code), '[]'::json)
    FROM aps_items
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 3. aps_list_lines 재정의 (auto_plan 포함) ═══
CREATE OR REPLACE FUNCTION aps_list_lines(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'code', code, 'name', name, 'memo', memo,
      'auto_plan', auto_plan,
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY code), '[]'::json)
    FROM aps_lines
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 4. 품목 생산 정보 저장 (라인 + 시간당 생산량) ═══
-- aps_upsert_item 시그니처는 건드리지 않고 별도 RPC로 저장 (구버전 호환)
CREATE OR REPLACE FUNCTION aps_set_item_plan_info(
  p_admin_hash TEXT,
  p_item_id BIGINT,
  p_line_ids JSONB,
  p_units_per_hour NUMERIC
) RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  UPDATE aps_items
     SET line_ids = CASE WHEN jsonb_typeof(p_line_ids) = 'array' THEN p_line_ids ELSE '[]'::jsonb END,
         units_per_hour = CASE WHEN p_units_per_hour IS NULL OR p_units_per_hour <= 0 THEN NULL ELSE p_units_per_hour END,
         updated_at = now()
   WHERE id = p_item_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 5. 라인 자동계획 허용 토글 ═══
CREATE OR REPLACE FUNCTION aps_set_line_auto(p_admin_hash TEXT, p_id BIGINT, p_enabled BOOLEAN)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  UPDATE aps_lines SET auto_plan = COALESCE(p_enabled, FALSE), updated_at = now() WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 6. 매출 요일별 평균 ═══
-- 매출 데이터의 마지막 날짜부터 거꾸로 p_weeks주(= p_weeks*7일) 윈도우.
-- 데이터가 그보다 짧으면 첫 매출일부터. 각 요일 평균 = 그 요일 판매 합계 / 윈도우 안 그 요일 날짜 수
-- (판매 없는 날도 분모에 포함 → 0 판매일이 평균에 반영됨)
-- dow: ISO 요일 1=월 … 7=일
CREATE OR REPLACE FUNCTION aps_get_sales_dow(p_admin_hash TEXT, p_weeks INT DEFAULT 8)
RETURNS JSON AS $$
DECLARE
  v_end DATE;
  v_min DATE;
  v_start DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT MAX(date), MIN(date) INTO v_end, v_min FROM aps_sales_daily;
  IF v_end IS NULL THEN
    RETURN json_build_object('start', NULL, 'end', NULL, 'rows', '[]'::json);
  END IF;
  v_start := GREATEST(v_min, v_end - (GREATEST(COALESCE(p_weeks, 8), 1) * 7 - 1));

  RETURN json_build_object(
    'start', v_start,
    'end', v_end,
    'rows', (
      WITH days AS (
        SELECT d::date AS date, EXTRACT(ISODOW FROM d)::INT AS dow
        FROM generate_series(v_start, v_end, interval '1 day') d
      ),
      dow_cnt AS (
        SELECT dow, COUNT(*)::INT AS n FROM days GROUP BY dow
      ),
      sums AS (
        SELECT s.code, MAX(s.name) AS name, EXTRACT(ISODOW FROM s.date)::INT AS dow, SUM(s.qty) AS qty
        FROM aps_sales_daily s
        WHERE s.date BETWEEN v_start AND v_end
        GROUP BY s.code, EXTRACT(ISODOW FROM s.date)
      )
      SELECT COALESCE(json_agg(json_build_object(
        'code', sums.code, 'name', sums.name, 'dow', sums.dow,
        'total', sums.qty, 'days', dow_cnt.n,
        'avg', ROUND(sums.qty / NULLIF(dow_cnt.n, 0), 3)
      )), '[]'::json)
      FROM sums JOIN dow_cnt ON dow_cnt.dow = sums.dow
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
