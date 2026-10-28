-- ═══════════════════════════════════════════
-- APS — 🧠 AI 검토 (Groq) — 1회 실행
--  페이지에 API 키를 넣으면 누구나 볼 수 있으므로,
--  키는 Supabase 안(aps_secrets)에만 두고 Supabase가 대신 Groq를 호출한다.
--  호출은 pg_net(비동기) → 요청 id를 받고, 페이지가 결과를 몇 초마다 확인.
--  setup_aps.sql 실행 전제 (aps_assert_admin 사용). 다시 실행해도 안전.
-- ═══════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS aps_secrets (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE aps_secrets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON aps_secrets FROM anon, authenticated;

-- 상태: 키 등록 여부 / 모델 (키 값은 절대 돌려주지 않음)
CREATE OR REPLACE FUNCTION aps_ai_status(p_admin_hash TEXT)
RETURNS JSONB AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN jsonb_build_object(
    'has_key', EXISTS (SELECT 1 FROM aps_secrets WHERE key = 'groq_api_key'),
    'model', COALESCE((SELECT value FROM aps_secrets WHERE key = 'groq_model'), 'llama-3.3-70b-versatile'),
    'net', EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 키 저장 (빈 값 = 삭제)
CREATE OR REPLACE FUNCTION aps_ai_set_key(p_admin_hash TEXT, p_key TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_key IS NULL OR btrim(p_key) = '' THEN
    DELETE FROM aps_secrets WHERE key = 'groq_api_key';
    RETURN false;
  END IF;
  INSERT INTO aps_secrets (key, value, updated_at) VALUES ('groq_api_key', btrim(p_key), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 요청 보내기 → 요청 id (결과는 aps_ai_result로 확인)
CREATE OR REPLACE FUNCTION aps_ai_request(p_admin_hash TEXT, p_messages JSONB, p_max_tokens INT DEFAULT 2048)
RETURNS BIGINT AS $$
DECLARE
  v_key TEXT;
  v_model TEXT;
  v_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT value INTO v_key FROM aps_secrets WHERE key = 'groq_api_key';
  IF v_key IS NULL THEN RAISE EXCEPTION 'no_ai_key'; END IF;
  v_model := COALESCE((SELECT value FROM aps_secrets WHERE key = 'groq_model'), 'llama-3.3-70b-versatile');
  SELECT net.http_post(
    url := 'https://api.groq.com/openai/v1/chat/completions',
    body := jsonb_build_object(
      'model', v_model,
      'messages', p_messages,
      'temperature', 0.2,
      'max_tokens', LEAST(GREATEST(COALESCE(p_max_tokens, 2048), 256), 8000),
      'response_format', jsonb_build_object('type', 'json_object')
    ),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    timeout_milliseconds := 90000
  ) INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 결과 확인: 아직이면 {pending:true}
CREATE OR REPLACE FUNCTION aps_ai_result(p_admin_hash TEXT, p_id BIGINT)
RETURNS JSONB AS $$
DECLARE
  r RECORD;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT status_code, content, timed_out, error_msg INTO r FROM net._http_response WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('pending', true); END IF;
  RETURN jsonb_build_object(
    'pending', false,
    'status', r.status_code,
    'content', r.content,
    'timed_out', r.timed_out,
    'error', r.error_msg
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 모델 바꾸기 (선택): INSERT INTO aps_secrets(key,value) VALUES('groq_model','llama-3.3-70b-versatile') ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;
