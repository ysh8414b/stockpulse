-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 품목 "사용 안 함"(숨김) (2026-11-06)
-- Supabase SQL Editor에서 1회 실행 (setup_aps_pack_qty.sql 실행 전제, 재실행 안전)
-- 목적: 생산계획 이력이 있어 삭제할 수 없는 품목을 지우지 않고 숨김
--       (과거 계획·통계·실적은 그대로 유지)
-- ═══════════════════════════════════════════
ALTER TABLE aps_items ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT TRUE;

-- aps_list_items 재정의 (pack_qty + active)
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
      'pack_qty', pack_qty,
      'active', active,
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY type, code), '[]'::json)
    FROM aps_items
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 숨기기 / 다시 쓰기
CREATE OR REPLACE FUNCTION aps_set_item_active(p_admin_hash TEXT, p_item_id BIGINT, p_active BOOLEAN)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  UPDATE aps_items
     SET active = COALESCE(p_active, TRUE), updated_at = now()
   WHERE id = p_item_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
