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

-- 5. 게시글 작성 RPC (30초 쿨다운)
CREATE OR REPLACE FUNCTION insert_board_post(p_nickname TEXT, p_password_hash TEXT, p_title TEXT, p_content TEXT)
RETURNS BIGINT AS $$
DECLARE
  last_time TIMESTAMPTZ;
  new_id BIGINT;
BEGIN
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

-- 6. 댓글 작성 RPC (15초 쿨다운)
CREATE OR REPLACE FUNCTION insert_board_comment(p_post_id BIGINT, p_nickname TEXT, p_password_hash TEXT, p_content TEXT)
RETURNS BIGINT AS $$
DECLARE
  last_time TIMESTAMPTZ;
  new_id BIGINT;
BEGIN
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

-- 7. 게시글 삭제 RPC (비밀번호 검증)
CREATE OR REPLACE FUNCTION delete_board_post(p_id BIGINT, p_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_hash TEXT := '8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918'; -- 'admin'의 SHA-256
BEGIN
  IF p_hash = admin_hash THEN
    DELETE FROM board_posts WHERE id = p_id;
    RETURN true;
  END IF;
  DELETE FROM board_posts WHERE id = p_id AND password_hash = p_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. 댓글 삭제 RPC (비밀번호 검증)
CREATE OR REPLACE FUNCTION delete_board_comment(c_id BIGINT, c_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_hash TEXT := '8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918'; -- 'admin'의 SHA-256
BEGIN
  IF c_hash = admin_hash THEN
    DELETE FROM board_comments WHERE id = c_id;
    RETURN true;
  END IF;
  DELETE FROM board_comments WHERE id = c_id AND password_hash = c_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 9. 게시글 수정 RPC (비밀번호 검증)
CREATE OR REPLACE FUNCTION update_board_post(p_id BIGINT, p_hash TEXT, p_title TEXT, p_content TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_hash TEXT := '8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918'; -- 'admin'의 SHA-256
BEGIN
  IF p_hash = admin_hash THEN
    UPDATE board_posts SET title = p_title, content = p_content, updated_at = now() WHERE id = p_id;
    RETURN FOUND;
  END IF;
  UPDATE board_posts SET title = p_title, content = p_content, updated_at = now() WHERE id = p_id AND password_hash = p_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 10. 공지 고정/해제 RPC (관리자 전용)
CREATE OR REPLACE FUNCTION toggle_pin_post(p_id BIGINT, p_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_hash TEXT := '8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918'; -- 'admin'의 SHA-256
BEGIN
  IF p_hash != admin_hash THEN
    RETURN false;
  END IF;
  UPDATE board_posts SET is_pinned = NOT is_pinned WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
