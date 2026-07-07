-- ═══════════════════════════════════════════
-- STOCKPULSE APS — 생산일보 v2
-- ─ 로스탭 "제품 검색" 뷰용 chain-level 통계 RPC 추가
-- ─ 전제: setup_aps_production.sql 실행 완료
-- Supabase SQL Editor에서 1회 실행
-- ═══════════════════════════════════════════

-- ───────────────────────────────────────────
-- 제품별 로스 집계용 chain-level 통계
-- 각 chain (= 하나의 chain_start 제품 + 여러 원육 로우) 별로
--   product_code / product_name / product_kg (excel 원본, 팩수 개념)
--   chain_raw_kg  = 그 chain의 모든 원육 kg 합계
-- 를 반환한다. 팩당 kg 파싱은 클라이언트에서 (extractPackWeightFromName)
-- ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION aps_get_product_chain_stats(
  p_admin_hash TEXT,
  p_days_back  INT DEFAULT 365
)
RETURNS JSON AS $$
DECLARE
  v_cutoff DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days_back IS NULL OR p_days_back < 1 THEN p_days_back := 365; END IF;
  v_cutoff := CURRENT_DATE - p_days_back;

  RETURN (
    WITH chain_starts AS (
      SELECT
        date, chain_id,
        product_code, product_name, product_origin,
        product_boxes, product_kg, product_unit, product_amount
      FROM aps_production_log
      WHERE is_chain_start
        AND NOT is_loss_summary
        AND product_code <> ''
        AND date >= v_cutoff
    ),
    chain_raws AS (
      SELECT
        date, chain_id,
        SUM(raw_meat_kg) AS chain_raw_kg,
        SUM(raw_meat_amount) AS chain_raw_amount
      FROM aps_production_log
      WHERE NOT is_loss_summary
        AND raw_meat_code <> ''
        AND raw_meat_kg > 0
        AND date >= v_cutoff
      GROUP BY date, chain_id
    ),
    joined AS (
      SELECT
        s.date, s.chain_id,
        s.product_code, s.product_name, s.product_origin,
        s.product_boxes, s.product_kg, s.product_unit, s.product_amount,
        COALESCE(r.chain_raw_kg, 0)     AS chain_raw_kg,
        COALESCE(r.chain_raw_amount, 0) AS chain_raw_amount
      FROM chain_starts s
      LEFT JOIN chain_raws r
        ON r.date = s.date AND r.chain_id = s.chain_id
    )
    SELECT COALESCE(json_agg(json_build_object(
      'date',              date,
      'chain_id',          chain_id,
      'product_code',      product_code,
      'product_name',      product_name,
      'product_origin',    product_origin,
      'product_boxes',     ROUND(product_boxes, 2),
      'product_kg',        ROUND(product_kg, 2),
      'product_unit',      product_unit,
      'product_amount',    ROUND(product_amount, 0),
      'chain_raw_kg',      ROUND(chain_raw_kg, 2),
      'chain_raw_amount',  ROUND(chain_raw_amount, 0)
    ) ORDER BY date DESC, chain_id), '[]'::json)
    FROM joined
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
