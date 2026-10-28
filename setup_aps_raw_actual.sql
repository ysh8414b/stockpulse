-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 생산계획 실제 투입 원육 kg
-- Supabase SQL Editor에서 1회 실행 (재실행 안전)
-- 전제: setup_aps.sql ~ v9 실행 완료
-- 목적:
--   계획(BOM 기준) 원육 kg과 실제 투입 원육 kg이 달라 통계가 부정확한 문제 해결.
--   계획마다 원자재별 실제 투입 kg을 따로 저장 (계획 1건 : 원자재 N개).
-- 안전: 새 테이블·새 함수만 추가. 기존 함수/컬럼 변경 없음.
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS aps_plan_raw_actuals (
  plan_id     BIGINT NOT NULL REFERENCES aps_plans(id) ON DELETE CASCADE,
  material_id BIGINT NOT NULL REFERENCES aps_items(id) ON DELETE CASCADE,
  kg          NUMERIC NOT NULL CHECK (kg >= 0),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (plan_id, material_id)
);
CREATE INDEX IF NOT EXISTS idx_aps_plan_raw_material ON aps_plan_raw_actuals(material_id);
ALTER TABLE aps_plan_raw_actuals ENABLE ROW LEVEL SECURITY;  -- 정책 없음 → RPC로만 접근

-- ═══ 계획 여러 건의 실제 투입 원육 조회 ═══
-- 반환: [{plan_id, material_id, material_code, material_name, kg}]
CREATE OR REPLACE FUNCTION aps_get_plan_raw_actuals(
  p_admin_hash TEXT,
  p_plan_ids BIGINT[]
) RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'plan_id',       r.plan_id,
      'material_id',   r.material_id,
      'material_code', i.code,
      'material_name', i.name,
      'kg',            r.kg
    ) ORDER BY r.plan_id, r.kg DESC), '[]'::json)
    FROM aps_plan_raw_actuals r
    JOIN aps_items i ON i.id = r.material_id
    WHERE r.plan_id = ANY(COALESCE(p_plan_ids, ARRAY[]::BIGINT[]))
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 계획 1건의 실제 투입 원육 저장 (통째로 교체) ═══
-- p_rows: [{material_id, kg}] — 빈 배열이면 이 계획의 실제 투입 기록 삭제(계획값 사용)
CREATE OR REPLACE FUNCTION aps_set_plan_raw_actuals(
  p_admin_hash TEXT,
  p_plan_id BIGINT,
  p_rows JSONB
) RETURNS JSON AS $$
DECLARE
  v_count INT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF NOT EXISTS (SELECT 1 FROM aps_plans WHERE id = p_plan_id) THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  DELETE FROM aps_plan_raw_actuals WHERE plan_id = p_plan_id;

  INSERT INTO aps_plan_raw_actuals (plan_id, material_id, kg, updated_at)
  SELECT p_plan_id, (x->>'material_id')::BIGINT, SUM((x->>'kg')::NUMERIC), now()
    FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) x
   WHERE (x->>'material_id') IS NOT NULL
     AND (x->>'kg') IS NOT NULL
     AND (x->>'kg')::NUMERIC >= 0
     AND EXISTS (SELECT 1 FROM aps_items i WHERE i.id = (x->>'material_id')::BIGINT)
   GROUP BY (x->>'material_id')::BIGINT;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN json_build_object('plan_id', p_plan_id, 'saved', v_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 품목별 실제 원육 사용 통계 (📈 통계 탭) ═══
-- 실제 투입 kg이 입력된 완료 계획만 집계. 기간 필터는 aps_get_item_stats와 동일.
-- 반환: [{item_id, plan_count, total_qty, total_raw_kg, materials:[{material_id, material_name, kg}]}]
--   total_qty = 그 계획들의 실제 수량(없으면 계획 수량) 합 → 단위당 실제 원육 kg = total_raw_kg / total_qty
CREATE OR REPLACE FUNCTION aps_get_raw_usage_stats(
  p_admin_hash TEXT,
  p_days_back INT DEFAULT NULL
) RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    WITH pl AS (
      SELECT p.id, p.item_id, COALESCE(p.actual_qty, p.qty) AS q
        FROM aps_plans p
       WHERE p.status = 'done'
         AND p.actual_end_at IS NOT NULL
         AND (p_days_back IS NULL OR p.actual_end_at >= now() - (p_days_back || ' days')::interval)
         AND EXISTS (SELECT 1 FROM aps_plan_raw_actuals r WHERE r.plan_id = p.id)
    ),
    per_item AS (
      SELECT item_id, COUNT(*) AS plan_count, SUM(q) AS total_qty
        FROM pl GROUP BY item_id
    ),
    per_mat AS (
      SELECT pl.item_id, r.material_id, i.name AS material_name, SUM(r.kg) AS kg
        FROM pl
        JOIN aps_plan_raw_actuals r ON r.plan_id = pl.id
        JOIN aps_items i ON i.id = r.material_id
       GROUP BY pl.item_id, r.material_id, i.name
    )
    SELECT COALESCE(json_agg(json_build_object(
      'item_id',      pi.item_id,
      'plan_count',   pi.plan_count,
      'total_qty',    pi.total_qty,
      'total_raw_kg', (SELECT COALESCE(SUM(kg),0) FROM per_mat m WHERE m.item_id = pi.item_id),
      'materials',    (SELECT COALESCE(json_agg(json_build_object(
                         'material_id', m.material_id, 'material_name', m.material_name, 'kg', m.kg
                       ) ORDER BY m.kg DESC), '[]'::json)
                         FROM per_mat m WHERE m.item_id = pi.item_id)
    )), '[]'::json)
    FROM per_item pi
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
