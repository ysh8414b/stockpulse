-- ═══════════════════════════════════════════
-- STOCKPULSE APS v2 — 라인 + 시간 단위 마이그레이션
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql 실행 완료
-- 주의: aps_plans는 DROP/CREATE 됩니다. 데이터 있으면 사전 백업 필요.
--       (사용자 확인: 데이터 없음 → 안전)
-- ═══════════════════════════════════════════

-- ═══ 1. 생산라인 마스터 ═══
CREATE TABLE IF NOT EXISTS aps_lines (
  id BIGSERIAL PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  memo TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE aps_lines ENABLE ROW LEVEL SECURITY;

-- ═══ 2. 전역 설정 (key-value) ═══
CREATE TABLE IF NOT EXISTS aps_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE aps_settings ENABLE ROW LEVEL SECURITY;

INSERT INTO aps_settings (key, value) VALUES
  ('work_start_hour', '8'),
  ('work_end_hour',   '17')
ON CONFLICT (key) DO NOTHING;

-- ═══ 3. aps_plans 재생성 (시간 + 라인 기반) ═══
DROP TABLE IF EXISTS aps_plans CASCADE;
CREATE TABLE aps_plans (
  id BIGSERIAL PRIMARY KEY,
  item_id BIGINT NOT NULL REFERENCES aps_items(id) ON DELETE RESTRICT,
  line_id BIGINT REFERENCES aps_lines(id) ON DELETE RESTRICT,
  qty NUMERIC NOT NULL CHECK (qty > 0),
  start_at TIMESTAMPTZ NOT NULL,
  end_at   TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned','in_progress','done','canceled')),
  memo TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  CHECK (end_at > start_at)
);
CREATE INDEX idx_aps_plans_times  ON aps_plans (start_at, end_at);
CREATE INDEX idx_aps_plans_line   ON aps_plans (line_id);
CREATE INDEX idx_aps_plans_status ON aps_plans (status);
ALTER TABLE aps_plans ENABLE ROW LEVEL SECURITY;

-- aps_stock_txns의 related_plan_id FK 복구 (DROP CASCADE로 잃어버린 것)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'aps_stock_txns'::regclass
       AND contype = 'f'
       AND pg_get_constraintdef(oid) LIKE '%aps_plans%'
  ) THEN
    ALTER TABLE aps_stock_txns
      ADD CONSTRAINT aps_stock_txns_related_plan_fk
      FOREIGN KEY (related_plan_id) REFERENCES aps_plans(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ═══ 4. 라인 RPC ═══
CREATE OR REPLACE FUNCTION aps_list_lines(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'code', code, 'name', name, 'memo', memo,
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY code), '[]'::json)
    FROM aps_lines
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_upsert_line(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_code TEXT,
  p_name TEXT,
  p_memo TEXT
) RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_id IS NULL THEN
    INSERT INTO aps_lines (code, name, memo)
    VALUES (p_code, p_name, COALESCE(p_memo,''))
    RETURNING id INTO new_id;
    RETURN new_id;
  ELSE
    UPDATE aps_lines
       SET code = p_code,
           name = p_name,
           memo = COALESCE(p_memo,''),
           updated_at = now()
     WHERE id = p_id;
    RETURN p_id;
  END IF;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'duplicate_code';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_delete_line(p_admin_hash TEXT, p_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF EXISTS (SELECT 1 FROM aps_plans WHERE line_id = p_id) THEN
    RAISE EXCEPTION 'has_plans';
  END IF;
  DELETE FROM aps_lines WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 5. 설정 RPC ═══
CREATE OR REPLACE FUNCTION aps_get_settings(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN COALESCE(
    (SELECT json_object_agg(key, value) FROM aps_settings),
    '{}'::json
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_set_setting(p_admin_hash TEXT, p_key TEXT, p_value TEXT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  INSERT INTO aps_settings (key, value, updated_at)
  VALUES (p_key, p_value, now())
  ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value,
        updated_at = now();
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 6. aps_list_plans / aps_upsert_plan 재정의 (시간 + 라인) ═══
DROP FUNCTION IF EXISTS aps_list_plans(TEXT, TEXT);
CREATE FUNCTION aps_list_plans(p_admin_hash TEXT, p_status TEXT DEFAULT NULL)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id',         p.id,
      'item_id',    p.item_id,
      'item_code',  i.code,
      'item_name',  i.name,
      'item_unit',  i.unit,
      'line_id',    p.line_id,
      'line_code',  l.code,
      'line_name',  l.name,
      'qty',        p.qty,
      'start_at',   p.start_at,
      'end_at',     p.end_at,
      'status',     p.status,
      'memo',       p.memo,
      'created_at', p.created_at,
      'updated_at', p.updated_at
    ) ORDER BY p.start_at DESC, p.id DESC), '[]'::json)
    FROM aps_plans p
    JOIN aps_items i ON i.id = p.item_id
    LEFT JOIN aps_lines l ON l.id = p.line_id
    WHERE p_status IS NULL OR p.status = p_status
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS aps_upsert_plan(TEXT, BIGINT, BIGINT, NUMERIC, DATE, DATE, TEXT, TEXT);
CREATE FUNCTION aps_upsert_plan(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_item_id BIGINT,
  p_line_id BIGINT,
  p_qty NUMERIC,
  p_start_at TIMESTAMPTZ,
  p_end_at TIMESTAMPTZ,
  p_status TEXT,
  p_memo TEXT
) RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_end_at <= p_start_at THEN
    RAISE EXCEPTION 'invalid_times';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO aps_plans (item_id, line_id, qty, start_at, end_at, status, memo)
    VALUES (p_item_id, p_line_id, p_qty, p_start_at, p_end_at,
            COALESCE(NULLIF(p_status,''),'planned'),
            COALESCE(p_memo,''))
    RETURNING id INTO new_id;
    RETURN new_id;
  ELSE
    UPDATE aps_plans
       SET item_id  = p_item_id,
           line_id  = p_line_id,
           qty      = p_qty,
           start_at = p_start_at,
           end_at   = p_end_at,
           status   = COALESCE(NULLIF(p_status,''),'planned'),
           memo     = COALESCE(p_memo,''),
           updated_at = now()
     WHERE id = p_id;
    RETURN p_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
