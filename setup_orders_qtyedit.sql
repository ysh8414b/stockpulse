-- 자동 리스트 생성기 — 업로드한 발주서 수량 편집 (2026-10-15)
-- setup_orders.sql(+ setup_orders_extra.sql) 실행 이후 1회 실행 (재실행 안전)
-- orig_qty: 처음 편집하기 전 발주서 원래 수량 (NULL = 편집 안 함). 같은 발주번호를 다시 업로드하면 품목이 새로 들어가 초기화

ALTER TABLE ol_order_items ADD COLUMN IF NOT EXISTS orig_qty NUMERIC;

-- 품목 수량 일괄 수정 — p_items: [{"id":123,"qty":560}, ...]
-- 원래 수량으로 되돌리면 orig_qty도 지움
CREATE OR REPLACE FUNCTION ol_update_order_items(p_admin_hash TEXT, p_order_id BIGINT, p_items JSONB)
RETURNS INT AS $$
DECLARE v_n INT := 0; r JSONB; v_qty NUMERIC;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) LOOP
    v_qty := (r->>'qty')::NUMERIC;
    IF v_qty IS NULL OR v_qty < 0 THEN RAISE EXCEPTION 'invalid_qty'; END IF;
    UPDATE ol_order_items
      SET orig_qty = CASE WHEN COALESCE(orig_qty, qty) = v_qty THEN NULL ELSE COALESCE(orig_qty, qty) END,
          qty = v_qty
      WHERE id = (r->>'id')::BIGINT AND order_id = p_order_id AND qty IS DISTINCT FROM v_qty;
    IF FOUND THEN v_n := v_n + 1; END IF;
  END LOOP;
  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 목록 응답에 orig_qty 추가
CREATE OR REPLACE FUNCTION ol_list_orders(p_admin_hash TEXT, p_from DATE, p_to DATE, p_extra BOOLEAN DEFAULT FALSE)
RETURNS JSON AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', o.id, 'order_no', o.order_no, 'vendor', o.vendor, 'center', o.center,
      'center_addr', o.center_addr, 'due_date', o.due_date, 'order_type', o.order_type,
      'file_name', o.file_name, 'created_at', o.created_at, 'is_extra', o.is_extra,
      'items', (SELECT COALESCE(json_agg(json_build_object(
          'id', i.id, 'line_no', i.line_no, 'code', i.code, 'name', i.name, 'qty', i.qty, 'orig_qty', i.orig_qty,
          'mfg_date', i.mfg_date, 'expiry_date', i.expiry_date
        ) ORDER BY i.line_no, i.id), '[]'::json) FROM ol_order_items i WHERE i.order_id = o.id)
    ) ORDER BY o.due_date DESC, o.created_at), '[]'::json)
    FROM ol_orders o
    WHERE (p_from IS NULL OR o.due_date >= p_from) AND (p_to IS NULL OR o.due_date <= p_to)
      AND o.is_extra = COALESCE(p_extra, FALSE)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';
