-- ═══════════════════════════════════════════
-- STOCKPULSE APS v5 — aps_list_plans 응답에 item_spec 추가
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + v2 + v3 + v4 실행 완료
-- 목적: 생산계획 리스트/이미지 export에 품목 규격(spec) 노출
-- ═══════════════════════════════════════════

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
