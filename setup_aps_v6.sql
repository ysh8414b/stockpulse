-- ═══════════════════════════════════════════
-- STOCKPULSE APS v6 — 실제 생산 수량(actual_qty) + 통계 탭 인라인 수정
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + v2 + v3 + v4 + v5 실행 완료
-- 목적:
--   1) 계획 수량(qty) 외에 실제 생산 수량(actual_qty)을 따로 기록
--      예) 40박스 계획 → 실제 35박스만 생산
--   2) 통계 탭에서 잘못 기록된 실제 시작/종료 시각 + 실제 수량을 인라인 수정
-- 안전: 컬럼/함수 모두 IF NOT EXISTS / OR REPLACE 패턴. 기존 데이터 보존.
-- ═══════════════════════════════════════════

-- ═══ 1. 실제 생산 수량 컬럼 추가 ═══
-- NULL = 계획 qty를 그대로 사용 (별도 실제 수량 기록 없음)
-- 숫자 = 그 값이 실제로 생산된 수량 (qty와 다를 수 있음)
ALTER TABLE aps_plans ADD COLUMN IF NOT EXISTS actual_qty NUMERIC;

-- ═══ 2. aps_list_plans 재정의 (v5 + actual_qty) ═══
DROP FUNCTION IF EXISTS aps_list_plans(TEXT, TEXT);
CREATE FUNCTION aps_list_plans(p_admin_hash TEXT, p_status TEXT DEFAULT NULL)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id',              p.id,
      'item_id',         p.item_id,
      'item_code',       i.code,
      'item_name',       i.name,
      'item_unit',       i.unit,
      'item_spec',       i.spec,
      'line_id',         p.line_id,
      'line_code',       l.code,
      'line_name',       l.name,
      'qty',             p.qty,
      'actual_qty',      p.actual_qty,
      'start_at',        p.start_at,
      'end_at',          p.end_at,
      'actual_start_at', p.actual_start_at,
      'actual_end_at',   p.actual_end_at,
      'status',          p.status,
      'memo',            p.memo,
      'sort_order',      p.sort_order,
      'created_at',      p.created_at,
      'updated_at',      p.updated_at
    ) ORDER BY p.sort_order ASC NULLS LAST, p.id ASC), '[]'::json)
    FROM aps_plans p
    JOIN aps_items i ON i.id = p.item_id
    LEFT JOIN aps_lines l ON l.id = p.line_id
    WHERE p_status IS NULL OR p.status = p_status
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 3. aps_get_item_stats 재정의 (실제 수량 우선 사용) ═══
-- total_qty / avg_qty / qty_per_hour: COALESCE(actual_qty, qty) 사용
--   - actual_qty가 채워져 있으면 그 값(실제 생산량)
--   - NULL이면 계획 qty 그대로 사용 (구버전 호환)
-- 시간 통계는 기존과 동일 (actual_start_at / actual_end_at 기반)
CREATE OR REPLACE FUNCTION aps_get_item_stats(p_admin_hash TEXT, p_days_back INT DEFAULT NULL)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.plan_count DESC, x.item_code), '[]'::json)
    FROM (
      SELECT
        i.id   AS item_id,
        i.code AS item_code,
        i.name AS item_name,
        i.type AS item_type,
        i.unit AS item_unit,
        COUNT(p.id)::INT                                                                                AS plan_count,
        COALESCE(SUM(COALESCE(p.actual_qty, p.qty)), 0)::NUMERIC                                        AS total_qty,
        COALESCE(AVG(COALESCE(p.actual_qty, p.qty)), 0)::NUMERIC                                        AS avg_qty,
        COALESCE(SUM(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at)))/3600, 0)::NUMERIC       AS total_actual_hours,
        COALESCE(AVG(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at)))/3600, 0)::NUMERIC       AS avg_actual_hours,
        COALESCE(AVG(EXTRACT(EPOCH FROM (p.end_at - p.start_at)))/3600, 0)::NUMERIC                     AS avg_planned_hours,
        CASE
          WHEN COALESCE(SUM(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at))), 0) > 0
          THEN (SUM(COALESCE(p.actual_qty, p.qty)) / (SUM(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at)))/3600))::NUMERIC
          ELSE 0
        END AS qty_per_hour,
        MAX(p.actual_end_at) AS last_completed_at
      FROM aps_items i
      LEFT JOIN aps_plans p
        ON p.item_id = i.id
       AND p.status = 'done'
       AND p.actual_start_at IS NOT NULL
       AND p.actual_end_at   IS NOT NULL
       AND (p_days_back IS NULL OR p.actual_end_at >= now() - (p_days_back || ' days')::interval)
      WHERE i.type IN ('product','semi')
      GROUP BY i.id, i.code, i.name, i.type, i.unit
    ) x
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 4. 품목별 완료 plan 드릴다운 RPC ═══
-- 통계 탭에서 품목 행을 클릭하면 해당 품목의 완료 plan 리스트를 펼친다.
-- 통계와 같은 기간 필터(p_days_back) 적용 → 표시 데이터와 일관성 유지.
CREATE OR REPLACE FUNCTION aps_get_done_plans_for_item(
  p_admin_hash TEXT,
  p_item_id BIGINT,
  p_days_back INT DEFAULT NULL
) RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id',              p.id,
      'item_id',         p.item_id,
      'item_name',       i.name,
      'item_unit',       i.unit,
      'line_id',         p.line_id,
      'line_code',       l.code,
      'line_name',       l.name,
      'qty',             p.qty,
      'actual_qty',      p.actual_qty,
      'start_at',        p.start_at,
      'end_at',          p.end_at,
      'actual_start_at', p.actual_start_at,
      'actual_end_at',   p.actual_end_at,
      'status',          p.status,
      'memo',            p.memo
    ) ORDER BY p.actual_end_at DESC, p.id DESC), '[]'::json)
    FROM aps_plans p
    JOIN aps_items i ON i.id = p.item_id
    LEFT JOIN aps_lines l ON l.id = p.line_id
    WHERE p.item_id = p_item_id
      AND p.status = 'done'
      AND p.actual_start_at IS NOT NULL
      AND p.actual_end_at IS NOT NULL
      AND (p_days_back IS NULL OR p.actual_end_at >= now() - (p_days_back || ' days')::interval)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 5. 실제 시각/수량 인라인 수정 RPC ═══
