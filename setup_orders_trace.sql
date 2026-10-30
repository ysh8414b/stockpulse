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
