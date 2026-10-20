-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 품목 입수량 (2026-10-20)
-- Supabase SQL Editor에서 1회 실행 (setup_aps_v10.sql 실행 전제, 재실행 안전)
-- 목적: 매출 업로드 시 I열(수량 kg) ÷ 입수량 = 박스 수
-- ═══════════════════════════════════════════
ALTER TABLE aps_items ADD COLUMN IF NOT EXISTS pack_qty NUMERIC NULL;

-- aps_list_items 재정의 (v10 + pack_qty)
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
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY type, code), '[]'::json)
    FROM aps_items
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 입수량 저장 (aps_upsert_item 시그니처는 건드리지 않음). 0 이하/NULL = 미설정
CREATE OR REPLACE FUNCTION aps_set_item_pack_qty(p_admin_hash TEXT, p_item_id BIGINT, p_pack_qty NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  UPDATE aps_items
     SET pack_qty = CASE WHEN p_pack_qty IS NULL OR p_pack_qty <= 0 THEN NULL ELSE p_pack_qty END,
         updated_at = now()
   WHERE id = p_item_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
