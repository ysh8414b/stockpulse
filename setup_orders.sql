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
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ── 적재 방식 ──
-- kind: single(단독 파렛트) / mixed(혼적 — 자투리 박스를 다른 제품과 한 파렛트에)
-- max_boxes: 파렛트당 최대 박스 수, cols: 혼적 이미지에서 제품 1줄을 몇 칸으로 나눌지
CREATE TABLE IF NOT EXISTS ol_load_methods (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'single' CHECK (kind IN ('single','mixed')),
  max_boxes   INT  NOT NULL DEFAULT 40 CHECK (max_boxes > 0),
  cols        INT  NOT NULL DEFAULT 3 CHECK (cols > 0),
  memo        TEXT DEFAULT '',
  created_at  TIMESTAMPTZ DEFAULT now()
);

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

ALTER TABLE ol_box_specs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_load_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_products     ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_orders       ENABLE ROW LEVEL SECURITY;
ALTER TABLE ol_order_items  ENABLE ROW LEVEL SECURITY;

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
    'methods', (SELECT COALESCE(json_agg(row_to_json(m) ORDER BY m.id), '[]'::json) FROM ol_load_methods m)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 제품 ──
CREATE OR REPLACE FUNCTION ol_upsert_product(
  p_admin_hash TEXT, p_id BIGINT, p_code TEXT, p_name TEXT, p_image_name TEXT,
  p_per_box INT, p_method_ids JSONB, p_site TEXT, p_box_spec TEXT, p_color TEXT
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_code),'') = '' OR COALESCE(TRIM(p_name),'') = '' THEN
    RAISE EXCEPTION 'code_name_required';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO ol_products (code, name, image_name, per_box, method_ids, site, box_spec, color)
    VALUES (TRIM(p_code), TRIM(p_name), COALESCE(p_image_name,''), GREATEST(COALESCE(p_per_box,1),1),
            COALESCE(p_method_ids,'[]'::jsonb), COALESCE(TRIM(p_site),''), COALESCE(p_box_spec,''), COALESCE(p_color,'#1d4ed8'))
    RETURNING id INTO v_id;
  ELSE
    UPDATE ol_products SET
      code = TRIM(p_code), name = TRIM(p_name), image_name = COALESCE(p_image_name,''),
      per_box = GREATEST(COALESCE(p_per_box,1),1), method_ids = COALESCE(p_method_ids,'[]'::jsonb),
      site = COALESCE(TRIM(p_site),''), box_spec = COALESCE(p_box_spec,''), color = COALESCE(p_color,'#1d4ed8'),
      updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_product(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  DELETE FROM ol_products WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 박스 규격 ──
CREATE OR REPLACE FUNCTION ol_add_box_spec(p_admin_hash TEXT, p_spec TEXT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_spec),'') = '' THEN RAISE EXCEPTION 'spec_required'; END IF;
  INSERT INTO ol_box_specs (spec) VALUES (TRIM(p_spec)) ON CONFLICT (spec) DO NOTHING;
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
CREATE OR REPLACE FUNCTION ol_upsert_method(
  p_admin_hash TEXT, p_id BIGINT, p_name TEXT, p_kind TEXT, p_max_boxes INT, p_cols INT, p_memo TEXT
) RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_name),'') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO ol_load_methods (name, kind, max_boxes, cols, memo)
    VALUES (TRIM(p_name), COALESCE(p_kind,'single'), GREATEST(COALESCE(p_max_boxes,40),1), GREATEST(COALESCE(p_cols,3),1), COALESCE(p_memo,''))
    RETURNING id INTO v_id;
  ELSE
    UPDATE ol_load_methods SET name = TRIM(p_name), kind = COALESCE(p_kind,'single'),
      max_boxes = GREATEST(COALESCE(p_max_boxes,40),1), cols = GREATEST(COALESCE(p_cols,3),1), memo = COALESCE(p_memo,'')
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
-- 기간 내 발주서 + 품목 (입고예정일 기준)
CREATE OR REPLACE FUNCTION ol_list_orders(p_admin_hash TEXT, p_from DATE, p_to DATE)
RETURNS JSON AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', o.id, 'order_no', o.order_no, 'vendor', o.vendor, 'center', o.center,
      'center_addr', o.center_addr, 'due_date', o.due_date, 'order_type', o.order_type,
      'file_name', o.file_name, 'created_at', o.created_at,
      'items', (SELECT COALESCE(json_agg(json_build_object(
          'id', i.id, 'line_no', i.line_no, 'code', i.code, 'name', i.name, 'qty', i.qty,
          'mfg_date', i.mfg_date, 'expiry_date', i.expiry_date
        ) ORDER BY i.line_no, i.id), '[]'::json) FROM ol_order_items i WHERE i.order_id = o.id)
    ) ORDER BY o.due_date DESC, o.created_at), '[]'::json)
    FROM ol_orders o
    WHERE (p_from IS NULL OR o.due_date >= p_from) AND (p_to IS NULL OR o.due_date <= p_to)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 입고예정일 목록 (날짜 선택용)
