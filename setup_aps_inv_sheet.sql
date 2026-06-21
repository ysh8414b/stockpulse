-- ═══════════════════════════════════════════
-- APS 재고 시트 Supabase 동기화 (2026-06-21)
-- 사용자 요청: PC에서 업로드한 재고 시트를 모바일에서도 보고 싶음
-- → 기존 localStorage 단일 저장 → Supabase 싱글톤 테이블 + RPC 3종 추가
-- 의존성: setup_aps.sql 의 aps_assert_admin(p_admin_hash) 가 먼저 적용돼 있어야 함
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS aps_inventory_sheet(
  id          INT PRIMARY KEY DEFAULT 1 CHECK(id = 1),
  payload     JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE aps_inventory_sheet ENABLE ROW LEVEL SECURITY;
-- RLS 정책 없음 → REST 직접 접근 차단, RPC(SECURITY DEFINER)로만 접근 가능

-- ───── 읽기 ─────
CREATE OR REPLACE FUNCTION aps_get_inventory_sheet(p_admin_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_payload     JSONB;
  v_updated_at  TIMESTAMPTZ;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  SELECT payload, updated_at INTO v_payload, v_updated_at
    FROM aps_inventory_sheet WHERE id = 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  -- payload 본문 + 서버 timestamp 를 함께 반환
  RETURN jsonb_set(
    COALESCE(v_payload, '{}'::jsonb),
    '{updated_at}',
    to_jsonb(v_updated_at::text)
  );
END;
$$;

-- ───── 저장 (upsert) ─────
CREATE OR REPLACE FUNCTION aps_save_inventory_sheet(p_admin_hash TEXT, p_payload JSONB)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_updated_at TIMESTAMPTZ;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  INSERT INTO aps_inventory_sheet(id, payload, updated_at)
  VALUES (1, COALESCE(p_payload, '{}'::jsonb), now())
  ON CONFLICT (id) DO UPDATE
    SET payload = EXCLUDED.payload,
        updated_at = now()
  RETURNING updated_at INTO v_updated_at;
  RETURN v_updated_at;
END;
$$;

-- ───── 삭제 ─────
CREATE OR REPLACE FUNCTION aps_clear_inventory_sheet(p_admin_hash TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_inventory_sheet WHERE id = 1;
END;
$$;

GRANT EXECUTE ON FUNCTION aps_get_inventory_sheet(TEXT)              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION aps_save_inventory_sheet(TEXT, JSONB)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION aps_clear_inventory_sheet(TEXT)            TO anon, authenticated;
