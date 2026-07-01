-- ═══════════════════════════════════════════
-- STOCKPULSE APS v8 — 원자재 필요 안전재고 자동 계산 (BOM 기반)
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + v2 + v3 + v4 + v5 + v6 + v7 실행 완료
-- 목적:
--   원자재의 필요 안전재고 = Σ(직접 부모 제품/반제품의 safety_stock × BOM.qty × (1 + loss_rate/100))
--   재고시트 이미지에 원자재별 필요치 vs 실제 재고 비교 표시용
-- 안전: 함수 OR REPLACE 패턴. 컬럼/데이터 변경 없음.
-- ═══════════════════════════════════════════

-- ═══ aps_get_material_requirements ═══
-- 원자재 각각에 대해 "이 원자재를 직접 자식으로 갖는 부모(제품/반제품)의 안전재고 × qty × loss_rate" 합산
-- 부모의 type은 product/semi로 제한 (원자재끼리의 BOM 무시)
-- safety_stock 0인 부모는 자연스럽게 0 기여 → HAVING으로 제외해도 되지만, 부모 없는 원자재도 리스트에 나타나야
-- 유용하므로 제외하지 않음. 클라이언트에서 required_kg=0인 항목은 무시하면 됨
-- 반환: {material_id, code, name, required_kg, source_count}
--   source_count = 이 원자재를 사용하는 부모 아이템 수
CREATE OR REPLACE FUNCTION aps_get_material_requirements(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
    FROM (
      SELECT
        c.id::BIGINT AS material_id,
        c.code AS code,
        c.name AS name,
        COALESCE(SUM(p.safety_stock * b.qty * (1 + COALESCE(b.loss_rate, 0) / 100.0)), 0)::NUMERIC AS required_kg,
        COUNT(DISTINCT b.parent_id)::INT AS source_count,
        COALESCE(json_agg(json_build_object(
          'parent_id', p.id,
          'parent_code', p.code,
          'parent_name', p.name,
          'parent_type', p.type,
          'parent_safety_stock', p.safety_stock,
          'qty', b.qty,
          'loss_rate', COALESCE(b.loss_rate, 0),
          'contrib_kg', (p.safety_stock * b.qty * (1 + COALESCE(b.loss_rate, 0) / 100.0))
        ) ORDER BY (p.safety_stock * b.qty * (1 + COALESCE(b.loss_rate, 0) / 100.0)) DESC)
          FILTER (WHERE p.id IS NOT NULL), '[]'::json) AS sources
      FROM aps_items c
      LEFT JOIN aps_bom b ON b.child_id = c.id
      LEFT JOIN aps_items p ON p.id = b.parent_id AND p.type IN ('product', 'semi')
      WHERE c.type = 'material'
      GROUP BY c.id, c.code, c.name
      ORDER BY required_kg DESC, c.code
    ) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
