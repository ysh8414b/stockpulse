-- ═══════════════════════════════════════════
-- STOCKPULSE APS v4 — 생산계획 수동 정렬 (sort_order)
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + setup_aps_v2.sql + setup_aps_v3.sql 실행 완료
-- 안전: 모두 idempotent. 기존 데이터 보존.
-- ═══════════════════════════════════════════

-- ═══ 1. sort_order 컬럼 추가 ═══
ALTER TABLE aps_plans ADD COLUMN IF NOT EXISTS sort_order INT;

-- 기존 데이터: id 값으로 1회 초기화 (NULL인 행만)
UPDATE aps_plans SET sort_order = id WHERE sort_order IS NULL;

-- 라인 그룹별 정렬 가속 인덱스
CREATE INDEX IF NOT EXISTS idx_aps_plans_line_sort ON aps_plans (line_id, sort_order);

-- ═══ 2. INSERT 시 sort_order 자동 부여 트리거 ═══
-- aps_upsert_plan을 건드리지 않고 BEFORE INSERT 트리거로 처리
CREATE OR REPLACE FUNCTION aps_plans_assign_sort_order() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.sort_order IS NULL THEN
    SELECT COALESCE(MAX(sort_order), 0) + 1 INTO NEW.sort_order FROM aps_plans;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_aps_plans_sort_order ON aps_plans;
CREATE TRIGGER trg_aps_plans_sort_order
  BEFORE INSERT ON aps_plans
  FOR EACH ROW EXECUTE FUNCTION aps_plans_assign_sort_order();

-- ═══ 3. aps_list_plans 재정의 — sort_order 포함, 정렬도 sort_order 기준 ═══
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

-- ═══ 4. 같은 라인 그룹 내 인접 행과 sort_order swap ═══
-- p_direction: 'up' | 'down'
-- 같은 line_id(또는 둘 다 NULL)인 행 중에서 sort_order 인접 행을 찾아 교환
CREATE OR REPLACE FUNCTION aps_move_plan_order(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_direction TEXT
) RETURNS JSON AS $$
DECLARE
  curr_line     BIGINT;
  curr_sort     INT;
  neighbor_id   BIGINT;
  neighbor_sort INT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_direction NOT IN ('up','down') THEN
    RAISE EXCEPTION 'invalid_direction';
  END IF;

  SELECT line_id, sort_order INTO curr_line, curr_sort
    FROM aps_plans WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF p_direction = 'up' THEN
    SELECT id, sort_order INTO neighbor_id, neighbor_sort
      FROM aps_plans
      WHERE id <> p_id
        AND (line_id IS NOT DISTINCT FROM curr_line)
        AND sort_order < curr_sort
      ORDER BY sort_order DESC, id DESC
      LIMIT 1;
  ELSE
    SELECT id, sort_order INTO neighbor_id, neighbor_sort
      FROM aps_plans
      WHERE id <> p_id
        AND (line_id IS NOT DISTINCT FROM curr_line)
        AND sort_order > curr_sort
      ORDER BY sort_order ASC, id ASC
      LIMIT 1;
  END IF;

  IF neighbor_id IS NULL THEN
    RETURN json_build_object('moved', false);
  END IF;

  UPDATE aps_plans SET sort_order = neighbor_sort, updated_at = now() WHERE id = p_id;
  UPDATE aps_plans SET sort_order = curr_sort,     updated_at = now() WHERE id = neighbor_id;

  RETURN json_build_object(
    'moved', true,
    'swapped_with', neighbor_id,
    'new_sort_order', neighbor_sort
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
