-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 ↔ APS 품목 연결 (2026-10-28)
-- 발주서 상품코드(쿠팡) → APS 품목(aps_items) 연결표
-- setup_orders.sql + setup_aps.sql 을 이미 실행한 경우 이 파일만 Supabase SQL Editor에서 1회 실행 (재실행 안전)
-- ═══════════════════════════════════════════

-- aps_item_id: 이 발주 제품을 만드는 APS 품목 (NULL = 연결 안 됨)
-- 여러 발주 제품(500g/1kg, 업체별 등)이 같은 APS 품목을 가리켜도 됨
ALTER TABLE ol_products ADD COLUMN IF NOT EXISTS aps_item_id BIGINT NULL;
-- (ol_list_masters 는 row_to_json 이라 새 컬럼이 자동으로 포함됨)

CREATE OR REPLACE FUNCTION ol_set_product_aps_item(p_admin_hash TEXT, p_id BIGINT, p_aps_item_id BIGINT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  UPDATE ol_products SET aps_item_id = p_aps_item_id, updated_at = now() WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 제품 폼의 "APS 품목" 선택 목록 (제품/반제품만, 이름·코드·규격만 반환)
CREATE OR REPLACE FUNCTION ol_list_aps_items(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'code', code, 'name', name, 'type', type, 'spec', spec
    ) ORDER BY type, code), '[]'::json)
    FROM aps_items WHERE type IN ('product','semi')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 최근 업로드 시각 (2026-10-28) ──
-- 입고예정일 목록에 날짜별 마지막 업로드 시각(last_upload) 추가 → 발주서 탭에 "최근 업로드" 표시
-- (같은 발주번호를 다시 올리면 created_at 이 now() 로 바뀌므로 재업로드도 반영됨)
CREATE OR REPLACE FUNCTION ol_list_due_dates(p_admin_hash TEXT, p_extra BOOLEAN DEFAULT FALSE)
RETURNS JSON AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  PERFORM ol_cleanup_old_orders();
  RETURN (
    SELECT COALESCE(json_agg(json_build_object('due_date', d, 'order_count', c, 'last_upload', lu) ORDER BY d DESC), '[]'::json)
    FROM (SELECT due_date d, COUNT(*) c, MAX(created_at) lu FROM ol_orders WHERE is_extra = COALESCE(p_extra, FALSE) GROUP BY due_date) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
