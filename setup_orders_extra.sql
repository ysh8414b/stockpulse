-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — 추가 발주 탭 (2026-10-14)
-- setup_orders.sql 을 이미 실행한 경우 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
-- setup_orders_retention.sql(1달 보관)이 먼저 실행돼 있어야 합니다.
-- ═══════════════════════════════════════════

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
          'id', i.id, 'line_no', i.line_no, 'code', i.code, 'name', i.name, 'qty', i.qty,
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
    SELECT COALESCE(json_agg(json_build_object('due_date', d, 'order_count', c) ORDER BY d DESC), '[]'::json)
    FROM (SELECT due_date d, COUNT(*) c FROM ol_orders WHERE is_extra = COALESCE(p_extra, FALSE) GROUP BY due_date) t
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
