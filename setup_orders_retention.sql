-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — 발주서 1달 보관 (2026-10-14)
-- setup_orders.sql 을 이미 실행한 경우 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
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

-- 입고예정일 목록 (날짜 선택용)
CREATE OR REPLACE FUNCTION ol_list_due_dates(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  -- 인증 없음 (2026-10-13: 비밀번호 없이 접근 허용)
  PERFORM ol_cleanup_old_orders();
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
  PERFORM ol_cleanup_old_orders();

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

-- 지금 바로 한 번 정리
SELECT ol_cleanup_old_orders();
