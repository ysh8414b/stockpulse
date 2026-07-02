-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 회의록 관리 (Meetings)
-- ─ 회의 헤더 (제목/일시/참석자/작성자/메모)
-- ─ 회의 항목 (안건/결정사항/액션아이템 + 담당자/기한/완료 체크)
-- 전제: setup_aps.sql 실행 완료 (board_admins / aps_assert_admin 필요)
-- Supabase SQL Editor에서 1회 실행
-- ═══════════════════════════════════════════

-- ───────────────────────────────────────────
-- 1. 회의록 헤더
-- ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS aps_meetings (
  id          BIGSERIAL PRIMARY KEY,
  meeting_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  title       TEXT NOT NULL,
  attendees   TEXT NOT NULL DEFAULT '',
  author      TEXT NOT NULL DEFAULT '',
  memo        TEXT NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_aps_meetings_at ON aps_meetings(meeting_at DESC);

ALTER TABLE aps_meetings ENABLE ROW LEVEL SECURITY;
-- 정책 없음 → REST 직접 접근 차단, RPC만 허용

-- ───────────────────────────────────────────
-- 2. 회의록 항목 (안건/결정사항/액션)
-- ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS aps_meeting_items (
  id           BIGSERIAL PRIMARY KEY,
  meeting_id   BIGINT NOT NULL REFERENCES aps_meetings(id) ON DELETE CASCADE,
  kind         TEXT   NOT NULL CHECK (kind IN ('agenda','decision','action')),
  content      TEXT   NOT NULL DEFAULT '',
  assignee     TEXT   NOT NULL DEFAULT '',
  due_date     DATE,
  done         BOOLEAN NOT NULL DEFAULT FALSE,
  sort_order   INT,
  created_at   TIMESTAMPTZ DEFAULT now(),
  updated_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_aps_meeting_items_mtg ON aps_meeting_items(meeting_id, kind, sort_order);

ALTER TABLE aps_meeting_items ENABLE ROW LEVEL SECURITY;

-- 자동 sort_order (같은 meeting_id + kind 안에서 max+1)
CREATE OR REPLACE FUNCTION aps_meeting_items_assign_sort_order()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.sort_order IS NULL THEN
    SELECT COALESCE(MAX(sort_order), 0) + 1
      INTO NEW.sort_order
      FROM aps_meeting_items
     WHERE meeting_id = NEW.meeting_id AND kind = NEW.kind;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_aps_meeting_items_sort_order ON aps_meeting_items;
CREATE TRIGGER trg_aps_meeting_items_sort_order
  BEFORE INSERT ON aps_meeting_items
  FOR EACH ROW
  EXECUTE FUNCTION aps_meeting_items_assign_sort_order();

-- ───────────────────────────────────────────
-- RPC: 회의록 목록 (최근순 + 항목 카운트)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_list_meetings(
  p_admin_hash TEXT,
  p_days       INT DEFAULT NULL,   -- NULL = 전체
  p_search     TEXT DEFAULT ''
)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.meeting_at DESC, t.id DESC), '[]'::json)
    FROM (
      SELECT m.id, m.meeting_at, m.title, m.attendees, m.author, m.memo,
             (SELECT COUNT(*) FROM aps_meeting_items WHERE meeting_id = m.id) AS item_count,
             (SELECT COUNT(*) FROM aps_meeting_items
               WHERE meeting_id = m.id AND kind = 'action' AND done = FALSE) AS open_actions
      FROM aps_meetings m
      WHERE (p_days IS NULL OR m.meeting_at >= now() - (p_days || ' days')::INTERVAL)
        AND (COALESCE(TRIM(p_search),'') = ''
             OR m.title      ILIKE '%'||p_search||'%'
             OR m.attendees  ILIKE '%'||p_search||'%'
             OR m.author     ILIKE '%'||p_search||'%'
             OR m.memo       ILIKE '%'||p_search||'%')
    ) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 단일 회의록 (헤더 + 모든 항목)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_meeting(
  p_admin_hash TEXT,
  p_id         BIGINT
)
RETURNS JSON AS $$
DECLARE
  v_meeting JSON;
  v_items   JSON;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT row_to_json(m) INTO v_meeting FROM aps_meetings m WHERE m.id = p_id;
  IF v_meeting IS NULL THEN RAISE EXCEPTION 'meeting_not_found'; END IF;

  SELECT COALESCE(json_agg(row_to_json(i) ORDER BY i.kind, i.sort_order NULLS LAST, i.id), '[]'::json)
    INTO v_items
    FROM aps_meeting_items i
   WHERE i.meeting_id = p_id;

  RETURN json_build_object('meeting', v_meeting, 'items', v_items);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 회의록 헤더 추가/수정
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_upsert_meeting(
  p_admin_hash TEXT,
  p_id         BIGINT,
  p_meeting_at TIMESTAMPTZ,
  p_title      TEXT,
  p_attendees  TEXT,
  p_author     TEXT,
  p_memo       TEXT
)
RETURNS JSON AS $$
DECLARE
  v_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_title IS NULL OR TRIM(p_title) = '' THEN
    RAISE EXCEPTION 'title_required';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO aps_meetings(meeting_at, title, attendees, author, memo)
    VALUES (COALESCE(p_meeting_at, now()), TRIM(p_title),
            COALESCE(p_attendees,''), COALESCE(p_author,''), COALESCE(p_memo,''))
    RETURNING id INTO v_id;
  ELSE
    UPDATE aps_meetings
       SET meeting_at = COALESCE(p_meeting_at, meeting_at),
           title      = TRIM(p_title),
           attendees  = COALESCE(p_attendees,''),
           author     = COALESCE(p_author,''),
           memo       = COALESCE(p_memo,''),
           updated_at = now()
     WHERE id = p_id;
    v_id := p_id;
  END IF;
  RETURN json_build_object('id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 회의록 삭제 (항목 CASCADE)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_delete_meeting(p_admin_hash TEXT, p_id BIGINT)
RETURNS JSON AS $$
DECLARE v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_meetings WHERE id = p_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 회의 항목 추가/수정
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_upsert_meeting_item(
  p_admin_hash TEXT,
  p_id         BIGINT,
  p_meeting_id BIGINT,
  p_kind       TEXT,
  p_content    TEXT,
  p_assignee   TEXT,
  p_due_date   DATE,
  p_done       BOOLEAN
)
RETURNS JSON AS $$
DECLARE
  v_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_kind NOT IN ('agenda','decision','action') THEN
    RAISE EXCEPTION 'invalid_kind';
  END IF;
  IF p_meeting_id IS NULL THEN RAISE EXCEPTION 'meeting_id_required'; END IF;

  IF p_id IS NULL THEN
    INSERT INTO aps_meeting_items(meeting_id, kind, content, assignee, due_date, done)
    VALUES (p_meeting_id, p_kind, COALESCE(p_content,''),
            COALESCE(p_assignee,''), p_due_date, COALESCE(p_done, FALSE))
    RETURNING id INTO v_id;
  ELSE
    UPDATE aps_meeting_items
       SET kind       = p_kind,
           content    = COALESCE(p_content,''),
           assignee   = COALESCE(p_assignee,''),
           due_date   = p_due_date,
           done       = COALESCE(p_done, done),
           updated_at = now()
     WHERE id = p_id;
    v_id := p_id;
  END IF;
  RETURN json_build_object('id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 항목 삭제
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_delete_meeting_item(p_admin_hash TEXT, p_id BIGINT)
RETURNS JSON AS $$
DECLARE v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_meeting_items WHERE id = p_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ───────────────────────────────────────────
-- RPC: 액션 완료 토글 (빠른 갱신용)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_toggle_meeting_item_done(p_admin_hash TEXT, p_id BIGINT)
RETURNS JSON AS $$
DECLARE v_done BOOLEAN;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  UPDATE aps_meeting_items
     SET done = NOT done,
         updated_at = now()
   WHERE id = p_id
   RETURNING done INTO v_done;
  IF v_done IS NULL THEN RAISE EXCEPTION 'item_not_found'; END IF;
  RETURN json_build_object('id', p_id, 'done', v_done);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
