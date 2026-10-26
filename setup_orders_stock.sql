-- ═══ 💰 판매가 — 쿠팡 품절 확인 (2026-10-26) ═══
-- setup_orders_prices.sql 실행 후 1회 실행 (다시 실행해도 안전)
-- 확장 프로그램이 상품 페이지에서 읽은 품절 여부·남은 수량을 저장

ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS sold_out         BOOLEAN;       -- NULL = 아직 확인 안 함
ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS sold_out_at      TIMESTAMPTZ;   -- 품절을 처음 확인한 시각
ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS stock_left       INT;           -- "품절임박 N개" 일 때 N
ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS stock_checked_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION ol_set_price_stock(p_admin_hash TEXT, p_id BIGINT, p_sold_out BOOLEAN, p_stock_left INT)
RETURNS JSON AS $$
DECLARE was BOOLEAN;
BEGIN
  SELECT sold_out INTO was FROM ol_prices WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found'; END IF;
  UPDATE ol_prices SET
    sold_out = p_sold_out,
    sold_out_at = CASE WHEN p_sold_out IS TRUE AND COALESCE(was, FALSE) = FALSE THEN now()
                       WHEN p_sold_out IS TRUE THEN COALESCE(sold_out_at, now())
                       ELSE NULL END,
    stock_left = CASE WHEN p_sold_out IS TRUE THEN 0 ELSE p_stock_left END,
    stock_checked_at = now()
  WHERE id = p_id;
  RETURN json_build_object('id', p_id, 'sold_out', p_sold_out, 'was', was);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
