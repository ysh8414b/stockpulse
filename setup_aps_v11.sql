-- ═══════════════════════════════════════════
-- STOCKPULSE APS v11 — 매출 날짜별 조회 + 요일 평균 기준 보정
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps_sales.sql + setup_aps_v10.sql 실행 완료
-- 목적:
--   1) 💰 매출 탭에서 업로드된 날짜 목록 / 날짜별 상품 / 상품별 주×요일 표 조회
--   2) 요일 평균 분모 = "매출이 업로드된 날짜" 중 그 요일 수
--      (예: 지난주 월 40 + 이번주 월 20 → 월요일 평균 30.
--       휴무·미업로드로 그날 매출 파일 자체가 없으면 0으로 치지 않고 평균에서 제외)
-- 안전: OR REPLACE, 재실행 안전. 테이블 변경 없음.
-- ═══════════════════════════════════════════

-- ═══ 1. 요일별 평균 재정의 ═══
-- 윈도우: 매출 마지막 날짜부터 거꾸로 p_weeks주
-- 분모: 윈도우 안에서 매출 데이터가 있는 날짜(어느 상품이든 1건 이상) 중 그 요일 수
--       → 그날 업로드는 됐는데 이 상품이 안 팔렸으면 0으로 평균에 포함
CREATE OR REPLACE FUNCTION aps_get_sales_dow(p_admin_hash TEXT, p_weeks INT DEFAULT 8)
RETURNS JSON AS $$
DECLARE
  v_end DATE;
  v_start DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT MAX(date) INTO v_end FROM aps_sales_daily;
  IF v_end IS NULL THEN
    RETURN json_build_object('start', NULL, 'end', NULL, 'rows', '[]'::json);
  END IF;
  v_start := v_end - (GREATEST(COALESCE(p_weeks, 8), 1) * 7 - 1);

  RETURN json_build_object(
    'start', v_start,
    'end', v_end,
    'rows', (
      WITH days AS (
        SELECT DISTINCT date, EXTRACT(ISODOW FROM date)::INT AS dow
        FROM aps_sales_daily
        WHERE date BETWEEN v_start AND v_end
      ),
      dow_cnt AS (
        SELECT dow, COUNT(*)::INT AS n FROM days GROUP BY dow
      ),
      sums AS (
        SELECT s.code, MAX(s.name) AS name, EXTRACT(ISODOW FROM s.date)::INT AS dow, SUM(s.qty) AS qty
        FROM aps_sales_daily s
        WHERE s.date BETWEEN v_start AND v_end
        GROUP BY s.code, EXTRACT(ISODOW FROM s.date)
      )
      SELECT COALESCE(json_agg(json_build_object(
        'code', sums.code, 'name', sums.name, 'dow', sums.dow,
        'total', sums.qty, 'days', dow_cnt.n,
        'avg', ROUND(sums.qty / NULLIF(dow_cnt.n, 0), 3)
      )), '[]'::json)
      FROM sums JOIN dow_cnt ON dow_cnt.dow = sums.dow
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 2. 업로드된 날짜 목록 (최근 p_days일) ═══
CREATE OR REPLACE FUNCTION aps_get_sales_dates(p_admin_hash TEXT, p_days INT DEFAULT 365)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'date', d.date, 'qty', d.qty, 'codes', d.codes
    ) ORDER BY d.date DESC), '[]'::json)
    FROM (
      SELECT date, SUM(qty) AS qty, COUNT(*)::INT AS codes
      FROM aps_sales_daily
      WHERE p_days IS NULL OR date >= (SELECT MAX(date) FROM aps_sales_daily) - (p_days - 1)
      GROUP BY date
    ) d
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 3. 특정 날짜의 상품별 매출 ═══
CREATE OR REPLACE FUNCTION aps_get_sales_by_date(p_admin_hash TEXT, p_date DATE)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'code', code, 'name', name, 'qty', qty
    ) ORDER BY qty DESC, code), '[]'::json)
    FROM aps_sales_daily
    WHERE date = p_date
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 4. 특정 상품의 날짜별 매출 (주×요일 표용) ═══
-- 윈도우는 aps_get_sales_dow 와 동일 (마지막 매출일부터 p_weeks주)
-- uploaded_dates: 윈도우 안에서 매출이 업로드된 날짜 (그날 이 상품이 없으면 판매 0으로 표시)
CREATE OR REPLACE FUNCTION aps_get_sales_by_code(p_admin_hash TEXT, p_code TEXT, p_weeks INT DEFAULT 8)
RETURNS JSON AS $$
DECLARE
  v_end DATE;
  v_start DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT MAX(date) INTO v_end FROM aps_sales_daily;
  IF v_end IS NULL THEN
    RETURN json_build_object('start', NULL, 'end', NULL, 'uploaded_dates', '[]'::json, 'rows', '[]'::json);
  END IF;
  v_start := v_end - (GREATEST(COALESCE(p_weeks, 8), 1) * 7 - 1);
  RETURN json_build_object(
    'start', v_start,
    'end', v_end,
    'uploaded_dates', (
      SELECT COALESCE(json_agg(x.date ORDER BY x.date), '[]'::json)
      FROM (SELECT DISTINCT date FROM aps_sales_daily WHERE date BETWEEN v_start AND v_end) x
    ),
    'rows', (
      SELECT COALESCE(json_agg(json_build_object('date', date, 'qty', qty) ORDER BY date), '[]'::json)
      FROM aps_sales_daily
      WHERE code = p_code AND date BETWEEN v_start AND v_end
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
