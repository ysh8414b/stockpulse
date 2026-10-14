-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — 제품 보관 구분(냉장/냉동) 추가 (2026-10-14)
-- setup_orders.sql 을 이미 실행한 경우 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
-- setup_orders_sauce.sql(양념)이 먼저 실행돼 있어야 합니다.
-- ═══════════════════════════════════════════

-- storage: 'chilled'(냉장, 기본 → 부착리스트 "신선" 센터) / 'frozen'(냉동 → "냉동" 센터)
-- 컬럼을 처음 만들 때만: 생산지점 이름에 '냉동'이 들어간 기존 제품은 냉동으로 초기화
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'ol_products' AND column_name = 'storage') THEN
    ALTER TABLE ol_products ADD COLUMN storage TEXT NOT NULL DEFAULT 'chilled';
    UPDATE ol_products SET storage = 'frozen' WHERE site LIKE '%냉동%';
  END IF;
END $$;

-- ── 제품 ──
-- 2026-10-14: p_storage(냉장/냉동) 추가 → 기존 11인자 버전 삭제
DROP FUNCTION IF EXISTS ol_upsert_product(TEXT, BIGINT, TEXT, TEXT, TEXT, INT, JSONB, TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION ol_upsert_product(
  p_admin_hash TEXT, p_id BIGINT, p_code TEXT, p_name TEXT, p_image_name TEXT,
  p_per_box INT, p_method_ids JSONB, p_site TEXT, p_box_spec TEXT, p_color TEXT,
  p_sauce TEXT DEFAULT '', p_storage TEXT DEFAULT 'chilled'
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT; v_storage TEXT := CASE WHEN p_storage = 'frozen' THEN 'frozen' ELSE 'chilled' END;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_code),'') = '' OR COALESCE(TRIM(p_name),'') = '' THEN
    RAISE EXCEPTION 'code_name_required';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO ol_products (code, name, image_name, per_box, method_ids, site, box_spec, color, sauce, storage)
    VALUES (TRIM(p_code), TRIM(p_name), COALESCE(p_image_name,''), GREATEST(COALESCE(p_per_box,1),1),
            COALESCE(p_method_ids,'[]'::jsonb), COALESCE(TRIM(p_site),''), COALESCE(p_box_spec,''), COALESCE(p_color,'#1d4ed8'),
            COALESCE(TRIM(p_sauce),''), v_storage)
    RETURNING id INTO v_id;
  ELSE
    UPDATE ol_products SET
      code = TRIM(p_code), name = TRIM(p_name), image_name = COALESCE(p_image_name,''),
      per_box = GREATEST(COALESCE(p_per_box,1),1), method_ids = COALESCE(p_method_ids,'[]'::jsonb),
      site = COALESCE(TRIM(p_site),''), box_spec = COALESCE(p_box_spec,''), color = COALESCE(p_color,'#1d4ed8'),
      sauce = COALESCE(TRIM(p_sauce),''), storage = v_storage,
      updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
