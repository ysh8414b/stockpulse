-- ═══════════════════════════════════════════════════════════════
-- 자동 리스트 생성기 (orders.html) — 1회 실행
-- 제품리스트 / 박스규격 / 적재방식 / 발주서(헤더+품목)
-- 인증 없이 사용 (p_admin_hash 파라미터는 호환용으로만 남김, 값 무시)
-- 다시 실행해도 안전 (CREATE IF NOT EXISTS + CREATE OR REPLACE)
-- 모든 테이블 RLS ENABLE + 정책 없음 → SECURITY DEFINER RPC로만 접근
-- ═══════════════════════════════════════════════════════════════

-- ── 박스 규격 (가로×세로×높이) ──
CREATE TABLE IF NOT EXISTS ol_box_specs (
  id          BIGSERIAL PRIMARY KEY,
  spec        TEXT NOT NULL UNIQUE,
  name        TEXT DEFAULT '',
  created_at  TIMESTAMPTZ DEFAULT now()
);
-- 규격명 (2026-10-13 추가 — 기존 테이블 마이그레이션)
ALTER TABLE ol_box_specs ADD COLUMN IF NOT EXISTS name TEXT DEFAULT '';

-- ── 적재 방식 ──
-- kind: single(단독 파렛트) / mixed(혼적 — 자투리 박스를 다른 제품과 한 파렛트에)
-- max_boxes: 파렛트당 최대 박스 수, cols: 혼적 이미지에서 제품 1줄을 몇 칸으로 나눌지
CREATE TABLE IF NOT EXISTS ol_load_methods (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'single' CHECK (kind IN ('single','mixed')),
  max_boxes   INT  NOT NULL DEFAULT 40 CHECK (max_boxes > 0),
  cols        INT  NOT NULL DEFAULT 3 CHECK (cols > 0),
  per_layer   INT  NOT NULL DEFAULT 6 CHECK (per_layer > 0),
  memo        TEXT DEFAULT '',
  created_at  TIMESTAMPTZ DEFAULT now()
);
-- 혼적 층당 박스 수(방) — 2026-10-13 추가. 한 층에 6자리, 자리마다 박스를 위로 쌓음
ALTER TABLE ol_load_methods ADD COLUMN IF NOT EXISTS per_layer INT NOT NULL DEFAULT 6;
-- 혼적 1자리 최대 단수 — 2026-10-15 추가. NULL = 파렛트 설정의 '혼적 최대 단수' 사용
ALTER TABLE ol_load_methods ADD COLUMN IF NOT EXISTS mix_layers INT CHECK (mix_layers IS NULL OR mix_layers > 0);

