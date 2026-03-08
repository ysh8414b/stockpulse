-- ═══════════════════════════════════════════
-- STOCKPULSE 자유게시판 테이블 설정
-- Supabase SQL Editor에서 실행
-- ═══════════════════════════════════════════

-- 1. 게시글 테이블
CREATE TABLE board_posts (
  id BIGSERIAL PRIMARY KEY,
  nickname TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  comment_count INT DEFAULT 0,
  is_pinned BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE board_posts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read_posts" ON board_posts FOR SELECT USING (true);

-- 2. 댓글 테이블
CREATE TABLE board_comments (
  id BIGSERIAL PRIMARY KEY,
  post_id BIGINT REFERENCES board_posts(id) ON DELETE CASCADE,
  nickname TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE board_comments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read_comments" ON board_comments FOR SELECT USING (true);

-- 3. 뷰 (password_hash 숨김, 공지 우선 정렬)
CREATE VIEW board_posts_public AS
  SELECT id, nickname, title, content, comment_count, is_pinned, created_at, updated_at
  FROM board_posts
  ORDER BY is_pinned DESC, created_at DESC;

CREATE VIEW board_comments_public AS
  SELECT id, post_id, nickname, content, created_at
  FROM board_comments
  ORDER BY created_at ASC;

-- 4. 댓글 수 자동 업데이트 트리거
CREATE OR REPLACE FUNCTION update_comment_count() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE board_posts SET comment_count = comment_count + 1 WHERE id = NEW.post_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE board_posts SET comment_count = comment_count - 1 WHERE id = OLD.post_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_comment_count
AFTER INSERT OR DELETE ON board_comments
FOR EACH ROW EXECUTE FUNCTION update_comment_count();

-- ═══════════════════════════════════════════
-- 관리자 시스템
-- ═══════════════════════════════════════════

-- 5. 관리자 테이블
CREATE TABLE board_admins (
  id BIGSERIAL PRIMARY KEY,
  nickname TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL UNIQUE,
  role TEXT NOT NULL DEFAULT 'moderator' CHECK (role IN ('superadmin','moderator')),
  permissions JSONB NOT NULL DEFAULT '{"delete_posts":false,"delete_comments":false,"edit_posts":false,"pin_posts":false,"use_reserved_names":false}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE board_admins ENABLE ROW LEVEL SECURITY;
-- SELECT 정책 없음 → REST API 직접 조회 차단, RPC(SECURITY DEFINER)만 접근 가능

-- 6. 슈퍼관리자 시드
INSERT INTO board_admins (nickname, password_hash, role, permissions) VALUES (
  'admin',
  '8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918',
  'superadmin',
  '{"delete_posts":true,"delete_comments":true,"edit_posts":true,"pin_posts":true,"use_reserved_names":true}'::jsonb
);

-- ═══════════════════════════════════════════
-- 게시판 RPC 함수 (board_admins 연동)
-- ═══════════════════════════════════════════

-- 7. 게시글 작성 RPC (30초 쿨다운 + 차단/예약 닉네임 검사)
CREATE OR REPLACE FUNCTION insert_board_post(p_nickname TEXT, p_password_hash TEXT, p_title TEXT, p_content TEXT)
RETURNS BIGINT AS $$
DECLARE
  last_time TIMESTAMPTZ;
  new_id BIGINT;
  admin_rec board_admins;
  reserved_names TEXT[] := ARRAY['운영자','관리자','admin','ADMIN','Admin','운영진','매니저'];
BEGIN
  -- 차단/예약 닉네임 검사 (관리자는 우회 가능)
  IF EXISTS (SELECT 1 FROM banned_nicknames WHERE LOWER(nickname) = LOWER(p_nickname)) OR p_nickname = ANY(reserved_names) THEN
    SELECT * INTO admin_rec FROM board_admins WHERE password_hash = p_password_hash;
    IF NOT FOUND OR NOT (admin_rec.role = 'superadmin' OR (admin_rec.permissions->>'use_reserved_names')::boolean) THEN
      IF EXISTS (SELECT 1 FROM banned_nicknames WHERE LOWER(nickname) = LOWER(p_nickname)) THEN
        RAISE EXCEPTION 'banned_nickname';
      ELSE
        RAISE EXCEPTION 'reserved_name';
      END IF;
    END IF;
  END IF;
  SELECT created_at INTO last_time FROM board_posts WHERE nickname = p_nickname ORDER BY created_at DESC LIMIT 1;
  IF last_time IS NOT NULL AND (now() - last_time) < interval '30 seconds' THEN
    RAISE EXCEPTION 'too_fast';
  END IF;
  INSERT INTO board_posts (nickname, password_hash, title, content)
  VALUES (p_nickname, p_password_hash, p_title, p_content)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. 댓글 작성 RPC (15초 쿨다운 + 차단/예약 닉네임 검사)
CREATE OR REPLACE FUNCTION insert_board_comment(p_post_id BIGINT, p_nickname TEXT, p_password_hash TEXT, p_content TEXT)
RETURNS BIGINT AS $$
DECLARE
  last_time TIMESTAMPTZ;
  new_id BIGINT;
  admin_rec board_admins;
  reserved_names TEXT[] := ARRAY['운영자','관리자','admin','ADMIN','Admin','운영진','매니저'];
BEGIN
  -- 차단/예약 닉네임 검사 (관리자는 우회 가능)
  IF EXISTS (SELECT 1 FROM banned_nicknames WHERE LOWER(nickname) = LOWER(p_nickname)) OR p_nickname = ANY(reserved_names) THEN
    SELECT * INTO admin_rec FROM board_admins WHERE password_hash = p_password_hash;
    IF NOT FOUND OR NOT (admin_rec.role = 'superadmin' OR (admin_rec.permissions->>'use_reserved_names')::boolean) THEN
      IF EXISTS (SELECT 1 FROM banned_nicknames WHERE LOWER(nickname) = LOWER(p_nickname)) THEN
        RAISE EXCEPTION 'banned_nickname';
      ELSE
        RAISE EXCEPTION 'reserved_name';
      END IF;
    END IF;
  END IF;
  SELECT created_at INTO last_time FROM board_comments WHERE nickname = p_nickname ORDER BY created_at DESC LIMIT 1;
  IF last_time IS NOT NULL AND (now() - last_time) < interval '15 seconds' THEN
    RAISE EXCEPTION 'too_fast';
  END IF;
  INSERT INTO board_comments (post_id, nickname, password_hash, content)
  VALUES (p_post_id, p_nickname, p_password_hash, p_content)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 9. 게시글 삭제 RPC (관리자 권한 또는 작성자 비밀번호)
CREATE OR REPLACE FUNCTION delete_board_post(p_id BIGINT, p_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_rec board_admins;
BEGIN
  SELECT * INTO admin_rec FROM board_admins WHERE password_hash = p_hash;
  IF FOUND AND (admin_rec.role = 'superadmin' OR (admin_rec.permissions->>'delete_posts')::boolean) THEN
    DELETE FROM board_posts WHERE id = p_id;
    RETURN true;
  END IF;
  DELETE FROM board_posts WHERE id = p_id AND password_hash = p_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 10. 댓글 삭제 RPC (관리자 권한 또는 작성자 비밀번호)
CREATE OR REPLACE FUNCTION delete_board_comment(c_id BIGINT, c_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_rec board_admins;
BEGIN
  SELECT * INTO admin_rec FROM board_admins WHERE password_hash = c_hash;
  IF FOUND AND (admin_rec.role = 'superadmin' OR (admin_rec.permissions->>'delete_comments')::boolean) THEN
    DELETE FROM board_comments WHERE id = c_id;
    RETURN true;
  END IF;
  DELETE FROM board_comments WHERE id = c_id AND password_hash = c_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 11. 게시글 수정 RPC (관리자 권한 또는 작성자 비밀번호)
CREATE OR REPLACE FUNCTION update_board_post(p_id BIGINT, p_hash TEXT, p_title TEXT, p_content TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_rec board_admins;
BEGIN
  SELECT * INTO admin_rec FROM board_admins WHERE password_hash = p_hash;
  IF FOUND AND (admin_rec.role = 'superadmin' OR (admin_rec.permissions->>'edit_posts')::boolean) THEN
    UPDATE board_posts SET title = p_title, content = p_content, updated_at = now() WHERE id = p_id;
    RETURN FOUND;
  END IF;
  UPDATE board_posts SET title = p_title, content = p_content, updated_at = now() WHERE id = p_id AND password_hash = p_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 12. 공지 고정/해제 RPC (관리자 pin_posts 권한 필요)
CREATE OR REPLACE FUNCTION toggle_pin_post(p_id BIGINT, p_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_rec board_admins;
BEGIN
  SELECT * INTO admin_rec FROM board_admins WHERE password_hash = p_hash;
  IF NOT FOUND OR NOT (admin_rec.role = 'superadmin' OR (admin_rec.permissions->>'pin_posts')::boolean) THEN
    RETURN false;
  END IF;
  UPDATE board_posts SET is_pinned = NOT is_pinned WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 관리자 관리 RPC 함수
-- ═══════════════════════════════════════════

-- 13. 관리자 로그인
CREATE OR REPLACE FUNCTION admin_login(p_hash TEXT)
RETURNS JSON AS $$
DECLARE
  admin_row board_admins;
BEGIN
  SELECT * INTO admin_row FROM board_admins WHERE password_hash = p_hash;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN json_build_object(
    'id', admin_row.id,
    'nickname', admin_row.nickname,
    'role', admin_row.role,
    'permissions', admin_row.permissions
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 14. 관리자 목록 조회 (superadmin 전용)
CREATE OR REPLACE FUNCTION list_board_admins(p_admin_hash TEXT)
RETURNS JSON AS $$
DECLARE
  caller board_admins;
BEGIN
  SELECT * INTO caller FROM board_admins WHERE password_hash = p_admin_hash;
  IF NOT FOUND OR caller.role != 'superadmin' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'nickname', nickname, 'role', role,
      'permissions', permissions, 'created_at', created_at
    ) ORDER BY created_at ASC), '[]'::json)
    FROM board_admins
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 15. 관리자 추가 (superadmin 전용)
CREATE OR REPLACE FUNCTION add_board_admin(p_admin_hash TEXT, p_nickname TEXT, p_password_hash TEXT, p_permissions JSONB)
RETURNS BIGINT AS $$
DECLARE
  caller board_admins;
  new_id BIGINT;
BEGIN
  SELECT * INTO caller FROM board_admins WHERE password_hash = p_admin_hash;
  IF NOT FOUND OR caller.role != 'superadmin' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF EXISTS (SELECT 1 FROM board_admins WHERE nickname = p_nickname) THEN
    RAISE EXCEPTION 'duplicate_nickname';
  END IF;
  IF EXISTS (SELECT 1 FROM board_admins WHERE password_hash = p_password_hash) THEN
    RAISE EXCEPTION 'duplicate_password';
  END IF;
  INSERT INTO board_admins (nickname, password_hash, role, permissions)
  VALUES (p_nickname, p_password_hash, 'moderator', p_permissions)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 16. 관리자 권한 수정 (superadmin 전용, superadmin 수정 불가)
CREATE OR REPLACE FUNCTION update_board_admin(p_admin_hash TEXT, p_target_id BIGINT, p_permissions JSONB)
RETURNS BOOLEAN AS $$
DECLARE
  caller board_admins;
  target board_admins;
BEGIN
  SELECT * INTO caller FROM board_admins WHERE password_hash = p_admin_hash;
  IF NOT FOUND OR caller.role != 'superadmin' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  SELECT * INTO target FROM board_admins WHERE id = p_target_id;
  IF NOT FOUND THEN RETURN false; END IF;
  IF target.role = 'superadmin' THEN
    RAISE EXCEPTION 'cannot_modify_superadmin';
  END IF;
  UPDATE board_admins SET permissions = p_permissions WHERE id = p_target_id;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 17. 비밀번호 변경 (본인 확인 후 변경)
CREATE OR REPLACE FUNCTION change_admin_password(p_old_hash TEXT, p_new_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_rec board_admins;
BEGIN
  SELECT * INTO admin_rec FROM board_admins WHERE password_hash = p_old_hash;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF EXISTS (SELECT 1 FROM board_admins WHERE password_hash = p_new_hash) THEN
    RAISE EXCEPTION 'duplicate_password';
  END IF;
  UPDATE board_admins SET password_hash = p_new_hash WHERE id = admin_rec.id;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 18. 관리자 삭제 (superadmin 전용, superadmin 삭제 불가)
CREATE OR REPLACE FUNCTION delete_board_admin(p_admin_hash TEXT, p_target_id BIGINT)
RETURNS BOOLEAN AS $$
DECLARE
  caller board_admins;
  target board_admins;
BEGIN
  SELECT * INTO caller FROM board_admins WHERE password_hash = p_admin_hash;
  IF NOT FOUND OR caller.role != 'superadmin' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  SELECT * INTO target FROM board_admins WHERE id = p_target_id;
  IF NOT FOUND THEN RETURN false; END IF;
  IF target.role = 'superadmin' THEN
    RAISE EXCEPTION 'cannot_delete_superadmin';
  END IF;
  DELETE FROM board_admins WHERE id = p_target_id;
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 닉네임 제한(차단) 시스템
-- ═══════════════════════════════════════════

-- 19. 차단 닉네임 테이블
CREATE TABLE banned_nicknames (
  id BIGSERIAL PRIMARY KEY,
  nickname TEXT NOT NULL,
  reason TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE UNIQUE INDEX idx_banned_nicknames_lower ON banned_nicknames (LOWER(nickname));

ALTER TABLE banned_nicknames ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read_banned" ON banned_nicknames FOR SELECT USING (true);

-- 20. 차단 닉네임 확인 (공개 — 채팅/게시판 클라이언트용)
CREATE OR REPLACE FUNCTION check_banned_nickname(p_nickname TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM banned_nicknames WHERE LOWER(nickname) = LOWER(p_nickname));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 21. 차단 닉네임 목록 조회 (superadmin 전용)
CREATE OR REPLACE FUNCTION list_banned_nicknames(p_admin_hash TEXT)
RETURNS JSON AS $$
DECLARE
  caller board_admins;
BEGIN
  SELECT * INTO caller FROM board_admins WHERE password_hash = p_admin_hash;
  IF NOT FOUND OR caller.role != 'superadmin' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'nickname', nickname, 'reason', reason, 'created_at', created_at
    ) ORDER BY created_at DESC), '[]'::json)
    FROM banned_nicknames
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 21. 차단 닉네임 추가 (superadmin 전용)
CREATE OR REPLACE FUNCTION add_banned_nickname(p_admin_hash TEXT, p_nickname TEXT, p_reason TEXT DEFAULT '')
RETURNS BIGINT AS $$
DECLARE
  caller board_admins;
  new_id BIGINT;
BEGIN
  SELECT * INTO caller FROM board_admins WHERE password_hash = p_admin_hash;
  IF NOT FOUND OR caller.role != 'superadmin' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF EXISTS (SELECT 1 FROM banned_nicknames WHERE LOWER(nickname) = LOWER(p_nickname)) THEN
    RAISE EXCEPTION 'duplicate_nickname';
  END IF;
  INSERT INTO banned_nicknames (nickname, reason) VALUES (p_nickname, p_reason) RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 22. 차단 닉네임 삭제 (superadmin 전용)
CREATE OR REPLACE FUNCTION remove_banned_nickname(p_admin_hash TEXT, p_id BIGINT)
RETURNS BOOLEAN AS $$
DECLARE
  caller board_admins;
BEGIN
  SELECT * INTO caller FROM board_admins WHERE password_hash = p_admin_hash;
  IF NOT FOUND OR caller.role != 'superadmin' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  DELETE FROM banned_nicknames WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 23. 채팅 메시지 전송 RPC (차단 닉네임 서버사이드 검사 + 관리자 우회) ═══
CREATE OR REPLACE FUNCTION insert_chat_message(p_nickname TEXT, p_message TEXT, p_admin_hash TEXT DEFAULT '')
RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
  admin_rec board_admins;
BEGIN
  IF EXISTS (SELECT 1 FROM banned_nicknames WHERE LOWER(nickname) = LOWER(p_nickname)) THEN
    IF p_admin_hash != '' THEN
      SELECT * INTO admin_rec FROM board_admins WHERE password_hash = p_admin_hash;
      IF NOT FOUND OR NOT (admin_rec.role = 'superadmin' OR (admin_rec.permissions->>'use_reserved_names')::boolean) THEN
        RAISE EXCEPTION 'banned_nickname';
      END IF;
    ELSE
      RAISE EXCEPTION 'banned_nickname';
    END IF;
  END IF;
  IF length(p_message) > 300 THEN
    RAISE EXCEPTION 'message_too_long';
  END IF;
  INSERT INTO chat_messages (nickname, message)
  VALUES (p_nickname, p_message)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
