-- ═══════════════════════════════════════════
-- 여러 컴퓨터 동시 사용 — ol_settings 부분 수정 + 가벼운 조회 (2026-11-06)
-- 1회 실행 (재실행 안전). setup_orders.sql 끝에도 같은 내용이 들어 있음
--
-- 예전: 화면이 가진 값 전체를 ol_set_setting 으로 덮어씀
--   → A 컴퓨터가 고친 뒤 B 컴퓨터(옛 값 보유)가 다른 걸 고치면 A의 수정이 사라짐
-- 이제: 바뀐 부분만 서버에서 합침 (객체 = 키 단위, 배열 = 항목 추가/삭제)
-- ═══════════════════════════════════════════

-- 객체: value = (value - p_unset) || p_set
-- 배열: value = (value 에서 p_remove 항목 제거) + p_add 중 없는 항목
-- 반환 {value, at}
CREATE OR REPLACE FUNCTION ol_edit_setting(
  p_admin_hash TEXT, p_key TEXT,
  p_set JSONB DEFAULT NULL, p_unset TEXT[] DEFAULT NULL,
  p_add JSONB DEFAULT NULL, p_remove JSONB DEFAULT NULL
) RETURNS JSON AS $$
DECLARE v_key TEXT := TRIM(p_key); v_val JSONB; v_at TIMESTAMPTZ; v_arr BOOLEAN;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(v_key,'') = '' THEN RAISE EXCEPTION 'key_required'; END IF;
  v_arr := p_add IS NOT NULL OR p_remove IS NOT NULL;
  INSERT INTO ol_settings (key, value, updated_at)
  VALUES (v_key, CASE WHEN v_arr THEN '[]'::jsonb ELSE '{}'::jsonb END, clock_timestamp())
  ON CONFLICT (key) DO NOTHING;
  SELECT value INTO v_val FROM ol_settings WHERE key = v_key FOR UPDATE;

  IF v_arr THEN
    IF jsonb_typeof(v_val) <> 'array' THEN v_val := '[]'::jsonb; END IF;
    IF p_remove IS NOT NULL AND jsonb_typeof(p_remove) = 'array' THEN
      SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_val
      FROM jsonb_array_elements(v_val) e
      WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_remove) r WHERE r = e);
    END IF;
    IF p_add IS NOT NULL AND jsonb_typeof(p_add) = 'array' THEN
      SELECT v_val || COALESCE(jsonb_agg(a), '[]'::jsonb) INTO v_val
      FROM jsonb_array_elements(p_add) a
      WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_val) e WHERE e = a);
    END IF;
  ELSE
    IF jsonb_typeof(v_val) <> 'object' THEN v_val := '{}'::jsonb; END IF;
    IF p_unset IS NOT NULL THEN v_val := v_val - p_unset; END IF;
    IF p_set IS NOT NULL AND jsonb_typeof(p_set) = 'object' THEN v_val := v_val || p_set; END IF;
  END IF;

  UPDATE ol_settings SET value = v_val, updated_at = clock_timestamp()
  WHERE key = v_key RETURNING updated_at INTO v_at;
  RETURN json_build_object('value', v_val, 'at', v_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 지정한 키들만 조회 → {키: {value, at}} (화면을 열어 둔 동안 주기적으로 최신값 확인용)
CREATE OR REPLACE FUNCTION ol_get_settings(p_admin_hash TEXT, p_keys TEXT[])
RETURNS JSON AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  RETURN (SELECT COALESCE(json_object_agg(key, json_build_object('value', value, 'at', updated_at)), '{}'::json)
          FROM ol_settings WHERE key = ANY(p_keys));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
