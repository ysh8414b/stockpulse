-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — ❄ 냉동재고 입출고 이력 ↩ 되돌리기 (2026-11-06)
-- setup_orders_frozen.sql (+ setup_orders_trace.sql) 을 실행한 뒤 Supabase SQL Editor에서 1회 실행. (재실행 안전)
-- ═══════════════════════════════════════════

-- 복구에 필요한 로트 정보(단위·입고일·메모) + 되돌림 표시
ALTER TABLE ol_frozen_txns ADD COLUMN IF NOT EXISTS unit       TEXT;
ALTER TABLE ol_frozen_txns ADD COLUMN IF NOT EXISTS in_date    DATE;
ALTER TABLE ol_frozen_txns ADD COLUMN IF NOT EXISTS lot_memo   TEXT;
ALTER TABLE ol_frozen_txns ADD COLUMN IF NOT EXISTS undone_at  TIMESTAMPTZ;  -- 이 기록을 되돌린 시각
ALTER TABLE ol_frozen_txns ADD COLUMN IF NOT EXISTS undo_of    BIGINT;       -- 되돌리기로 생긴 기록이면 원래 기록 id

-- 출고(-)로 0이 되면 로트가 삭제되므로 단위·입고일·메모도 함께 기록
CREATE OR REPLACE FUNCTION ol_frozen_change_qty(p_admin_hash TEXT, p_id BIGINT, p_delta NUMERIC, p_memo TEXT)
RETURNS JSON AS $$
DECLARE l ol_frozen_lots%ROWTYPE; v_new NUMERIC;
BEGIN
  SELECT * INTO l FROM ol_frozen_lots WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'lot_not_found'; END IF;
  IF COALESCE(p_delta,0) = 0 THEN RAISE EXCEPTION 'qty_required'; END IF;
  v_new := l.qty + p_delta;
  IF v_new < 0 THEN RAISE EXCEPTION 'not_enough_stock'; END IF;
  IF v_new = 0 THEN
    DELETE FROM ol_frozen_lots WHERE id = p_id;
  ELSE
    UPDATE ol_frozen_lots SET qty = v_new, updated_at = now() WHERE id = p_id;
  END IF;
  INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo, unit, in_date, lot_memo)
  VALUES (p_id, CASE WHEN p_delta > 0 THEN 'in' ELSE 'out' END, l.product_code, l.product_name, l.expiry, l.location,
          p_delta, v_new, COALESCE(TRIM(p_memo),''), l.unit, l.in_date, l.memo);
  RETURN json_build_object('qty', v_new, 'removed', v_new = 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_frozen_lot(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
DECLARE l ol_frozen_lots%ROWTYPE;
BEGIN
  SELECT * INTO l FROM ol_frozen_lots WHERE id = p_id;
  IF NOT FOUND THEN RETURN; END IF;
  DELETE FROM ol_frozen_lots WHERE id = p_id;
  INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo, unit, in_date, lot_memo)
  VALUES (p_id, 'delete', l.product_code, l.product_name, l.expiry, l.location, -l.qty, 0, '재고 삭제', l.unit, l.in_date, l.memo);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ↩ 기록 하나 되돌리기
--  삭제 → 같은 수량으로 다시 넣음 / 입고 → 뺌 / 출고 → 다시 넣음 / 수량 수정 → 차이만큼 반대로 / 이동 → 원래 위치로 옮김
--  로트가 없어졌으면 같은 제품·소비기한·위치 로트에 합치고, 그것도 없으면 새로 만듦
CREATE OR REPLACE FUNCTION ol_frozen_undo_txn(p_admin_hash TEXT, p_txn_id BIGINT)
RETURNS JSON AS $$
DECLARE
  t ol_frozen_txns%ROWTYPE;
  l ol_frozen_lots%ROWTYPE;
  v_delta NUMERIC; v_new NUMERIC; v_lot BIGINT; v_from TEXT; v_unit TEXT;
BEGIN
  SELECT * INTO t FROM ol_frozen_txns WHERE id = p_txn_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'txn_not_found'; END IF;
  IF t.undone_at IS NOT NULL THEN RAISE EXCEPTION 'already_undone'; END IF;
  IF t.undo_of IS NOT NULL THEN RAISE EXCEPTION 'cannot_undo_undo'; END IF;

  -- 지금 그 로트 찾기: 기록의 lot_id → 없으면 같은 제품·소비기한·위치
  SELECT * INTO l FROM ol_frozen_lots WHERE id = t.lot_id
     AND product_code = t.product_code AND product_name = t.product_name
     AND location = COALESCE(t.location,'') AND expiry IS NOT DISTINCT FROM t.expiry
   FOR UPDATE;
  IF NOT FOUND THEN
    SELECT * INTO l FROM ol_frozen_lots
     WHERE product_code = t.product_code AND product_name = t.product_name
       AND location = COALESCE(t.location,'') AND expiry IS NOT DISTINCT FROM t.expiry
     ORDER BY id LIMIT 1 FOR UPDATE;
  END IF;

  IF t.kind = 'move' THEN
    IF l.id IS NULL THEN RAISE EXCEPTION 'lot_gone'; END IF;
    IF l.qty < t.qty_change THEN RAISE EXCEPTION 'not_enough_stock'; END IF;
    v_from := split_part(COALESCE(t.memo,''), ' → ', 1);
    IF v_from = '(위치 없음)' THEN v_from := ''; END IF;
    PERFORM ol_frozen_relocate(p_admin_hash, l.id, t.qty_change, v_from);
    UPDATE ol_frozen_txns SET undo_of = t.id
     WHERE id = (SELECT max(id) FROM ol_frozen_txns WHERE kind = 'move' AND undo_of IS NULL AND id > t.id);
    UPDATE ol_frozen_txns SET undone_at = now() WHERE id = t.id;
    RETURN json_build_object('ok', true);
  END IF;

  IF t.kind NOT IN ('in','out','adjust','delete') THEN RAISE EXCEPTION 'cannot_undo'; END IF;
  v_delta := -COALESCE(t.qty_change,0);
  IF v_delta = 0 THEN RAISE EXCEPTION 'cannot_undo'; END IF;

  IF l.id IS NOT NULL THEN
    v_new := l.qty + v_delta;
    IF v_new < 0 THEN RAISE EXCEPTION 'not_enough_stock'; END IF;
    IF v_new = 0 THEN DELETE FROM ol_frozen_lots WHERE id = l.id;
    ELSE UPDATE ol_frozen_lots SET qty = v_new, updated_at = now() WHERE id = l.id; END IF;
    v_lot := l.id;
    v_unit := l.unit;
  ELSE
    IF v_delta < 0 THEN RAISE EXCEPTION 'not_enough_stock'; END IF;
    -- 예전 기록은 단위가 없음 → 같은 제품의 다른 로트 단위 → 박스
    v_unit := COALESCE(NULLIF(t.unit,''),
      (SELECT unit FROM ol_frozen_lots WHERE product_code = t.product_code AND product_name = t.product_name ORDER BY id LIMIT 1),
      '박스');
    INSERT INTO ol_frozen_lots (product_code, product_name, qty, unit, expiry, location, in_date, memo)
    VALUES (t.product_code, t.product_name, v_delta, v_unit, t.expiry, COALESCE(t.location,''),
            COALESCE(t.in_date, CURRENT_DATE), COALESCE(t.lot_memo,''))
    RETURNING id INTO v_lot;
    v_new := v_delta;
  END IF;

  INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo, unit, in_date, lot_memo, undo_of)
  VALUES (v_lot, CASE WHEN v_delta > 0 THEN 'in' ELSE 'out' END, t.product_code, t.product_name, t.expiry, COALESCE(t.location,''),
          v_delta, v_new,
          '↩ 되돌리기: ' || CASE t.kind WHEN 'delete' THEN '삭제' WHEN 'in' THEN '입고' WHEN 'out' THEN '출고' ELSE '수정' END
            || CASE WHEN COALESCE(t.memo,'') <> '' AND t.kind <> 'delete' THEN ' (' || t.memo || ')' ELSE '' END,
          v_unit, t.in_date, t.lot_memo, t.id);
  UPDATE ol_frozen_txns SET undone_at = now() WHERE id = t.id;
  RETURN json_build_object('ok', true, 'lot_id', v_lot, 'qty', v_new);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
