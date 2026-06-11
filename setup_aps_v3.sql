-- ═══════════════════════════════════════════
-- STOCKPULSE APS v3 — 실제 생산 시각 + 품목 통계 + 1년 retention
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + setup_aps_v2.sql 실행 완료
-- 안전: 컬럼/함수 모두 IF NOT EXISTS / OR REPLACE, 기존 데이터 보존
-- ═══════════════════════════════════════════

-- ═══ 1. 실제 시작/종료 시각 컬럼 추가 ═══
ALTER TABLE aps_plans ADD COLUMN IF NOT EXISTS actual_start_at TIMESTAMPTZ;
ALTER TABLE aps_plans ADD COLUMN IF NOT EXISTS actual_end_at   TIMESTAMPTZ;

-- 통계 쿼리 가속용 인덱스
CREATE INDEX IF NOT EXISTS idx_aps_plans_actual ON aps_plans (item_id, status, actual_end_at)
  WHERE status = 'done';

-- ═══ 2. 상태 전환 + 실제 시각 자동 기록 RPC ═══
-- planned/canceled → in_progress: actual_start_at = now()
-- ?            → done:           actual_end_at   = now()
-- in_progress → planned (취소):  actual_start_at NULL로 되돌리지 않음 (감사 추적)
CREATE OR REPLACE FUNCTION aps_set_plan_status(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_status TEXT
) RETURNS JSON AS $$
DECLARE
  curr_status TEXT;
  new_actual_start TIMESTAMPTZ;
  new_actual_end   TIMESTAMPTZ;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_status NOT IN ('planned','in_progress','done','canceled') THEN
    RAISE EXCEPTION 'invalid_status';
  END IF;

  SELECT status, actual_start_at, actual_end_at
    INTO curr_status, new_actual_start, new_actual_end
    FROM aps_plans WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  -- in_progress 진입 시: 최초 시작 또는 재시작(완료에서 되돌릴 때) → now()
  IF p_status = 'in_progress' AND curr_status <> 'in_progress' THEN
    new_actual_start := now();
    new_actual_end   := NULL;  -- 완료 → 진행중 되돌리면 종료 시각 리셋
  END IF;

  -- done 진입 시: actual_end_at = now(). 시작 시각 없으면 같이 채움.
  IF p_status = 'done' AND curr_status <> 'done' THEN
    IF new_actual_start IS NULL THEN
      new_actual_start := now();
    END IF;
    new_actual_end := now();
  END IF;

  UPDATE aps_plans
     SET status = p_status,
         actual_start_at = new_actual_start,
         actual_end_at   = new_actual_end,
         updated_at = now()
   WHERE id = p_id;

  RETURN json_build_object(
    'id', p_id,
    'status', p_status,
    'actual_start_at', new_actual_start,
    'actual_end_at',   new_actual_end
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 3. aps_list_plans 재정의 (실제 시각 포함) ═══
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
      'created_at',      p.created_at,
      'updated_at',      p.updated_at
    ) ORDER BY p.start_at DESC, p.id DESC), '[]'::json)
    FROM aps_plans p
    JOIN aps_items i ON i.id = p.item_id
    LEFT JOIN aps_lines l ON l.id = p.line_id
    WHERE p_status IS NULL OR p.status = p_status
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 4. 1년 retention 정리 RPC ═══
-- 완료/취소 상태 + updated_at이 p_days(기본 365) 일 초과면 삭제
-- 반환: 삭제된 행 개수
CREATE OR REPLACE FUNCTION aps_cleanup_old_plans(p_admin_hash TEXT, p_days INT DEFAULT 365)
RETURNS INT AS $$
DECLARE
  cnt INT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  WITH del AS (
    DELETE FROM aps_plans
     WHERE status IN ('done','canceled')
       AND updated_at < now() - (p_days || ' days')::interval
    RETURNING id
  )
  SELECT count(*) INTO cnt FROM del;
  RETURN cnt;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 5. 품목별 누적 통계 RPC ═══
-- p_days_back: 최근 N일 (NULL이면 전체)
-- 완료(done) + 실제 시각 둘 다 있는 계획만 집계
-- 시간당 생산률 = total_qty / total_hours
-- planned_hours: 계획 상의 (end_at - start_at)
-- actual_hours:  실제 (actual_end_at - actual_start_at)
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
        COUNT(p.id)::INT                                                       AS plan_count,
        COALESCE(SUM(p.qty), 0)::NUMERIC                                       AS total_qty,
        COALESCE(AVG(p.qty), 0)::NUMERIC                                       AS avg_qty,
        COALESCE(SUM(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at)))/3600, 0)::NUMERIC AS total_actual_hours,
        COALESCE(AVG(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at)))/3600, 0)::NUMERIC AS avg_actual_hours,
        COALESCE(AVG(EXTRACT(EPOCH FROM (p.end_at - p.start_at)))/3600, 0)::NUMERIC               AS avg_planned_hours,
        CASE
          WHEN COALESCE(SUM(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at))), 0) > 0
          THEN (SUM(p.qty) / (SUM(EXTRACT(EPOCH FROM (p.actual_end_at - p.actual_start_at)))/3600))::NUMERIC
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
