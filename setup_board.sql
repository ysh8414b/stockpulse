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
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE board_posts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read_posts" ON board_posts FOR SELECT USING (true);
CREATE POLICY "insert_posts" ON board_posts FOR INSERT WITH CHECK (true);

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
CREATE POLICY "insert_comments" ON board_comments FOR INSERT WITH CHECK (true);

-- 3. 뷰 (password_hash 숨김)
CREATE VIEW board_posts_public AS
  SELECT id, nickname, title, content, comment_count, created_at, updated_at
  FROM board_posts
  ORDER BY created_at DESC;

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

-- 5. 게시글 삭제 RPC (비밀번호 검증)
-- ※ '여기에_관리자_비밀번호_SHA256_해시' 부분을 실제 관리자 비밀번호의 SHA-256 해시로 교체하세요
CREATE OR REPLACE FUNCTION delete_board_post(p_id BIGINT, p_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_hash TEXT := '8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918'; -- 'admin' 의 SHA-256
BEGIN
  IF p_hash = admin_hash THEN
    DELETE FROM board_posts WHERE id = p_id;
    RETURN true;
  END IF;
  DELETE FROM board_posts WHERE id = p_id AND password_hash = p_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. 댓글 삭제 RPC (비밀번호 검증)
CREATE OR REPLACE FUNCTION delete_board_comment(c_id BIGINT, c_hash TEXT)
RETURNS BOOLEAN AS $$
DECLARE
  admin_hash TEXT := '8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918'; -- 'admin' 의 SHA-256
BEGIN
  IF c_hash = admin_hash THEN
    DELETE FROM board_comments WHERE id = c_id;
    RETURN true;
  END IF;
  DELETE FROM board_comments WHERE id = c_id AND password_hash = c_hash;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
