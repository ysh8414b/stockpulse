-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — ❄ 냉동재고 탭 (2026-10-21)
-- setup_orders.sql 을 이미 실행한 경우 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
-- ═══════════════════════════════════════════

-- ── 재고 묶음(로트): 같은 제품이라도 소비기한·위치가 다르면 별도 행 ──
CREATE TABLE IF NOT EXISTS ol_frozen_lots (
  id            BIGSERIAL PRIMARY KEY,
  product_code  TEXT DEFAULT '',
  product_name  TEXT NOT NULL,
  qty           NUMERIC NOT NULL DEFAULT 0 CHECK (qty >= 0),
  unit          TEXT DEFAULT '박스',
  expiry        DATE,
  location      TEXT DEFAULT '',
  in_date       DATE DEFAULT CURRENT_DATE,
  memo          TEXT DEFAULT '',
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_frozen_lots_code ON ol_frozen_lots (product_code);
CREATE INDEX IF NOT EXISTS idx_ol_frozen_lots_expiry ON ol_frozen_lots (expiry);
ALTER TABLE ol_frozen_lots ENABLE ROW LEVEL SECURITY;

-- ── 입출고 이력 (로트가 삭제돼도 남음) ──
CREATE TABLE IF NOT EXISTS ol_frozen_txns (
  id            BIGSERIAL PRIMARY KEY,
  lot_id        BIGINT,
  kind          TEXT NOT NULL,           -- in | out | adjust | move | delete
  product_code  TEXT DEFAULT '',
  product_name  TEXT DEFAULT '',
  expiry        DATE,
  location      TEXT DEFAULT '',
  qty_change    NUMERIC DEFAULT 0,
  qty_after     NUMERIC DEFAULT 0,
  memo          TEXT DEFAULT '',
  created_at    TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_frozen_txns_created ON ol_frozen_txns (created_at DESC);
ALTER TABLE ol_frozen_txns ENABLE ROW LEVEL SECURITY;

-- 1년 지난 이력은 조회 때 자동 정리
CREATE OR REPLACE FUNCTION ol_list_frozen(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  DELETE FROM ol_frozen_txns WHERE created_at < now() - INTERVAL '365 days';
  RETURN json_build_object(
    'lots', COALESCE((SELECT json_agg(row_to_json(l) ORDER BY l.expiry NULLS LAST, l.id) FROM ol_frozen_lots l), '[]'::json),
    'txns', COALESCE((SELECT json_agg(row_to_json(t) ORDER BY t.created_at DESC)
                      FROM (SELECT * FROM ol_frozen_txns ORDER BY created_at DESC LIMIT 200) t), '[]'::json)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 등록/수정. p_id NULL = 입고 등록 (같은 제품·소비기한·위치 로트가 있으면 수량을 더함)
CREATE OR REPLACE FUNCTION ol_upsert_frozen_lot(
  p_admin_hash TEXT, p_id BIGINT, p_product_code TEXT, p_product_name TEXT, p_qty NUMERIC,
  p_unit TEXT, p_expiry DATE, p_location TEXT, p_in_date DATE, p_memo TEXT
) RETURNS JSON AS $$
DECLARE
  v_id BIGINT; v_old NUMERIC; v_new NUMERIC;
  v_code TEXT := COALESCE(TRIM(p_product_code),'');
  v_name TEXT := COALESCE(TRIM(p_product_name),'');
  v_loc  TEXT := COALESCE(TRIM(p_location),'');
  v_qty  NUMERIC := GREATEST(COALESCE(p_qty,0),0);
BEGIN
  IF v_name = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF p_id IS NULL THEN
    IF v_qty <= 0 THEN RAISE EXCEPTION 'qty_required'; END IF;
    SELECT id, qty INTO v_id, v_old FROM ol_frozen_lots
     WHERE product_code = v_code AND product_name = v_name AND location = v_loc
       AND expiry IS NOT DISTINCT FROM p_expiry
     LIMIT 1;
    IF v_id IS NOT NULL THEN
      v_new := v_old + v_qty;
      UPDATE ol_frozen_lots SET qty = v_new, updated_at = now(),
             memo = CASE WHEN COALESCE(TRIM(p_memo),'') <> '' THEN TRIM(p_memo) ELSE memo END
       WHERE id = v_id;
    ELSE
      v_new := v_qty;
      INSERT INTO ol_frozen_lots (product_code, product_name, qty, unit, expiry, location, in_date, memo)
      VALUES (v_code, v_name, v_qty, COALESCE(NULLIF(TRIM(p_unit),''),'박스'), p_expiry, v_loc,
              COALESCE(p_in_date, CURRENT_DATE), COALESCE(TRIM(p_memo),''))
      RETURNING id INTO v_id;
    END IF;
    INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo)
    VALUES (v_id, 'in', v_code, v_name, p_expiry, v_loc, v_qty, v_new, COALESCE(TRIM(p_memo),''));
    RETURN json_build_object('id', v_id, 'merged', v_old IS NOT NULL);
  END IF;

  SELECT qty INTO v_old FROM ol_frozen_lots WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'lot_not_found'; END IF;
  UPDATE ol_frozen_lots SET product_code = v_code, product_name = v_name, qty = v_qty,
         unit = COALESCE(NULLIF(TRIM(p_unit),''),'박스'), expiry = p_expiry, location = v_loc,
         in_date = COALESCE(p_in_date, in_date), memo = COALESCE(TRIM(p_memo),''), updated_at = now()
   WHERE id = p_id;
  IF v_old IS DISTINCT FROM v_qty THEN
    INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo)
    VALUES (p_id, 'adjust', v_code, v_name, p_expiry, v_loc, v_qty - v_old, v_qty, '수량 수정');
  END IF;
  RETURN json_build_object('id', p_id, 'merged', false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 입고(+) / 출고(-). 출고로 0이 되면 로트 삭제
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
  INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo)
  VALUES (p_id, CASE WHEN p_delta > 0 THEN 'in' ELSE 'out' END, l.product_code, l.product_name, l.expiry, l.location,
          p_delta, v_new, COALESCE(TRIM(p_memo),''));
  RETURN json_build_object('qty', v_new, 'removed', v_new = 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 위치 이동. p_qty가 로트 수량보다 적으면 나눠서 이동 (도착 위치에 같은 로트가 있으면 합침)
CREATE OR REPLACE FUNCTION ol_frozen_relocate(p_admin_hash TEXT, p_id BIGINT, p_qty NUMERIC, p_location TEXT)
RETURNS JSON AS $$
DECLARE l ol_frozen_lots%ROWTYPE; v_loc TEXT := COALESCE(TRIM(p_location),''); v_qty NUMERIC; v_dest BIGINT;
BEGIN
  SELECT * INTO l FROM ol_frozen_lots WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'lot_not_found'; END IF;
  IF v_loc = l.location THEN RETURN json_build_object('moved', 0); END IF;
  v_qty := LEAST(GREATEST(COALESCE(p_qty, l.qty),0), l.qty);
  IF v_qty <= 0 THEN RAISE EXCEPTION 'qty_required'; END IF;

  SELECT id INTO v_dest FROM ol_frozen_lots
   WHERE id <> p_id AND product_code = l.product_code AND product_name = l.product_name
     AND location = v_loc AND expiry IS NOT DISTINCT FROM l.expiry
   LIMIT 1;

  IF v_dest IS NOT NULL THEN
    UPDATE ol_frozen_lots SET qty = qty + v_qty, updated_at = now() WHERE id = v_dest;
    IF v_qty >= l.qty THEN DELETE FROM ol_frozen_lots WHERE id = p_id;
    ELSE UPDATE ol_frozen_lots SET qty = qty - v_qty, updated_at = now() WHERE id = p_id; END IF;
  ELSIF v_qty >= l.qty THEN
    UPDATE ol_frozen_lots SET location = v_loc, updated_at = now() WHERE id = p_id;
    v_dest := p_id;
  ELSE
    UPDATE ol_frozen_lots SET qty = qty - v_qty, updated_at = now() WHERE id = p_id;
    INSERT INTO ol_frozen_lots (product_code, product_name, qty, unit, expiry, location, in_date, memo)
    VALUES (l.product_code, l.product_name, v_qty, l.unit, l.expiry, v_loc, l.in_date, l.memo)
    RETURNING id INTO v_dest;
  END IF;

  INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo)
  VALUES (v_dest, 'move', l.product_code, l.product_name, l.expiry, v_loc, v_qty, v_qty,
          COALESCE(NULLIF(l.location,''),'(위치 없음)') || ' → ' || COALESCE(NULLIF(v_loc,''),'(위치 없음)'));
  RETURN json_build_object('moved', v_qty, 'dest_id', v_dest);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_frozen_lot(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
DECLARE l ol_frozen_lots%ROWTYPE;
BEGIN
  SELECT * INTO l FROM ol_frozen_lots WHERE id = p_id;
  IF NOT FOUND THEN RETURN; END IF;
  DELETE FROM ol_frozen_lots WHERE id = p_id;
  INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo)
  VALUES (p_id, 'delete', l.product_code, l.product_name, l.expiry, l.location, -l.qty, 0, '재고 삭제');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
