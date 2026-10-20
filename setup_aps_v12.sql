-- ═══════════════════════════════════════════
-- STOCKPULSE APS v12 — 매출 업로드 안전화 (수량 불어남·엉뚱한 날짜 삭제 방지)
-- Supabase SQL Editor에서 1회 실행 (setup_aps_sales.sql 실행 전제, 재실행 안전)
-- 변경 (aps_upsert_sales_batch 시그니처 동일 → 클라이언트 수정 불필요):
--   1) 업로드에 들어 있는 날짜만 정확히 지우고 교체 (예전: 최소~최대 범위 전체 삭제 →
--      파일에 없는 중간 날짜까지 지워짐)
--   2) 같은 (날짜, 상품코드)는 SQL에서 먼저 합산한 뒤 INSERT, 충돌 시 "더하기"가 아니라
--      "교체" → 어떤 경우에도 기존 값에 누적되지 않음
--   3) 트랜잭션 잠금으로 업로드를 한 번에 하나씩만 처리 → 두 기기에서 동시에 올려도
--      삭제/삽입이 섞이지 않음
-- ═══════════════════════════════════════════
CREATE OR REPLACE FUNCTION aps_upsert_sales_batch(
  p_admin_hash TEXT,
  p_rows       JSONB
)
RETURNS JSON AS $$
DECLARE
  v_min DATE;
  v_max DATE;
  v_inserted INT := 0;
  v_deleted INT := 0;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RETURN json_build_object('inserted', 0, 'deleted', 0, 'min_date', NULL, 'max_date', NULL);
  END IF;

  -- 매출 업로드끼리 직렬화 (트랜잭션 끝나면 자동 해제)
  PERFORM pg_advisory_xact_lock(hashtext('aps_sales_upload'));

  -- 이번 업로드 행 (코드 공백 제거, 빈 코드 제외)
  SELECT MIN((r->>'date')::DATE), MAX((r->>'date')::DATE) INTO v_min, v_max
  FROM jsonb_array_elements(p_rows) AS r
  WHERE r->>'date' IS NOT NULL AND btrim(COALESCE(r->>'code', '')) <> '';
  IF v_min IS NULL THEN
    RETURN json_build_object('inserted', 0, 'deleted', 0, 'min_date', NULL, 'max_date', NULL);
  END IF;

  -- 이번 업로드에 들어 있는 날짜만 삭제
  DELETE FROM aps_sales_daily
  WHERE date IN (
    SELECT DISTINCT (r->>'date')::DATE FROM jsonb_array_elements(p_rows) AS r
    WHERE r->>'date' IS NOT NULL AND btrim(COALESCE(r->>'code', '')) <> ''
  );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  -- (날짜, 코드)별 합산 후 INSERT. 충돌 시 교체(누적 아님)
  INSERT INTO aps_sales_daily(date, code, name, qty, updated_at)
  SELECT (r->>'date')::DATE, btrim(r->>'code'), MAX(COALESCE(r->>'name', '')),
         SUM(COALESCE((r->>'qty')::NUMERIC, 0)), now()
  FROM jsonb_array_elements(p_rows) AS r
  WHERE r->>'date' IS NOT NULL AND btrim(COALESCE(r->>'code', '')) <> ''
  GROUP BY (r->>'date')::DATE, btrim(r->>'code')
  ON CONFLICT (date, code) DO UPDATE
    SET qty = EXCLUDED.qty,
        name = CASE WHEN EXCLUDED.name <> '' THEN EXCLUDED.name ELSE aps_sales_daily.name END,
        updated_at = now();
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN json_build_object('inserted', v_inserted, 'deleted', v_deleted, 'min_date', v_min, 'max_date', v_max);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