-- ── 제품 리스트 ──
CREATE TABLE IF NOT EXISTS ol_products (
  id          BIGSERIAL PRIMARY KEY,
  code        TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  image_name  TEXT DEFAULT '',
  per_box     INT  NOT NULL DEFAULT 1 CHECK (per_box > 0),
  method_ids  JSONB NOT NULL DEFAULT '[]'::jsonb,
  site        TEXT DEFAULT '',
  box_spec    TEXT DEFAULT '',
  color       TEXT DEFAULT '#1d4ed8',
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

-- 양념 (2026-10-14 추가) — 간장/고추장 등. 같은 양념끼리 우선 혼적, 빈 값 = 양념 없음
ALTER TABLE ol_products ADD COLUMN IF NOT EXISTS sauce TEXT DEFAULT '';

-- ── 발주서 헤더 ──
CREATE TABLE IF NOT EXISTS ol_orders (
  id          BIGSERIAL PRIMARY KEY,
  order_no    TEXT NOT NULL UNIQUE,
  vendor      TEXT DEFAULT '',
  center      TEXT DEFAULT '',
  center_addr TEXT DEFAULT '',
  due_date    DATE NOT NULL,
  order_type  TEXT DEFAULT '',
  file_name   TEXT DEFAULT '',
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_orders_due ON ol_orders (due_date DESC);

-- ── 발주서 품목 ──
CREATE TABLE IF NOT EXISTS ol_order_items (
  id          BIGSERIAL PRIMARY KEY,
  order_id    BIGINT NOT NULL REFERENCES ol_orders(id) ON DELETE CASCADE,
  line_no     INT  NOT NULL DEFAULT 0,
  code        TEXT NOT NULL,
  name        TEXT DEFAULT '',
  qty         NUMERIC NOT NULL DEFAULT 0,
  mfg_date    DATE,
  expiry_date DATE
);
CREATE INDEX IF NOT EXISTS idx_ol_items_order ON ol_order_items (order_id, line_no);
CREATE INDEX IF NOT EXISTS idx_ol_items_code ON ol_order_items (code);
-- 수량 편집 전 원래 수량 (2026-10-15, NULL = 편집 안 함)
ALTER TABLE ol_order_items ADD COLUMN IF NOT EXISTS orig_qty NUMERIC;

ALTER TABLE ol_box_specs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_load_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_products     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_orders       ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_order_items  ENABLE ROW LEVEL SECURITY;

-- ── 생산지점 (2026-10-13 추가 — 제품 등록 시 드롭다운) ──
-- 제품은 ol_products.site에 지점 이름(text)을 그대로 저장
-- ── 파렛트 설정 (2026-10-13 추가) ──
-- pallet_w / pallet_d: 파렛트 가로·세로(mm), max_height: 최대 적재 높이(mm), pallet_base: 파렛트 자체 높이(mm, 최대 높이에서 차감)
CREATE TABLE IF NOT EXISTS ol_settings (
  key         TEXT PRIMARY KEY,
  value       JSONB NOT NULL,
  updated_at  TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE ol_settings ENABLE ROW LEVEL SECURITY;
INSERT INTO ol_settings (key, value) VALUES
  ('pallet_w', '1100'), ('pallet_d', '1100'), ('max_height', '1700'), ('pallet_base', '0')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS ol_sites (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE ol_sites ENABLE ROW LEVEL SECURITY;
-- 이미 제품에 입력된 지점들을 목록으로 옮김
INSERT INTO ol_sites (name)
SELECT DISTINCT TRIM(site) FROM ol_products WHERE COALESCE(TRIM(site),'') <> ''
ON CONFLICT (name) DO NOTHING;

-- 기본 적재방식 시드 (비어 있을 때만)
INSERT INTO ol_load_methods (name, kind, max_boxes, cols, memo)
SELECT * FROM (VALUES
  ('단독 40박스', 'single', 40, 3, '한 파렛트에 한 제품만, 최대 40박스'),
  ('혼적 가능',   'mixed',  40, 3, '자투리 박스를 다른 혼적 제품과 한 파렛트에')
) v(name, kind, max_boxes, cols, memo)
WHERE NOT EXISTS (SELECT 1 FROM ol_load_methods);

-- ═══════════════════════════════════════════
-- 마스터 일괄 조회
-- ═══════════════════════════════════════════
CREATE OR REPLACE FUNCTION ol_list_masters(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  RETURN json_build_object(
    'products', (SELECT COALESCE(json_agg(row_to_json(p) ORDER BY p.site, p.code), '[]'::json) FROM ol_products p),
    'box_specs', (SELECT COALESCE(json_agg(row_to_json(b) ORDER BY b.spec), '[]'::json) FROM ol_box_specs b),
    'methods', (SELECT COALESCE(json_agg(row_to_json(m) ORDER BY m.id), '[]'::json) FROM ol_load_methods m),
    'sites', (SELECT COALESCE(json_agg(row_to_json(s) ORDER BY s.name), '[]'::json) FROM ol_sites s),
    'settings', (SELECT COALESCE(json_object_agg(key, value), '{}'::json) FROM ol_settings)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS ol_upsert_product(TEXT, BIGINT, TEXT, TEXT, TEXT, INT, JSONB, TEXT, TEXT, TEXT);
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

-- 출고장용 제품명 (2026-10-20, setup_orders_shipname.sql 과 동일) — 빈 값 = 제품명 그대로
ALTER TABLE ol_products ADD COLUMN IF NOT EXISTS ship_name TEXT DEFAULT '';
CREATE OR REPLACE FUNCTION ol_set_product_ship_name(p_admin_hash TEXT, p_id BIGINT, p_ship_name TEXT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  UPDATE ol_products SET ship_name = COALESCE(TRIM(p_ship_name),''), updated_at = now() WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_product(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  DELETE FROM ol_products WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 파렛트 설정 ──
CREATE OR REPLACE FUNCTION ol_set_setting(p_admin_hash TEXT, p_key TEXT, p_value JSONB)
RETURNS VOID AS $$
BEGIN
  IF COALESCE(TRIM(p_key),'') = '' THEN RAISE EXCEPTION 'key_required'; END IF;
  INSERT INTO ol_settings (key, value, updated_at) VALUES (TRIM(p_key), p_value, now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 생산지점 ──
CREATE OR REPLACE FUNCTION ol_add_site(p_admin_hash TEXT, p_name TEXT)
RETURNS VOID AS $$
BEGIN
  IF COALESCE(TRIM(p_name),'') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  INSERT INTO ol_sites (name) VALUES (TRIM(p_name)) ON CONFLICT (name) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 이름 변경 시 그 지점을 쓰던 제품들도 함께 변경
CREATE OR REPLACE FUNCTION ol_rename_site(p_admin_hash TEXT, p_id BIGINT, p_name TEXT)
RETURNS VOID AS $$
DECLARE v_old TEXT;
BEGIN
  IF COALESCE(TRIM(p_name),'') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  SELECT name INTO v_old FROM ol_sites WHERE id = p_id;
  IF v_old IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM ol_sites WHERE name = TRIM(p_name) AND id <> p_id) THEN
    RAISE EXCEPTION 'site_exists';
  END IF;
  UPDATE ol_sites SET name = TRIM(p_name) WHERE id = p_id;
  UPDATE ol_products SET site = TRIM(p_name), updated_at = now() WHERE TRIM(site) = v_old;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 삭제해도 제품에 입력된 지점 값은 유지 (목록에서만 빠짐)
CREATE OR REPLACE FUNCTION ol_delete_site(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  DELETE FROM ol_sites WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 박스 규격 ──
-- 같은 규격(가로×세로×높이)이 이미 있으면 규격명만 갱신 → 규격명 수정에도 사용
DROP FUNCTION IF EXISTS ol_add_box_spec(TEXT, TEXT);
CREATE OR REPLACE FUNCTION ol_add_box_spec(p_admin_hash TEXT, p_spec TEXT, p_name TEXT DEFAULT '')
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_spec),'') = '' THEN RAISE EXCEPTION 'spec_required'; END IF;
  INSERT INTO ol_box_specs (spec, name) VALUES (TRIM(p_spec), COALESCE(TRIM(p_name),''))
  ON CONFLICT (spec) DO UPDATE SET name = EXCLUDED.name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_box_spec(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  DELETE FROM ol_box_specs WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 적재 방식 ──
DROP FUNCTION IF EXISTS ol_upsert_method(TEXT, BIGINT, TEXT, TEXT, INT, INT, TEXT);
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

-- 삭제 시 제품들의 method_ids에서도 제거
CREATE OR REPLACE FUNCTION ol_delete_method(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  UPDATE ol_products SET method_ids = COALESCE((
    SELECT jsonb_agg(e) FROM jsonb_array_elements(method_ids) e WHERE e::text <> p_id::text
  ), '[]'::jsonb)
  WHERE method_ids @> to_jsonb(p_id);
  DELETE FROM ol_load_methods WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 발주서
-- ═══════════════════════════════════════════
-- 1달 보관 (2026-10-14): 입고예정일이 오늘(KST) 기준 1달 이전인 발주서 자동 삭제
-- 품목(ol_order_items)은 CASCADE, 남는 적재이미지 편집값(img:*)도 함께 정리
-- ol_list_due_dates(페이지 열 때) / ol_save_order(업로드 때)에서 자동 호출
CREATE OR REPLACE FUNCTION ol_cleanup_old_orders()
RETURNS INT AS $$
DECLARE v_cut DATE := ((now() AT TIME ZONE 'Asia/Seoul')::DATE - INTERVAL '1 month')::DATE; v_n INT;
BEGIN
  DELETE FROM ol_orders WHERE due_date < v_cut;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN
    DELETE FROM ol_settings s
    WHERE s.key LIKE 'img:%'
      AND NOT EXISTS (
        SELECT 1 FROM ol_orders o
        WHERE o.order_no = ANY (string_to_array(split_part(s.key, ':', 2), ', '))
      );
  END IF;
  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION ol_cleanup_old_orders() FROM PUBLIC, anon, authenticated;

-- is_extra: 추가 발주 탭에서 올린 발주서 (일반 발주서·발주리스트와 섞이지 않고 따로 적재)
ALTER TABLE ol_orders ADD COLUMN IF NOT EXISTS is_extra BOOLEAN NOT NULL DEFAULT FALSE;

-- 시그니처 변경(p_extra / p_is_extra 추가) → 기존 버전 삭제
DROP FUNCTION IF EXISTS ol_list_orders(TEXT, DATE, DATE);
DROP FUNCTION IF EXISTS ol_list_due_dates(TEXT);
DROP FUNCTION IF EXISTS ol_save_order(TEXT, TEXT, TEXT, TEXT, TEXT, DATE, TEXT, TEXT, JSONB);

-- 기간 내 발주서 + 품목 (입고예정일 기준) — p_extra: FALSE=일반 발주, TRUE=추가 발주
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

-- 입고예정일 목록 (날짜 선택용)
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

-- 발주서 저장: 같은 발주번호가 있으면 통째로 교체 (재업로드 idempotent)
-- p_is_extra: 추가 발주 탭에서 올리면 TRUE (같은 발주번호를 다른 탭에서 다시 올리면 그 탭으로 옮겨짐)
-- p_items: [{line_no, code, name, qty, mfg_date, expiry_date}]
CREATE OR REPLACE FUNCTION ol_save_order(
  p_admin_hash TEXT, p_order_no TEXT, p_vendor TEXT, p_center TEXT, p_center_addr TEXT,
  p_due_date DATE, p_order_type TEXT, p_file_name TEXT, p_items JSONB, p_is_extra BOOLEAN DEFAULT FALSE
) RETURNS JSON AS $$
DECLARE v_id BIGINT; v_replaced BOOLEAN := FALSE; v_was_extra BOOLEAN;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_order_no),'') = '' THEN RAISE EXCEPTION 'order_no_required'; END IF;
  IF p_due_date IS NULL THEN RAISE EXCEPTION 'due_date_required'; END IF;
  PERFORM ol_cleanup_old_orders();

  SELECT id, is_extra INTO v_id, v_was_extra FROM ol_orders WHERE order_no = TRIM(p_order_no);
  IF v_id IS NOT NULL THEN
    v_replaced := TRUE;
    DELETE FROM ol_order_items WHERE order_id = v_id;
    UPDATE ol_orders SET vendor = COALESCE(p_vendor,''), center = COALESCE(p_center,''),
      center_addr = COALESCE(p_center_addr,''), due_date = p_due_date, order_type = COALESCE(p_order_type,''),
      file_name = COALESCE(p_file_name,''), is_extra = COALESCE(p_is_extra, FALSE), created_at = now()
    WHERE id = v_id;
  ELSE
    INSERT INTO ol_orders (order_no, vendor, center, center_addr, due_date, order_type, file_name, is_extra)
    VALUES (TRIM(p_order_no), COALESCE(p_vendor,''), COALESCE(p_center,''), COALESCE(p_center_addr,''),
            p_due_date, COALESCE(p_order_type,''), COALESCE(p_file_name,''), COALESCE(p_is_extra, FALSE))
    RETURNING id INTO v_id;
  END IF;

  INSERT INTO ol_order_items (order_id, line_no, code, name, qty, mfg_date, expiry_date)
  SELECT v_id, COALESCE((e->>'line_no')::INT, 0), TRIM(e->>'code'), COALESCE(e->>'name',''),
         COALESCE((e->>'qty')::NUMERIC, 0),
         NULLIF(e->>'mfg_date','')::DATE, NULLIF(e->>'expiry_date','')::DATE
  FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) e
  WHERE COALESCE(TRIM(e->>'code'),'') <> '';

  RETURN json_build_object('id', v_id, 'replaced', v_replaced,
    'moved', v_replaced AND v_was_extra IS DISTINCT FROM COALESCE(p_is_extra, FALSE));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_order(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  DELETE FROM ol_orders WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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

-- 자동 리스트 생성기 — ❄ 냉동재고 탭 (2026-10-21)
-- (setup_orders_frozen.sql 과 동일)
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

-- 2주 지난 이력은 조회 때 자동 정리
CREATE OR REPLACE FUNCTION ol_list_frozen(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  DELETE FROM ol_frozen_txns WHERE created_at < now() - INTERVAL '14 days';
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


-- ═══ 💰 판매가 🔍 시장조사 (2026-10-22, setup_orders_market.sql 과 동일) ═══

-- 상품별 시장조사 검색어 + 제외한 경쟁 상품(쿠팡 productId 목록)
ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS market_query TEXT DEFAULT '';
ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS market_excluded JSONB NOT NULL DEFAULT '[]'::jsonb;

-- 검색 결과 기록 (검색 1번 = 1행, 180일 보관)
CREATE TABLE IF NOT EXISTS ol_market_snaps (
  id          BIGSERIAL PRIMARY KEY,
  price_id    BIGINT NOT NULL REFERENCES ol_prices(id) ON DELETE CASCADE,
  query       TEXT NOT NULL DEFAULT '',
  items       JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_market_snaps_price ON ol_market_snaps (price_id, created_at DESC);
ALTER TABLE ol_market_snaps ENABLE ROW LEVEL SECURITY;

-- 검색 결과 저장 + 검색어 기억
CREATE OR REPLACE FUNCTION ol_save_market_snap(p_admin_hash TEXT, p_price_id BIGINT, p_query TEXT, p_items JSONB)
RETURNS JSON AS $$
DECLARE v_id BIGINT; v_at TIMESTAMPTZ;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ol_prices WHERE id = p_price_id) THEN RAISE EXCEPTION 'price_not_found'; END IF;
  DELETE FROM ol_market_snaps WHERE created_at < now() - INTERVAL '180 days';
  INSERT INTO ol_market_snaps (price_id, query, items)
  VALUES (p_price_id, COALESCE(TRIM(p_query),''), COALESCE(p_items,'[]'::jsonb))
  RETURNING id, created_at INTO v_id, v_at;
  UPDATE ol_prices SET market_query = COALESCE(TRIM(p_query),'') WHERE id = p_price_id;
  RETURN json_build_object('id', v_id, 'created_at', v_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 한 상품의 검색 기록 (최근 30회, 최신 먼저)
CREATE OR REPLACE FUNCTION ol_list_market_snaps(p_admin_hash TEXT, p_price_id BIGINT)
RETURNS JSON AS $$
BEGIN
  RETURN COALESCE((SELECT json_agg(row_to_json(s) ORDER BY s.created_at DESC)
    FROM (SELECT id, query, items, created_at FROM ol_market_snaps
           WHERE price_id = p_price_id ORDER BY created_at DESC LIMIT 30) s), '[]'::json);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 검색 기록 1건 삭제
CREATE OR REPLACE FUNCTION ol_delete_market_snap(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  DELETE FROM ol_market_snaps WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 검색어만 저장 / 제외 목록 저장
CREATE OR REPLACE FUNCTION ol_set_market_prefs(p_admin_hash TEXT, p_price_id BIGINT, p_query TEXT, p_excluded JSONB)
RETURNS VOID AS $$
BEGIN
  UPDATE ol_prices
     SET market_query = CASE WHEN p_query IS NULL THEN market_query ELSE TRIM(p_query) END,
         market_excluded = CASE WHEN p_excluded IS NULL THEN market_excluded ELSE p_excluded END
   WHERE id = p_price_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 💰 판매가 — 쿠팡 품절 확인 (2026-10-26, setup_orders_stock.sql 과 동일) ═══
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

-- ═══ 🔗 APS 품목 연결 (2026-10-28, setup_orders_aps_link.sql 과 동일) ═══
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
