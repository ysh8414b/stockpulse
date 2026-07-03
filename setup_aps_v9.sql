-- ═══════════════════════════════════════════
-- STOCKPULSE APS v9 — 통계 탭 날짜별 뷰용 RPC
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + v2 + v3 + v4 + v5 + v6 + v7 + v8 실행 완료
-- 목적:
--   기존 통계 탭(품목별 집계)은 유지하고, 신규 "날짜별" 뷰용으로
--   기간 내 완료 plan 전체를 반환하는 RPC 추가.
--   클라이언트에서 KST 날짜 기준으로 그룹핑하여 렌더.
-- 안전: 신규 함수만 추가. 기존 함수/컬럼 영향 없음.
-- ═══════════════════════════════════════════

-- ═══ aps_get_done_plans_all ═══
-- 통계 탭 날짜별 뷰에서 사용.
-- status='done' + actual_start_at/actual_end_at 둘 다 존재하는 plan만 반환.
-- 기간 필터(p_days_back)는 품목별 뷰(aps_get_item_stats)와 동일 로직.
-- 반환 필드는 aps_get_done_plans_for_item과 통일해서 StatsDrilldownTable을 재사용할 수 있게 함.
-- 추가: item_code, item_type (품목별 뷰의 필드셋과 일치)
CREATE OR REPLACE FUNCTION aps_get_done_plans_all(
  p_admin_hash TEXT,
  p_days_back INT DEFAULT NULL
) RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id',              p.id,
      'item_id',         p.item_id,
      'item_code',       i.code,
      'item_name',       i.name,
      'item_type',       i.type,
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
    WHERE p.status = 'done'
      AND p.actual_start_at IS NOT NULL
      AND p.actual_end_at IS NOT NULL
      AND (p_days_back IS NULL OR p.actual_end_at >= now() - (p_days_back || ' days')::interval)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
