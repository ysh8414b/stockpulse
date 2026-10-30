-- ═══════════════════════════════════════════════════════════════
-- APS — 진행중/완료 계획의 실제 시작 시각 수정 (2026-10-30)
-- ▶ 시작 버튼을 늦게(또는 일찍) 눌렀을 때 실제 시작 시각을 고침
-- 1회 실행 (재실행 안전). setup_aps_v3.sql(actual_start_at) 실행 전제
-- ═══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION aps_set_plan_actual_start(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_actual_start_at TIMESTAMPTZ
) RETURNS JSON AS $$
DECLARE
  v_status TEXT;
  v_end TIMESTAMPTZ;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);

  SELECT status, actual_end_at INTO v_status, v_end FROM aps_plans WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;
  IF v_status NOT IN ('in_progress', 'done') THEN
    RAISE EXCEPTION 'not_started';
  END IF;
  IF p_actual_start_at IS NULL THEN
    RAISE EXCEPTION 'actual_start_required';
  END IF;
  IF p_actual_start_at > now() + INTERVAL '5 minutes' THEN
    RAISE EXCEPTION 'start_in_future';
  END IF;
  IF v_end IS NOT NULL AND p_actual_start_at >= v_end THEN
    RAISE EXCEPTION 'start_after_end';
  END IF;

  UPDATE aps_plans
     SET actual_start_at = p_actual_start_at,
         updated_at = now()
   WHERE id = p_id;

  RETURN json_build_object('id', p_id, 'actual_start_at', p_actual_start_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
