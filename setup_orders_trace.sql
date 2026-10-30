-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — ❄ 냉동재고 원육 표시 + 이력번호 (2026-10-30)
-- setup_orders_frozen.sql + setup_orders_aps_link.sql + setup_aps.sql 을 이미 실행한 경우
-- 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
-- ═══════════════════════════════════════════

-- 로트별 이력번호: {"<APS 원자재 id>": "이력번호", "_": "이력번호(원육 정보 없을 때)"}
ALTER TABLE ol_frozen_lots ADD COLUMN IF NOT EXISTS trace_nos JSONB NOT NULL DEFAULT '{}'::jsonb;
-- (ol_list_frozen 은 row_to_json 이라 새 컬럼이 자동으로 포함됨)

-- APS 품목별 사용 원육(원자재) — BOM 기준, 반제품을 거치는 원육까지 (최대 5단계)
-- 인증 없음: 원자재 이름·코드만 돌려줌 (ol_list_aps_items 와 같은 수준)
CREATE OR REPLACE FUNCTION ol_list_aps_materials(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  RETURN (
    WITH RECURSIVE t(root, cur, depth) AS (
      SELECT b.parent_id, b.child_id, 1 FROM aps_bom b
      UNION ALL
      SELECT t.root, b.child_id, t.depth + 1 FROM t JOIN aps_bom b ON b.parent_id = t.cur WHERE t.depth < 5
    )
    SELECT COALESCE(json_agg(json_build_object('item_id', root, 'materials', mats)), '[]'::json)
    FROM (
      SELECT d.root, json_agg(json_build_object('id', i.id, 'code', i.code, 'name', i.name) ORDER BY i.name) AS mats
      FROM (SELECT DISTINCT root, cur FROM t) d
      JOIN aps_items i ON i.id = d.cur AND i.type = 'material'
      GROUP BY d.root
    ) x
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 이력번호 저장 (통째로 교체, 빈 값은 빼고 저장)
CREATE OR REPLACE FUNCTION ol_set_frozen_trace(p_admin_hash TEXT, p_id BIGINT, p_traces JSONB)
RETURNS JSON AS $$
DECLARE v JSONB;
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  SELECT COALESCE(jsonb_object_agg(key, to_jsonb(TRIM(value))), '{}'::jsonb) INTO v
    FROM jsonb_each_text(COALESCE(p_traces, '{}'::jsonb))
   WHERE TRIM(COALESCE(value, '')) <> '';
  UPDATE ol_frozen_lots SET trace_nos = v, updated_at = now() WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'lot_not_found'; END IF;
  RETURN json_build_object('id', p_id, 'trace_nos', v);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 위치 이동: 나눠 옮길 때 이력번호도 같이 복사 (도착 로트에 이력번호가 없으면 옮긴 쪽 것을 씀)
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
    UPDATE ol_frozen_lots SET qty = qty + v_qty, updated_at = now(),
           trace_nos = CASE WHEN trace_nos = '{}'::jsonb THEN l.trace_nos ELSE trace_nos END
     WHERE id = v_dest;
    IF v_qty >= l.qty THEN DELETE FROM ol_frozen_lots WHERE id = p_id;
    ELSE UPDATE ol_frozen_lots SET qty = qty - v_qty, updated_at = now() WHERE id = p_id; END IF;
  ELSIF v_qty >= l.qty THEN
    UPDATE ol_frozen_lots SET location = v_loc, updated_at = now() WHERE id = p_id;
    v_dest := p_id;
  ELSE
    UPDATE ol_frozen_lots SET qty = qty - v_qty, updated_at = now() WHERE id = p_id;
    INSERT INTO ol_frozen_lots (product_code, product_name, qty, unit, expiry, location, in_date, memo, trace_nos)
    VALUES (l.product_code, l.product_name, v_qty, l.unit, l.expiry, v_loc, l.in_date, l.memo, l.trace_nos)
    RETURNING id INTO v_dest;
  END IF;

  INSERT INTO ol_frozen_txns (lot_id, kind, product_code, product_name, expiry, location, qty_change, qty_after, memo)
  VALUES (v_dest, 'move', l.product_code, l.product_name, l.expiry, v_loc, v_qty, v_qty,
          COALESCE(NULLIF(l.location,''),'(위치 없음)') || ' → ' || COALESCE(NULLIF(v_loc,''),'(위치 없음)'));
  RETURN json_build_object('moved', v_qty, 'dest_id', v_dest);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 🏷 이력번호 관리 (2026-10-30 추가)
-- 원육 + 소비기한 단위로 한 번만 입력 → 같은 원육을 쓰고 소비기한이 같은 냉동 로트에 자동 표시
-- ═══════════════════════════════════════════
CREATE TABLE IF NOT EXISTS ol_meat_traces (
  id               BIGSERIAL PRIMARY KEY,
  material_id      BIGINT NULL,              -- APS 원자재 id (NULL = 이름으로만 연결)
  material_name    TEXT NOT NULL,            -- 원육명
  expiry           DATE NULL,                -- 소비기한 (냉동 로트 소비기한과 맞춤)
  trace_no         TEXT NOT NULL DEFAULT '', -- 이력번호
  max_slaughter    DATE NULL,                -- 최대 도축일
  max_process      DATE NULL,                -- 최대 가공일
  max_receivable   DATE NULL,                -- 최대 입고가능일
  max_expiry       DATE NULL,                -- 최대 소비기한
  memo             TEXT DEFAULT '',
  created_at       TIMESTAMPTZ DEFAULT now(),
  updated_at       TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_meat_traces_mat ON ol_meat_traces (material_id, expiry);
ALTER TABLE ol_meat_traces ENABLE ROW LEVEL SECURITY;
-- 같은 원육 + 같은 소비기한 중복 금지 (이미 중복이 있으면 인덱스는 건너뛰고 안내만 — 화면에서 정리 후 다시 실행)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ol_meat_traces GROUP BY LOWER(TRIM(material_name)), expiry HAVING COUNT(*) > 1) THEN
    RAISE NOTICE '같은 원육·소비기한 이력번호가 중복된 기록이 있어 중복 금지 인덱스를 만들지 못했습니다. 화면에서 정리 후 이 파일을 다시 실행하세요.';
  ELSE
    CREATE UNIQUE INDEX IF NOT EXISTS uq_ol_meat_traces_mat_exp
      ON ol_meat_traces (LOWER(TRIM(material_name)), COALESCE(expiry, DATE '1900-01-01'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION ol_list_meat_traces(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  RETURN COALESCE((SELECT json_agg(row_to_json(t) ORDER BY t.material_name, t.expiry NULLS LAST, t.id) FROM ol_meat_traces t), '[]'::json);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- p_id NULL = 추가. p_row: {material_id, material_name, expiry, trace_no, max_slaughter, max_process, max_receivable, max_expiry, memo}
CREATE OR REPLACE FUNCTION ol_upsert_meat_trace(p_admin_hash TEXT, p_id BIGINT, p_row JSONB)
RETURNS JSON AS $$
DECLARE v_id BIGINT; v_name TEXT := TRIM(COALESCE(p_row->>'material_name',''));
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  IF v_name = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  -- 같은 원육 + 같은 소비기한에는 이력번호가 하나만 (2026-10-30)
  IF EXISTS (SELECT 1 FROM ol_meat_traces t
              WHERE t.id IS DISTINCT FROM p_id
                AND t.expiry IS NOT DISTINCT FROM NULLIF(p_row->>'expiry','')::DATE
                AND (LOWER(TRIM(t.material_name)) = LOWER(v_name)
                     OR (t.material_id IS NOT NULL AND t.material_id = NULLIF(p_row->>'material_id','')::BIGINT))) THEN
    RAISE EXCEPTION 'duplicate_trace';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO ol_meat_traces (material_id, material_name, expiry, trace_no, max_slaughter, max_process, max_receivable, max_expiry, memo)
    VALUES (NULLIF(p_row->>'material_id','')::BIGINT, v_name, NULLIF(p_row->>'expiry','')::DATE,
            TRIM(COALESCE(p_row->>'trace_no','')), NULLIF(p_row->>'max_slaughter','')::DATE, NULLIF(p_row->>'max_process','')::DATE,
            NULLIF(p_row->>'max_receivable','')::DATE, NULLIF(p_row->>'max_expiry','')::DATE, TRIM(COALESCE(p_row->>'memo','')))
    RETURNING id INTO v_id;
  ELSE
    UPDATE ol_meat_traces SET material_id = NULLIF(p_row->>'material_id','')::BIGINT, material_name = v_name,
           expiry = NULLIF(p_row->>'expiry','')::DATE, trace_no = TRIM(COALESCE(p_row->>'trace_no','')),
           max_slaughter = NULLIF(p_row->>'max_slaughter','')::DATE, max_process = NULLIF(p_row->>'max_process','')::DATE,
           max_receivable = NULLIF(p_row->>'max_receivable','')::DATE, max_expiry = NULLIF(p_row->>'max_expiry','')::DATE,
           memo = TRIM(COALESCE(p_row->>'memo','')), updated_at = now()
     WHERE id = p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'trace_not_found'; END IF;
  END IF;
  RETURN json_build_object('id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION ol_delete_meat_trace(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  DELETE FROM ol_meat_traces WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
