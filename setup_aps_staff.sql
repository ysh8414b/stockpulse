-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 인원 관리 (Staff)
-- ─ 직원 마스터 (부서/이름/역할/메모)
-- ─ 날짜별 휴무 기록 (default = 활성 직원 전체 출근, 휴무자만 row)
-- 전제: setup_aps.sql 실행 완료 (board_admins / aps_assert_admin 필요)
-- Supabase SQL Editor에서 1회 실행
-- ═══════════════════════════════════════════

-- ───────────────────────────────────────────
-- 1. 직원 마스터
-- ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS aps_staff (
  id          BIGSERIAL PRIMARY KEY,
  department  TEXT NOT NULL DEFAULT '',
  name        TEXT NOT NULL,
  role        TEXT NOT NULL DEFAULT '',
  memo        TEXT NOT NULL DEFAULT '',
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order  INT,
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_aps_staff_active_dept ON aps_staff(active, department, sort_order);

ALTER TABLE aps_staff ENABLE ROW LEVEL SECURITY;
-- 정책 없음 → REST 직접 접근 차단, RPC만 허용

-- 자동 sort_order (같은 부서 내 max+1)
CREATE OR REPLACE FUNCTION aps_staff_assign_sort_order()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.sort_order IS NULL THEN
    SELECT COALESCE(MAX(sort_order), 0) + 1
      INTO NEW.sort_order
      FROM aps_staff
     WHERE department = NEW.department;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_aps_staff_sort_order ON aps_staff;
CREATE TRIGGER trg_aps_staff_sort_order
  BEFORE INSERT ON aps_staff
  FOR EACH ROW
  EXECUTE FUNCTION aps_staff_assign_sort_order();

-- ───────────────────────────────────────────
-- 2. 근태 기록 (휴무만 저장, default = 출근)
-- ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS aps_attendance (
  date        DATE   NOT NULL,
  staff_id    BIGINT NOT NULL REFERENCES aps_staff(id) ON DELETE CASCADE,
  status      TEXT   NOT NULL DEFAULT 'off',  -- off(휴무) / leave(연차) / sick(병가) / business(출장) 등
  memo        TEXT   NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (date, staff_id)
);
CREATE INDEX IF NOT EXISTS idx_aps_attendance_date ON aps_attendance(date);

ALTER TABLE aps_attendance ENABLE ROW LEVEL SECURITY;

-- ───────────────────────────────────────────
-- RPC: 직원 목록
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_list_staff(
  p_admin_hash  TEXT,
  p_only_active BOOLEAN DEFAULT TRUE
)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id,
      'department', department,
      'name', name,
      'role', role,
      'memo', memo,
      'active', active,
      'sort_order', sort_order
    ) ORDER BY department, sort_order NULLS LAST, id), '[]'::json)
    FROM aps_staff
    WHERE (NOT p_only_active OR active = TRUE)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 직원 추가/수정
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_upsert_staff(
  p_admin_hash TEXT,
  p_id         BIGINT,
  p_department TEXT,
  p_name       TEXT,
  p_role       TEXT,
  p_memo       TEXT,
  p_active     BOOLEAN
)
RETURNS JSON AS $$
DECLARE
  v_id BIGINT;
  v_old_dept TEXT;
  v_new_dept TEXT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_name IS NULL OR TRIM(p_name) = '' THEN
    RAISE EXCEPTION 'name_required';
  END IF;
  v_new_dept := COALESCE(TRIM(p_department), '');

  IF p_id IS NULL THEN
    INSERT INTO aps_staff(department, name, role, memo, active)
    VALUES (v_new_dept, TRIM(p_name), COALESCE(p_role, ''), COALESCE(p_memo, ''), COALESCE(p_active, TRUE))
    RETURNING id INTO v_id;
  ELSE
    SELECT department INTO v_old_dept FROM aps_staff WHERE id = p_id;
    UPDATE aps_staff
       SET department = v_new_dept,
           name       = TRIM(p_name),
           role       = COALESCE(p_role, ''),
           memo       = COALESCE(p_memo, ''),
           active     = COALESCE(p_active, active),
           sort_order = CASE
             WHEN v_old_dept IS DISTINCT FROM v_new_dept
               THEN (SELECT COALESCE(MAX(sort_order),0)+1 FROM aps_staff WHERE department = v_new_dept)
             ELSE sort_order
           END,
           updated_at = now()
     WHERE id = p_id;
    v_id := p_id;
  END IF;
  RETURN json_build_object('id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 직원 삭제 (관련 attendance 자동 CASCADE)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_delete_staff(p_admin_hash TEXT, p_id BIGINT)
RETURNS JSON AS $$
DECLARE v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_staff WHERE id = p_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 같은 부서 내 인접 직원과 sort_order swap (↑/↓)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_move_staff_order(
  p_admin_hash TEXT,
  p_id         BIGINT,
  p_direction  TEXT  -- 'up' / 'down'
)
RETURNS JSON AS $$
DECLARE
  v_dept       TEXT;
  v_order      INT;
  v_adj_id     BIGINT;
  v_adj_order  INT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT department, sort_order INTO v_dept, v_order FROM aps_staff WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'staff_not_found'; END IF;

  IF p_direction = 'up' THEN
    SELECT id, sort_order INTO v_adj_id, v_adj_order
      FROM aps_staff
     WHERE department = v_dept AND sort_order < v_order
     ORDER BY sort_order DESC
     LIMIT 1;
  ELSE
    SELECT id, sort_order INTO v_adj_id, v_adj_order
      FROM aps_staff
     WHERE department = v_dept AND sort_order > v_order
     ORDER BY sort_order ASC
     LIMIT 1;
  END IF;

  IF v_adj_id IS NULL THEN
    RETURN json_build_object('moved', FALSE);
  END IF;

  UPDATE aps_staff SET sort_order = v_adj_order WHERE id = p_id;
  UPDATE aps_staff SET sort_order = v_order     WHERE id = v_adj_id;
  RETURN json_build_object('moved', TRUE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 특정 날짜의 휴무자 목록 (출근은 row 없음 = default)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_attendance(p_admin_hash TEXT, p_date DATE)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'staff_id', staff_id,
      'status',   status,
      'memo',     memo
    )), '[]'::json)
    FROM aps_attendance
    WHERE date = p_date
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 근태 토글 — status='work'이면 row 삭제, 그 외는 upsert
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_set_attendance(
  p_admin_hash TEXT,
  p_date       DATE,
  p_staff_id   BIGINT,
  p_status     TEXT,
  p_memo       TEXT DEFAULT ''
)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_status IS NULL OR p_status = '' OR p_status = 'work' THEN
    DELETE FROM aps_attendance WHERE date = p_date AND staff_id = p_staff_id;
  ELSE
    INSERT INTO aps_attendance(date, staff_id, status, memo)
    VALUES (p_date, p_staff_id, p_status, COALESCE(p_memo, ''))
    ON CONFLICT (date, staff_id) DO UPDATE
      SET status = EXCLUDED.status,
          memo   = EXCLUDED.memo;
  END IF;
  RETURN json_build_object('ok', TRUE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 기간 내 모든 근태 기록 (캘린더 뷰용 — 추후 사용)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_attendance_range(
  p_admin_hash TEXT,
  p_start      DATE,
  p_end        DATE
)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'date',     date,
      'staff_id', staff_id,
      'status',   status,
      'memo',     memo
    ) ORDER BY date), '[]'::json)
    FROM aps_attendance
    WHERE date BETWEEN p_start AND p_end
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
