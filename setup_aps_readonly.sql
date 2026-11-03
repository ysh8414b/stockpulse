-- ═══════════════════════════════════════════
-- APS — 👁 읽기 전용 접속 — 1회 실행 (다시 실행해도 안전)
--  로그인 화면의 "읽기 전용으로 보기" 버튼은 비밀번호 대신 'aps-readonly' 값을 보낸다.
--  · aps_assert_admin: 'aps-readonly'면 통과시키되 이 요청(트랜잭션)에 읽기 전용 표시를 켬
--  · 모든 aps_* 테이블에 트리거: 읽기 전용 표시가 켜진 요청의 INSERT/UPDATE/DELETE 거부
--  · Groq 호출(aps_ai_request / aps_ai_models_request)도 거부 (테이블 쓰기가 아니라서 따로 막음)
--  나중에 aps_ 테이블을 새로 만들면 이 파일을 다시 실행해야 그 테이블에도 트리거가 붙는다.
-- ═══════════════════════════════════════════

CREATE OR REPLACE FUNCTION aps_assert_admin(p_admin_hash TEXT)
RETURNS VOID AS $$
BEGIN
  IF p_admin_hash IS NULL OR p_admin_hash = '' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF p_admin_hash = 'aps-readonly' THEN
    PERFORM set_config('aps.readonly', 'on', true);  -- 이 트랜잭션 동안만
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM board_admins WHERE password_hash = p_admin_hash) THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_block_readonly()
RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('aps.readonly', true) = 'on' THEN
    RAISE EXCEPTION 'read_only';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 모든 aps_* 테이블에 트리거 부착
DO $$
DECLARE t RECORD;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'aps\_%' LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS aps_readonly_guard ON public.%I', t.tablename);
    EXECUTE format('CREATE TRIGGER aps_readonly_guard BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION aps_block_readonly()', t.tablename);
  END LOOP;
END $$;

-- Groq 호출 막기 (setup_aps_ai.sql을 실행한 경우에만 다시 정의)
DO $$
BEGIN
  IF to_regclass('public.aps_secrets') IS NULL THEN RETURN; END IF;

  EXECUTE $f$
  CREATE OR REPLACE FUNCTION aps_ai_request(p_admin_hash TEXT, p_messages JSONB, p_max_tokens INT DEFAULT 2048)
  RETURNS BIGINT AS $b$
  DECLARE
    v_key TEXT;
    v_model TEXT;
    v_id BIGINT;
  BEGIN
    PERFORM aps_assert_admin(p_admin_hash);
    IF p_admin_hash = 'aps-readonly' THEN RAISE EXCEPTION 'read_only'; END IF;
    SELECT value INTO v_key FROM aps_secrets WHERE key = 'groq_api_key';
    IF v_key IS NULL THEN RAISE EXCEPTION 'no_ai_key'; END IF;
    v_model := COALESCE((SELECT value FROM aps_secrets WHERE key = 'groq_model'), 'openai/gpt-oss-120b');
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
  $b$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
  $f$;

  EXECUTE $f$
  CREATE OR REPLACE FUNCTION aps_ai_models_request(p_admin_hash TEXT)
  RETURNS BIGINT AS $b$
  DECLARE
    v_key TEXT;
    v_id BIGINT;
  BEGIN
    PERFORM aps_assert_admin(p_admin_hash);
    IF p_admin_hash = 'aps-readonly' THEN RAISE EXCEPTION 'read_only'; END IF;
    SELECT value INTO v_key FROM aps_secrets WHERE key = 'groq_api_key';
    IF v_key IS NULL THEN RAISE EXCEPTION 'no_ai_key'; END IF;
    SELECT net.http_get(
      url := 'https://api.groq.com/openai/v1/models',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_key),
      timeout_milliseconds := 30000
    ) INTO v_id;
    RETURN v_id;
  END;
  $b$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
  $f$;
END $$;