CREATE OR REPLACE FUNCTION ol_list_due_dates(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  RETURN (
    SELECT COALESCE(json_agg(json_build_object('due_date', d, 'order_count', c) ORDER BY d DESC), '[]'::json)
    FROM (SELECT due_date d, COUNT(*) c FROM ol_orders GROUP BY due_date) t
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 발주서 저장: 같은 발주번호가 있으면 통째로 교체 (재업로드 idempotent)
-- p_items: [{line_no, code, name, qty, mfg_date, expiry_date}]
CREATE OR REPLACE FUNCTION ol_save_order(
  p_admin_hash TEXT, p_order_no TEXT, p_vendor TEXT, p_center TEXT, p_center_addr TEXT,
  p_due_date DATE, p_order_type TEXT, p_file_name TEXT, p_items JSONB
) RETURNS JSON AS $$
DECLARE v_id BIGINT; v_replaced BOOLEAN := FALSE;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF COALESCE(TRIM(p_order_no),'') = '' THEN RAISE EXCEPTION 'order_no_required'; END IF;
  IF p_due_date IS NULL THEN RAISE EXCEPTION 'due_date_required'; END IF;

  SELECT id INTO v_id FROM ol_orders WHERE order_no = TRIM(p_order_no);
  IF v_id IS NOT NULL THEN
    v_replaced := TRUE;
    DELETE FROM ol_order_items WHERE order_id = v_id;
    UPDATE ol_orders SET vendor = COALESCE(p_vendor,''), center = COALESCE(p_center,''),
      center_addr = COALESCE(p_center_addr,''), due_date = p_due_date, order_type = COALESCE(p_order_type,''),
      file_name = COALESCE(p_file_name,''), created_at = now()
    WHERE id = v_id;
  ELSE
    INSERT INTO ol_orders (order_no, vendor, center, center_addr, due_date, order_type, file_name)
    VALUES (TRIM(p_order_no), COALESCE(p_vendor,''), COALESCE(p_center,''), COALESCE(p_center_addr,''),
            p_due_date, COALESCE(p_order_type,''), COALESCE(p_file_name,''))
    RETURNING id INTO v_id;
  END IF;

  INSERT INTO ol_order_items (order_id, line_no, code, name, qty, mfg_date, expiry_date)
  SELECT v_id, COALESCE((e->>'line_no')::INT, 0), TRIM(e->>'code'), COALESCE(e->>'name',''),
         COALESCE((e->>'qty')::NUMERIC, 0),
         NULLIF(e->>'mfg_date','')::DATE, NULLIF(e->>'expiry_date','')::DATE
  FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) e
  WHERE COALESCE(TRIM(e->>'code'),'') <> '';

  RETURN json_build_object('id', v_id, 'replaced', v_replaced);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_order(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  DELETE FROM ol_orders WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
