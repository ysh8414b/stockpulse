-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — 출고장용 제품명 추가 (2026-10-20)
-- setup_orders.sql 을 이미 실행한 경우 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
-- ═══════════════════════════════════════════

-- ship_name: 🚚 출고장 탭에 표시할 이름 (빈 값 = 제품명 그대로 사용)
ALTER TABLE ol_products ADD COLUMN IF NOT EXISTS ship_name TEXT DEFAULT '';

-- ol_upsert_product 시그니처는 그대로 두고, 저장 후 이 함수로 출고장용 이름만 따로 저장
-- (ol_list_masters 는 row_to_json 이라 새 컬럼이 자동으로 포함됨)
CREATE OR REPLACE FUNCTION ol_set_product_ship_name(p_admin_hash TEXT, p_id BIGINT, p_ship_name TEXT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  UPDATE ol_products SET ship_name = COALESCE(TRIM(p_ship_name),''), updated_at = now() WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
