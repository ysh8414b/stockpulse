-- 자동 리스트 생성기 — 혼적 적재방식별 1자리 최대 단수 (2026-10-15)
-- setup_orders.sql 실행 이후 1회 실행 (재실행 안전)
-- mix_layers: 혼적 1자리에 쌓는 최대 박스 수. NULL = ⚙ 파렛트 설정의 '혼적 최대 단수' 사용
--   박스가 높아 6단까지 못 쌓는 제품은 4단 등으로 따로 만든 혼적 방식을 지정

ALTER TABLE ol_load_methods ADD COLUMN IF NOT EXISTS mix_layers INT CHECK (mix_layers IS NULL OR mix_layers > 0);

DROP FUNCTION IF EXISTS ol_upsert_method(TEXT, BIGINT, TEXT, TEXT, INT, INT, TEXT, INT);
CREATE OR REPLACE FUNCTION ol_upsert_method(
  p_admin_hash TEXT, p_id BIGINT, p_name TEXT, p_kind TEXT, p_max_boxes INT, p_cols INT, p_memo TEXT,
  p_per_layer INT DEFAULT 6, p_mix_layers INT DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT; v_ml INT;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_name),'') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  v_ml := CASE WHEN p_mix_layers IS NULL OR p_mix_layers < 1 THEN NULL ELSE p_mix_layers END;
  IF p_id IS NULL THEN
    INSERT INTO ol_load_methods (name, kind, max_boxes, cols, memo, per_layer, mix_layers)
    VALUES (TRIM(p_name), COALESCE(p_kind,'single'), GREATEST(COALESCE(p_max_boxes,40),1), GREATEST(COALESCE(p_cols,3),1), COALESCE(p_memo,''),
            GREATEST(COALESCE(p_per_layer,6),1), v_ml)
    RETURNING id INTO v_id;
  ELSE
    UPDATE ol_load_methods SET name = TRIM(p_name), kind = COALESCE(p_kind,'single'),
      max_boxes = GREATEST(COALESCE(p_max_boxes,40),1), cols = GREATEST(COALESCE(p_cols,3),1), memo = COALESCE(p_memo,''),
      per_layer = GREATEST(COALESCE(p_per_layer,6),1), mix_layers = v_ml
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';
