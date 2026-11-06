-- ═══════════════════════════════════════════
-- APS — 💵 원가 탭 설정 저장 — 1회 실행 (다시 실행해도 안전)
--  시급·포장비·간접비·품목별 판매가/포장비를 한 줄(JSON)로 저장한다.
--  👁 읽기 전용 접속에서는 읽기도 거부 (시급·원가는 비밀번호 없이 보이면 안 되므로)
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS aps_cost_config (
  id         INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  cfg        JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE aps_cost_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON aps_cost_config FROM anon, authenticated;

-- 읽기 전용 트리거 (setup_aps_readonly.sql을 실행했을 때만)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'aps_block_readonly') THEN
    DROP TRIGGER IF EXISTS aps_readonly_guard ON aps_cost_config;
    CREATE TRIGGER aps_readonly_guard BEFORE INSERT OR UPDATE OR DELETE ON aps_cost_config
      FOR EACH ROW EXECUTE FUNCTION aps_block_readonly();
  END IF;
END $$;

-- 이름이 aps_get_ 로 시작하지 않게 함 → 읽기 전용 화면은 이 함수를 보내지도 않음
CREATE OR REPLACE FUNCTION aps_cost_get_config(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF current_setting('aps.readonly', true) = 'on' THEN
    RAISE EXCEPTION 'read_only';
  END IF;
  RETURN COALESCE(
    (SELECT json_build_object('cfg', cfg, 'updated_at', updated_at) FROM aps_cost_config WHERE id = 1),
    json_build_object('cfg', '{}'::json, 'updated_at', NULL)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_cost_set_config(p_admin_hash TEXT, p_cfg JSONB)
RETURNS JSON AS $$
DECLARE v_at TIMESTAMPTZ;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF current_setting('aps.readonly', true) = 'on' THEN
    RAISE EXCEPTION 'read_only';
  END IF;
  INSERT INTO aps_cost_config (id, cfg, updated_at) VALUES (1, COALESCE(p_cfg, '{}'::jsonb), now())
  ON CONFLICT (id) DO UPDATE SET cfg = EXCLUDED.cfg, updated_at = now()
  RETURNING updated_at INTO v_at;
  RETURN json_build_object('updated_at', v_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION aps_cost_get_config(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION aps_cost_set_config(TEXT, JSONB) TO anon, authenticated;

-- 생산일보 chain별 투입 품목 목록 (원육·부자재를 화면에서 코드로 나누기 위해 합치지 않고 돌려줌)
CREATE OR REPLACE FUNCTION aps_cost_chain_inputs(p_admin_hash TEXT, p_days_back INT DEFAULT 90)
RETURNS JSON AS $$
DECLARE v_cutoff DATE;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_days_back IS NULL OR p_days_back < 1 THEN p_days_back := 90; END IF;
  v_cutoff := CURRENT_DATE - p_days_back;
  RETURN COALESCE((
    WITH s AS (
      SELECT date, chain_id, product_code, product_name, product_boxes, product_kg
      FROM aps_production_log
      WHERE is_chain_start AND NOT is_loss_summary AND product_code <> '' AND date >= v_cutoff
    ),
    i AS (
      SELECT date, chain_id,
        json_agg(json_build_object('code', raw_meat_code, 'name', raw_meat_name,
                                   'kg', raw_meat_kg, 'amount', raw_meat_amount) ORDER BY row_index) AS inputs
      FROM aps_production_log
      WHERE NOT is_loss_summary AND raw_meat_code <> '' AND date >= v_cutoff
      GROUP BY date, chain_id
    )
    SELECT json_agg(json_build_object(
      'date', s.date, 'chain_id', s.chain_id, 'product_code', s.product_code, 'product_name', s.product_name,
      'product_boxes', s.product_boxes, 'product_kg', s.product_kg, 'inputs', COALESCE(i.inputs, '[]'::json)
    ) ORDER BY s.date, s.chain_id)
    FROM s LEFT JOIN i ON i.date = s.date AND i.chain_id = s.chain_id
  ), '[]'::json);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION aps_cost_chain_inputs(TEXT, INT) TO anon, authenticated;
