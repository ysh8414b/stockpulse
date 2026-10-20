-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 매출 날짜별 삭제 (2026-10-20)
-- Supabase SQL Editor에서 1회 실행 (setup_aps_sales.sql 실행 전제, 재실행 안전)
-- ═══════════════════════════════════════════
CREATE OR REPLACE FUNCTION aps_delete_sales_date(p_admin_hash TEXT, p_date DATE)
RETURNS JSON AS $$
DECLARE v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_date IS NULL THEN RAISE EXCEPTION 'date_required'; END IF;
  DELETE FROM aps_sales_daily WHERE date = p_date;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN json_build_object('deleted', v_deleted, 'date', p_date);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
