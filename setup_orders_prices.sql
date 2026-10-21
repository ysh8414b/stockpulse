-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — 💰 판매가 (제품리스트 탭 안) (2026-10-22)
-- setup_orders.sql 을 이미 실행한 경우 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
-- ═══════════════════════════════════════════

-- ── 판매 상품 (쿠팡 SKU 1개 = 1행). 시트 = 업체 + 냉장/냉동 ──
CREATE TABLE IF NOT EXISTS ol_prices (
  id                BIGSERIAL PRIMARY KEY,
  vendor            TEXT NOT NULL DEFAULT '',
  storage           TEXT NOT NULL DEFAULT 'chilled',   -- chilled | frozen
  sort_order        INT  NOT NULL DEFAULT 0,
  sku_id            TEXT DEFAULT '',
  name              TEXT NOT NULL,
  barcode           TEXT DEFAULT '',
  per_box           NUMERIC,
  coupang_url       TEXT DEFAULT '',
  supply_price      NUMERIC,
  sale_price        NUMERIC,     -- 쿠팡 판매가 (정가)
  discount_price    NUMERIC,     -- 쿠팡 현재 할인가 (없으면 NULL = 할인 없음)
  store_url         TEXT DEFAULT '',
  store_price       NUMERIC,     -- 스마트스토어 판매가
  memo              TEXT DEFAULT '',
  price_checked_at  TIMESTAMPTZ, -- 가격을 마지막으로 확인/입력한 시각
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_prices_sheet ON ol_prices (vendor, storage, sort_order);
CREATE INDEX IF NOT EXISTS idx_ol_prices_sku ON ol_prices (sku_id);
ALTER TABLE ol_prices ENABLE ROW LEVEL SECURITY;

-- ── 가격 변경 이력 (상품이 삭제돼도 남음, 180일 보관) ──
CREATE TABLE IF NOT EXISTS ol_price_history (
  id          BIGSERIAL PRIMARY KEY,
  price_id    BIGINT,
  name        TEXT DEFAULT '',
  field       TEXT NOT NULL,      -- sale | discount | store | supply
  old_value   NUMERIC,
  new_value   NUMERIC,
  source      TEXT DEFAULT 'manual',  -- manual | import | capture
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_price_history_created ON ol_price_history (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ol_price_history_pid ON ol_price_history (price_id, created_at DESC);
ALTER TABLE ol_price_history ENABLE ROW LEVEL SECURITY;

-- JSON 값 → 숫자 (빈 문자열·null = NULL)
CREATE OR REPLACE FUNCTION ol__num(p_v JSONB, p_key TEXT)
RETURNS NUMERIC AS $$
  SELECT NULLIF(REPLACE(TRIM(COALESCE(p_v->>p_key,'')),',',''),'')::numeric;
$$ LANGUAGE sql IMMUTABLE;

-- 가격 칸 반영 + 바뀐 것만 이력 기록 (내부 전용). p_vals에 들어 있는 키만 바꿈
CREATE OR REPLACE FUNCTION ol__apply_prices(p_id BIGINT, p_vals JSONB, p_source TEXT)
RETURNS INT AS $$
DECLARE r ol_prices%ROWTYPE; v NUMERIC; n INT := 0;
BEGIN
  SELECT * INTO r FROM ol_prices WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'price_not_found'; END IF;
  IF p_vals ? 'sale_price' THEN
    v := ol__num(p_vals,'sale_price');
    IF v IS DISTINCT FROM r.sale_price THEN
      INSERT INTO ol_price_history (price_id,name,field,old_value,new_value,source) VALUES (p_id,r.name,'sale',r.sale_price,v,p_source);
      UPDATE ol_prices SET sale_price = v WHERE id = p_id; n := n + 1;
    END IF;
  END IF;
  IF p_vals ? 'discount_price' THEN
    v := ol__num(p_vals,'discount_price');
    IF v IS DISTINCT FROM r.discount_price THEN
      INSERT INTO ol_price_history (price_id,name,field,old_value,new_value,source) VALUES (p_id,r.name,'discount',r.discount_price,v,p_source);
      UPDATE ol_prices SET discount_price = v WHERE id = p_id; n := n + 1;
    END IF;
  END IF;
  IF p_vals ? 'store_price' THEN
    v := ol__num(p_vals,'store_price');
    IF v IS DISTINCT FROM r.store_price THEN
      INSERT INTO ol_price_history (price_id,name,field,old_value,new_value,source) VALUES (p_id,r.name,'store',r.store_price,v,p_source);
      UPDATE ol_prices SET store_price = v WHERE id = p_id; n := n + 1;
    END IF;
  END IF;
  IF p_vals ? 'supply_price' THEN
    v := ol__num(p_vals,'supply_price');
    IF v IS DISTINCT FROM r.supply_price THEN
      INSERT INTO ol_price_history (price_id,name,field,old_value,new_value,source) VALUES (p_id,r.name,'supply',r.supply_price,v,p_source);
      UPDATE ol_prices SET supply_price = v WHERE id = p_id; n := n + 1;
    END IF;
  END IF;
  UPDATE ol_prices SET updated_at = now(),
         price_checked_at = CASE WHEN p_source IN ('manual','capture') OR n > 0 THEN now() ELSE price_checked_at END
   WHERE id = p_id;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 상품 정보(글자 칸) 저장. 가격 칸은 ol__apply_prices
CREATE OR REPLACE FUNCTION ol__apply_info(p_id BIGINT, p_row JSONB)
RETURNS VOID AS $$
BEGIN
  UPDATE ol_prices SET
    vendor      = CASE WHEN p_row ? 'vendor'      THEN COALESCE(TRIM(p_row->>'vendor'),'') ELSE vendor END,
    storage     = CASE WHEN p_row ? 'storage'     THEN CASE WHEN p_row->>'storage' = 'frozen' THEN 'frozen' ELSE 'chilled' END ELSE storage END,
    sort_order  = CASE WHEN p_row ? 'sort_order'  THEN COALESCE(ol__num(p_row,'sort_order')::int, sort_order) ELSE sort_order END,
    sku_id      = CASE WHEN p_row ? 'sku_id'      THEN COALESCE(TRIM(p_row->>'sku_id'),'') ELSE sku_id END,
    name        = CASE WHEN p_row ? 'name' AND COALESCE(TRIM(p_row->>'name'),'') <> '' THEN TRIM(p_row->>'name') ELSE name END,
    barcode     = CASE WHEN p_row ? 'barcode'     THEN COALESCE(TRIM(p_row->>'barcode'),'') ELSE barcode END,
    per_box     = CASE WHEN p_row ? 'per_box'     THEN ol__num(p_row,'per_box') ELSE per_box END,
    coupang_url = CASE WHEN p_row ? 'coupang_url' THEN COALESCE(TRIM(p_row->>'coupang_url'),'') ELSE coupang_url END,
    store_url   = CASE WHEN p_row ? 'store_url'   THEN COALESCE(TRIM(p_row->>'store_url'),'') ELSE store_url END,
    memo        = CASE WHEN p_row ? 'memo'        THEN COALESCE(TRIM(p_row->>'memo'),'') ELSE memo END,
    updated_at  = now()
  WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION ol__apply_prices(BIGINT, JSONB, TEXT) FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION ol__apply_info(BIGINT, JSONB) FROM anon, authenticated, PUBLIC;

-- 목록 + 최근 이력 (180일 지난 이력은 조회 때 정리)
CREATE OR REPLACE FUNCTION ol_list_prices(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  DELETE FROM ol_price_history WHERE created_at < now() - INTERVAL '180 days';
  RETURN json_build_object(
    'items', COALESCE((SELECT json_agg(row_to_json(p) ORDER BY p.vendor, p.storage, p.sort_order, p.id) FROM ol_prices p), '[]'::json),
    'history', COALESCE((SELECT json_agg(row_to_json(h) ORDER BY h.created_at DESC)
                         FROM (SELECT * FROM ol_price_history ORDER BY created_at DESC LIMIT 500) h), '[]'::json)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 상품 추가/수정 (p_id NULL = 추가). p_row: 상품 정보 + 가격 칸
CREATE OR REPLACE FUNCTION ol_upsert_price(p_admin_hash TEXT, p_id BIGINT, p_row JSONB)
RETURNS JSON AS $$
DECLARE v_id BIGINT := p_id;
BEGIN
  IF COALESCE(TRIM(p_row->>'name'),'') = '' AND p_id IS NULL THEN RAISE EXCEPTION 'name_required'; END IF;
  IF v_id IS NULL THEN
    INSERT INTO ol_prices (name, vendor, storage, sort_order)
    VALUES (TRIM(p_row->>'name'), COALESCE(TRIM(p_row->>'vendor'),''),
            CASE WHEN p_row->>'storage' = 'frozen' THEN 'frozen' ELSE 'chilled' END,
            COALESCE((SELECT MAX(sort_order) + 1 FROM ol_prices
                       WHERE vendor = COALESCE(TRIM(p_row->>'vendor'),'')
                         AND storage = CASE WHEN p_row->>'storage' = 'frozen' THEN 'frozen' ELSE 'chilled' END), 1))
    RETURNING id INTO v_id;
  ELSIF NOT EXISTS (SELECT 1 FROM ol_prices WHERE id = v_id) THEN
    RAISE EXCEPTION 'price_not_found';
  END IF;
  PERFORM ol__apply_info(v_id, p_row - 'sort_order');
  PERFORM ol__apply_prices(v_id, p_row, 'manual');
  RETURN json_build_object('id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 가격만 바로 수정 (표에서 클릭 수정 / 쿠팡·스토어 페이지에서 가져오기)
CREATE OR REPLACE FUNCTION ol_set_price_values(p_admin_hash TEXT, p_id BIGINT, p_values JSONB, p_source TEXT)
RETURNS JSON AS $$
DECLARE n INT;
BEGIN
  n := ol__apply_prices(p_id, p_values, CASE WHEN p_source IN ('manual','capture','import') THEN p_source ELSE 'manual' END);
  RETURN json_build_object('id', p_id, 'changed', n);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 엑셀 가져오기: (업체·보관·상품명)이 같으면 수정 → 없으면 SKU ID로 찾음(그 SKU가 엑셀·DB에서 하나뿐일 때만)
--                 → 그래도 없으면 추가. 엑셀에서 SKU가 겹치는 행은 클라이언트가 sku_dup=true로 보냄
CREATE OR REPLACE FUNCTION ol_import_prices(p_admin_hash TEXT, p_rows JSONB)
RETURNS JSON AS $$
DECLARE
  r JSONB; v_id BIGINT; v_sku TEXT; v_vendor TEXT; v_storage TEXT; v_name TEXT;
  n_ins INT := 0; n_upd INT := 0; n_chg INT := 0;
BEGIN
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows,'[]'::jsonb)) LOOP
    v_sku := COALESCE(TRIM(r->>'sku_id'),'');
    v_vendor := COALESCE(TRIM(r->>'vendor'),'');
    v_storage := CASE WHEN r->>'storage' = 'frozen' THEN 'frozen' ELSE 'chilled' END;
    v_name := COALESCE(TRIM(r->>'name'),'');
    IF v_name = '' THEN CONTINUE; END IF;
    v_id := NULL;
    SELECT id INTO v_id FROM ol_prices WHERE vendor = v_vendor AND storage = v_storage AND name = v_name ORDER BY id LIMIT 1;
    IF v_id IS NULL AND v_sku <> '' AND COALESCE(r->>'sku_dup','') <> 'true'
       AND (SELECT COUNT(*) FROM ol_prices WHERE sku_id = v_sku) = 1 THEN
      SELECT id INTO v_id FROM ol_prices WHERE sku_id = v_sku;
    END IF;
    IF v_id IS NULL THEN
      INSERT INTO ol_prices (name, vendor, storage) VALUES (v_name, v_vendor, v_storage) RETURNING id INTO v_id;
      PERFORM ol__apply_info(v_id, r);
      PERFORM ol__apply_prices(v_id, r, 'import');
      DELETE FROM ol_price_history WHERE price_id = v_id;  -- 처음 등록은 '변경'이 아님
      n_ins := n_ins + 1;
    ELSE
      PERFORM ol__apply_info(v_id, r);
      n_chg := n_chg + ol__apply_prices(v_id, r, 'import');
      n_upd := n_upd + 1;
    END IF;
  END LOOP;
  RETURN json_build_object('inserted', n_ins, 'updated', n_upd, 'price_changes', n_chg);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_price(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  DELETE FROM ol_prices WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