-- 통계 탭에서 잘못 기록된 actual_start_at / actual_end_at / actual_qty를 한 번에 보정.
-- 인자:
--   p_actual_start_at: 새 시작 시각 (필수, TIMESTAMPTZ)
--   p_actual_end_at:   새 종료 시각 (필수, TIMESTAMPTZ, start보다 뒤)
--   p_actual_qty:      새 실제 수량 (선택, NULL이면 계획 qty 그대로 사용 의미로 비움)
-- 제약:
--   - status='done' 행에만 적용 (진행중 plan은 ▶/✓ 버튼으로 처리)
--   - end > start 검증
CREATE OR REPLACE FUNCTION aps_update_plan_actuals(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_actual_start_at TIMESTAMPTZ,
  p_actual_end_at TIMESTAMPTZ,
  p_actual_qty NUMERIC
) RETURNS JSON AS $$
DECLARE
  v_status TEXT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);

  SELECT status INTO v_status FROM aps_plans WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;
  IF v_status <> 'done' THEN
    RAISE EXCEPTION 'only_done_editable';
  END IF;
  IF p_actual_start_at IS NULL OR p_actual_end_at IS NULL THEN
    RAISE EXCEPTION 'actual_times_required';
  END IF;
  IF p_actual_end_at <= p_actual_start_at THEN
    RAISE EXCEPTION 'end_must_be_after_start';
  END IF;
  IF p_actual_qty IS NOT NULL AND p_actual_qty < 0 THEN
    RAISE EXCEPTION 'qty_must_be_non_negative';
  END IF;

  UPDATE aps_plans
     SET actual_start_at = p_actual_start_at,
         actual_end_at   = p_actual_end_at,
         actual_qty      = p_actual_qty,
         updated_at      = now()
   WHERE id = p_id;

  RETURN json_build_object(
    'id', p_id,
    'actual_start_at', p_actual_start_at,
    'actual_end_at',   p_actual_end_at,
    'actual_qty',      p_actual_qty
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
