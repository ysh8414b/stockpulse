-- ═══════════════════════════════════════════
-- STOCKPULSE APS — ⚡ 생산 속도 예측용 라인↔부서 연결
-- Supabase SQL Editor에서 1회 실행 (재실행 안전)
-- 전제: setup_aps_v10.sql (aps_lines.auto_plan) + setup_aps_staff.sql
--
-- aps_lines.staff_depts: 이 라인에서 일하는 👥 인원 부서 이름 배열
--   비어 있으면 그날 전체 출근 인원을 씀
-- 속도 모델 자체는 화면(aps.html)에서 실적·출근 기록으로 바로 계산 (별도 테이블 없음)
-- ═══════════════════════════════════════════

ALTER TABLE aps_lines ADD COLUMN IF NOT EXISTS staff_depts JSONB NOT NULL DEFAULT '[]'::jsonb;

CREATE OR REPLACE FUNCTION aps_list_lines(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'code', code, 'name', name, 'memo', memo,
      'auto_plan', auto_plan,
      'staff_depts', staff_depts,
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY code), '[]'::json)
    FROM aps_lines
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_set_line_staff_depts(p_admin_hash TEXT, p_line_id BIGINT, p_depts JSONB)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_depts IS NULL OR jsonb_typeof(p_depts) <> 'array' THEN p_depts := '[]'::jsonb; END IF;
  UPDATE aps_lines SET staff_depts = p_depts, updated_at = now() WHERE id = p_line_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
