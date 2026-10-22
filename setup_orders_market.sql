-- ═══════════════════════════════════════════
-- 자동 리스트 생성기 — 💰 판매가 🔍 시장조사 (2026-10-22)
-- setup_orders_prices.sql 을 실행한 뒤, 이 파일만 Supabase SQL Editor에서 1회 실행하면 됩니다. (재실행 안전)
-- ═══════════════════════════════════════════

-- 상품별 시장조사 검색어 + 제외한 경쟁 상품(쿠팡 productId 목록)
ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS market_query TEXT DEFAULT '';
ALTER TABLE ol_prices ADD COLUMN IF NOT EXISTS market_excluded JSONB NOT NULL DEFAULT '[]'::jsonb;

-- 검색 결과 기록 (검색 1번 = 1행, 180일 보관)
CREATE TABLE IF NOT EXISTS ol_market_snaps (
  id          BIGSERIAL PRIMARY KEY,
  price_id    BIGINT NOT NULL REFERENCES ol_prices(id) ON DELETE CASCADE,
  query       TEXT NOT NULL DEFAULT '',
  items       JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ol_market_snaps_price ON ol_market_snaps (price_id, created_at DESC);
ALTER TABLE ol_market_snaps ENABLE ROW LEVEL SECURITY;

-- 검색 결과 저장 + 검색어 기억
CREATE OR REPLACE FUNCTION ol_save_market_snap(p_admin_hash TEXT, p_price_id BIGINT, p_query TEXT, p_items JSONB)
RETURNS JSON AS $$
DECLARE v_id BIGINT; v_at TIMESTAMPTZ;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ol_prices WHERE id = p_price_id) THEN RAISE EXCEPTION 'price_not_found'; END IF;
  DELETE FROM ol_market_snaps WHERE created_at < now() - INTERVAL '180 days';
  INSERT INTO ol_market_snaps (price_id, query, items)
  VALUES (p_price_id, COALESCE(TRIM(p_query),''), COALESCE(p_items,'[]'::jsonb))
  RETURNING id, created_at INTO v_id, v_at;
  UPDATE ol_prices SET market_query = COALESCE(TRIM(p_query),'') WHERE id = p_price_id;
  RETURN json_build_object('id', v_id, 'created_at', v_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 한 상품의 검색 기록 (최근 30회, 최신 먼저)
CREATE OR REPLACE FUNCTION ol_list_market_snaps(p_admin_hash TEXT, p_price_id BIGINT)
RETURNS JSON AS $$
BEGIN
  RETURN COALESCE((SELECT json_agg(row_to_json(s) ORDER BY s.created_at DESC)
    FROM (SELECT id, query, items, created_at FROM ol_market_snaps
           WHERE price_id = p_price_id ORDER BY created_at DESC LIMIT 30) s), '[]'::json);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 검색 기록 1건 삭제
CREATE OR REPLACE FUNCTION ol_delete_market_snap(p_admin_hash TEXT, p_id BIGINT)
RETURNS VOID AS $$
BEGIN
  DELETE FROM ol_market_snaps WHERE id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 검색어만 저장 / 제외 목록 저장
CREATE OR REPLACE FUNCTION ol_set_market_prefs(p_admin_hash TEXT, p_price_id BIGINT, p_query TEXT, p_excluded JSONB)
RETURNS VOID AS $$
BEGIN
  UPDATE ol_prices
     SET market_query = CASE WHEN p_query IS NULL THEN market_query ELSE TRIM(p_query) END,
         market_excluded = CASE WHEN p_excluded IS NULL THEN market_excluded ELSE p_excluded END
   WHERE id = p_price_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
