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
    'model', COALESCE((SELECT value FROM aps_secrets WHERE key = 'groq_model'), 'openai/gpt-oss-120b'),
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

-- ═══ 모델 관리 ═══
-- Groq는 모델을 종종 종료함 (llama-3.3-70b-versatile → 2026-08-16 종료, 대체: openai/gpt-oss-120b)
-- 페이지가 모델 없음 오류를 받으면 목록을 조회해 다른 모델로 바꾸고 다시 시도한다.

-- 사용 가능한 모델 목록 요청 → 요청 id (결과는 aps_ai_result로 확인)
CREATE OR REPLACE FUNCTION aps_ai_models_request(p_admin_hash TEXT)
RETURNS BIGINT AS $$
DECLARE
  v_key TEXT;
  v_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT value INTO v_key FROM aps_secrets WHERE key = 'groq_api_key';
  IF v_key IS NULL THEN RAISE EXCEPTION 'no_ai_key'; END IF;
  SELECT net.http_get(
    url := 'https://api.groq.com/openai/v1/models',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key),
    timeout_milliseconds := 30000
  ) INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 모델 저장 (빈 값 = 기본 모델)
CREATE OR REPLACE FUNCTION aps_ai_set_model(p_admin_hash TEXT, p_model TEXT)
RETURNS TEXT AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_model IS NULL OR btrim(p_model) = '' THEN
    DELETE FROM aps_secrets WHERE key = 'groq_model';
    RETURN 'openai/gpt-oss-120b';
  END IF;
  INSERT INTO aps_secrets (key, value, updated_at) VALUES ('groq_model', btrim(p_model), now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  RETURN btrim(p_model);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ═══════════════════════════════════════════
-- 📒 공장 규칙 노트 + 📝 AI 제안 피드백 기록 (2026-10-28)
--  노트: 관리자가 확정한 이 공장의 규칙 → AI 검토마다 함께 보냄 (AI의 기억)
--  피드백: AI 제안을 받아들였는지/뺐는지 + 뺀 이유 + 만든 계획 id
--          → 최근 거절 기록을 다음 검토에 함께 보내 같은 실수 반복 방지
--          → 계획 id로 나중에 실제 생산량과 비교 (주간 회고용)
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS aps_ai_notes (
  id BIGSERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  source TEXT NOT NULL DEFAULT 'manual',   -- manual | ai (회고에서 승인한 것)
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE aps_ai_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON aps_ai_notes FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS aps_ai_feedback (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ DEFAULT now(),
  day DATE,                    -- 계획 날짜
  kind TEXT NOT NULL,          -- change | line_off
  item_id BIGINT,
  item_name TEXT,
  line_id BIGINT,
  line_name TEXT,
  rule_qty NUMERIC,            -- 규칙 초안 수량 (0 = 초안에 없음)
  ai_qty NUMERIC,              -- AI 제안 수량 (0 = 빼기)
  accepted BOOLEAN NOT NULL,
  created_qty NUMERIC,         -- 실제로 만든 계획 수량 (만들지 않았으면 NULL)
  plan_id BIGINT,              -- 만든 계획 (삭제돼도 기록은 남음)
  ai_reason TEXT,
  user_note TEXT               -- 관리자가 뺀 이유
);
CREATE INDEX IF NOT EXISTS idx_aps_ai_feedback_created ON aps_ai_feedback (created_at DESC);
ALTER TABLE aps_ai_feedback ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON aps_ai_feedback FROM anon, authenticated;

CREATE OR REPLACE FUNCTION aps_ai_list_notes(p_admin_hash TEXT)
RETURNS JSONB AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(n) ORDER BY n.id) FROM aps_ai_notes n), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION aps_ai_upsert_note(p_admin_hash TEXT, p_id BIGINT, p_content TEXT, p_enabled BOOLEAN DEFAULT TRUE, p_source TEXT DEFAULT 'manual')
RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_content IS NULL OR btrim(p_content) = '' THEN RAISE EXCEPTION 'empty_note'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO aps_ai_notes (content, enabled, source)
    VALUES (left(btrim(p_content), 500), COALESCE(p_enabled, TRUE), COALESCE(NULLIF(p_source, ''), 'manual'))
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  UPDATE aps_ai_notes SET content = left(btrim(p_content), 500), enabled = COALESCE(p_enabled, enabled), updated_at = now()
   WHERE id = p_id;
  RETURN p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION aps_ai_delete_note(p_admin_hash TEXT, p_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_ai_notes WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 피드백 여러 건 저장: rows = [{day,kind,item_id,item_name,line_id,line_name,rule_qty,ai_qty,accepted,created_qty,plan_id,ai_reason,user_note}]
CREATE OR REPLACE FUNCTION aps_ai_log_feedback(p_admin_hash TEXT, p_rows JSONB)
RETURNS INT AS $$
DECLARE v_n INT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  INSERT INTO aps_ai_feedback (day, kind, item_id, item_name, line_id, line_name, rule_qty, ai_qty, accepted, created_qty, plan_id, ai_reason, user_note)
  SELECT NULLIF(r->>'day','')::date, COALESCE(NULLIF(r->>'kind',''),'change'),
         NULLIF(r->>'item_id','')::bigint, r->>'item_name',
         NULLIF(r->>'line_id','')::bigint, r->>'line_name',
         NULLIF(r->>'rule_qty','')::numeric, NULLIF(r->>'ai_qty','')::numeric,
         COALESCE((r->>'accepted')::boolean, FALSE),
         NULLIF(r->>'created_qty','')::numeric, NULLIF(r->>'plan_id','')::bigint,
         left(r->>'ai_reason', 500), left(r->>'user_note', 300)
    FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) r;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM aps_ai_feedback WHERE created_at < now() - interval '365 days';
  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 최근 피드백 + 만든 계획의 지금 상태(수정된 수량·실제 생산량)
CREATE OR REPLACE FUNCTION aps_ai_list_feedback(p_admin_hash TEXT, p_days INT DEFAULT 60, p_limit INT DEFAULT 200)
RETURNS JSONB AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN COALESCE((
    SELECT jsonb_agg(x ORDER BY x.created_at DESC) FROM (
      SELECT f.*, p.qty AS plan_qty_now, p.status AS plan_status, p.actual_qty AS plan_actual_qty
        FROM aps_ai_feedback f
        LEFT JOIN aps_plans p ON p.id = f.plan_id
       WHERE f.created_at >= now() - make_interval(days => GREATEST(COALESCE(p_days, 60), 1))
       ORDER BY f.created_at DESC
       LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000)
    ) x
  ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
