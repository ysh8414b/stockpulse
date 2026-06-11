-- ═══════════════════════════════════════════
-- STOCKPULSE APS (Advanced Planning & Scheduling)
-- 생산계획 시스템 — 관리자 전용
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_board.sql 실행 완료 (board_admins 테이블 필요)
-- ═══════════════════════════════════════════

-- ═══ 1. 품목 마스터 ═══
CREATE TABLE IF NOT EXISTS aps_items (
  id BIGSERIAL PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('product','semi','material')),
  unit TEXT NOT NULL DEFAULT 'EA',
  spec TEXT DEFAULT '',
  safety_stock NUMERIC NOT NULL DEFAULT 0,
  lead_time_days INT NOT NULL DEFAULT 0,
  memo TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE aps_items ENABLE ROW LEVEL SECURITY;
-- 정책 없음 → 직접 REST 접근 차단, SECURITY DEFINER RPC로만 접근

-- ═══ 2. BOM (자재명세서) ═══
CREATE TABLE IF NOT EXISTS aps_bom (
  id BIGSERIAL PRIMARY KEY,
  parent_id BIGINT NOT NULL REFERENCES aps_items(id) ON DELETE CASCADE,
  child_id  BIGINT NOT NULL REFERENCES aps_items(id) ON DELETE RESTRICT,
  qty NUMERIC NOT NULL CHECK (qty > 0),
  loss_rate NUMERIC NOT NULL DEFAULT 0 CHECK (loss_rate >= 0 AND loss_rate < 100),
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(parent_id, child_id),
  CHECK (parent_id <> child_id)
);
CREATE INDEX IF NOT EXISTS idx_aps_bom_parent ON aps_bom(parent_id);
ALTER TABLE aps_bom ENABLE ROW LEVEL SECURITY;

-- ═══ 3. 생산계획 ═══
CREATE TABLE IF NOT EXISTS aps_plans (
  id BIGSERIAL PRIMARY KEY,
  item_id BIGINT NOT NULL REFERENCES aps_items(id) ON DELETE RESTRICT,
  qty NUMERIC NOT NULL CHECK (qty > 0),
  start_date DATE NOT NULL,
  due_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned','in_progress','done','canceled')),
  memo TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  CHECK (due_date >= start_date)
);
CREATE INDEX IF NOT EXISTS idx_aps_plans_dates  ON aps_plans(start_date, due_date);
CREATE INDEX IF NOT EXISTS idx_aps_plans_status ON aps_plans(status);
ALTER TABLE aps_plans ENABLE ROW LEVEL SECURITY;

-- ═══ 4. 입출고 트랜잭션 ═══
-- qty는 부호 포함(입고+ / 출고- / 조정±). 재고는 SUM(qty)로 계산.
CREATE TABLE IF NOT EXISTS aps_stock_txns (
  id BIGSERIAL PRIMARY KEY,
  item_id BIGINT NOT NULL REFERENCES aps_items(id) ON DELETE RESTRICT,
  txn_type TEXT NOT NULL CHECK (txn_type IN ('in','out','adjust')),
  qty NUMERIC NOT NULL,
  related_plan_id BIGINT REFERENCES aps_plans(id) ON DELETE SET NULL,
  memo TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_aps_stock_txns_item
  ON aps_stock_txns(item_id, created_at DESC);
ALTER TABLE aps_stock_txns ENABLE ROW LEVEL SECURITY;

-- ═══ 5. 재고 현황 VIEW ═══
CREATE OR REPLACE VIEW aps_inventory_view AS
SELECT
  i.id          AS item_id,
  i.code,
  i.name,
  i.type,
  i.unit,
  i.safety_stock,
  COALESCE(SUM(t.qty), 0)                  AS current_stock,
  COALESCE(SUM(t.qty), 0) - i.safety_stock AS stock_diff,
  CASE
    WHEN COALESCE(SUM(t.qty), 0) <= 0 THEN 'out'
    WHEN COALESCE(SUM(t.qty), 0) < i.safety_stock THEN 'low'
    ELSE 'ok'
  END AS stock_status
FROM aps_items i
LEFT JOIN aps_stock_txns t ON t.item_id = i.id
GROUP BY i.id;

-- ═══════════════════════════════════════════
-- 인증 헬퍼 (board_admins.password_hash 검증)
-- ═══════════════════════════════════════════
CREATE OR REPLACE FUNCTION aps_assert_admin(p_admin_hash TEXT)
RETURNS VOID AS $$
BEGIN
  IF p_admin_hash IS NULL OR p_admin_hash = '' THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM board_admins WHERE password_hash = p_admin_hash) THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 품목 RPC
-- ═══════════════════════════════════════════

CREATE OR REPLACE FUNCTION aps_list_items(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id', id, 'code', code, 'name', name, 'type', type,
      'unit', unit, 'spec', spec,
      'safety_stock', safety_stock, 'lead_time_days', lead_time_days,
      'memo', memo,
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY type, code), '[]'::json)
    FROM aps_items
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- p_id NULL이면 INSERT, 값이 있으면 UPDATE
CREATE OR REPLACE FUNCTION aps_upsert_item(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_code TEXT,
  p_name TEXT,
  p_type TEXT,
  p_unit TEXT,
  p_spec TEXT,
  p_safety_stock NUMERIC,
  p_lead_time_days INT,
  p_memo TEXT
) RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_id IS NULL THEN
    INSERT INTO aps_items (code, name, type, unit, spec, safety_stock, lead_time_days, memo)
    VALUES (p_code, p_name, p_type,
            COALESCE(NULLIF(p_unit,''),'EA'),
            COALESCE(p_spec,''), p_safety_stock, p_lead_time_days,
            COALESCE(p_memo,''))
    RETURNING id INTO new_id;
    RETURN new_id;
  ELSE
    UPDATE aps_items
    SET code = p_code,
        name = p_name,
        type = p_type,
        unit = COALESCE(NULLIF(p_unit,''),'EA'),
        spec = COALESCE(p_spec,''),
        safety_stock = p_safety_stock,
        lead_time_days = p_lead_time_days,
        memo = COALESCE(p_memo,''),
        updated_at = now()
    WHERE id = p_id;
    RETURN p_id;
  END IF;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'duplicate_code';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 트랜잭션/계획/BOM 참조가 있으면 삭제 거부
CREATE OR REPLACE FUNCTION aps_delete_item(p_admin_hash TEXT, p_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF EXISTS (SELECT 1 FROM aps_stock_txns WHERE item_id = p_id) THEN
    RAISE EXCEPTION 'has_txns';
  END IF;
  IF EXISTS (SELECT 1 FROM aps_plans WHERE item_id = p_id) THEN
    RAISE EXCEPTION 'has_plans';
  END IF;
  IF EXISTS (SELECT 1 FROM aps_bom WHERE child_id = p_id) THEN
    RAISE EXCEPTION 'used_in_bom';
  END IF;
  DELETE FROM aps_items WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- BOM RPC
-- ═══════════════════════════════════════════

CREATE OR REPLACE FUNCTION aps_list_bom(p_admin_hash TEXT, p_parent_id BIGINT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'id',         b.id,
      'parent_id',  b.parent_id,
      'child_id',   b.child_id,
      'child_code', c.code,
      'child_name', c.name,
      'child_type', c.type,
      'child_unit', c.unit,
      'qty',        b.qty,
      'loss_rate',  b.loss_rate
    ) ORDER BY c.code), '[]'::json)
    FROM aps_bom b
    JOIN aps_items c ON c.id = b.child_id
    WHERE b.parent_id = p_parent_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_upsert_bom(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_parent_id BIGINT,
  p_child_id BIGINT,
  p_qty NUMERIC,
  p_loss_rate NUMERIC
) RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_parent_id = p_child_id THEN
    RAISE EXCEPTION 'self_reference';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO aps_bom (parent_id, child_id, qty, loss_rate)
    VALUES (p_parent_id, p_child_id, p_qty, COALESCE(p_loss_rate,0))
    RETURNING id INTO new_id;
    RETURN new_id;
  ELSE
    UPDATE aps_bom
    SET qty = p_qty,
        loss_rate = COALESCE(p_loss_rate,0)
    WHERE id = p_id;
    RETURN p_id;
  END IF;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'duplicate_child';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_delete_bom(p_admin_hash TEXT, p_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_bom WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 생산계획 RPC
-- ═══════════════════════════════════════════

CREATE OR REPLACE FUNCTION aps_list_plans(p_admin_hash TEXT, p_status TEXT DEFAULT NULL)
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
      'qty',        p.qty,
      'start_date', p.start_date,
      'due_date',   p.due_date,
      'status',     p.status,
      'memo',       p.memo,
      'created_at', p.created_at,
      'updated_at', p.updated_at
    ) ORDER BY p.due_date DESC, p.id DESC), '[]'::json)
    FROM aps_plans p
    JOIN aps_items i ON i.id = p.item_id
    WHERE p_status IS NULL OR p.status = p_status
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_upsert_plan(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_item_id BIGINT,
  p_qty NUMERIC,
  p_start_date DATE,
  p_due_date DATE,
  p_status TEXT,
  p_memo TEXT
) RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_due_date < p_start_date THEN
    RAISE EXCEPTION 'invalid_dates';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO aps_plans (item_id, qty, start_date, due_date, status, memo)
    VALUES (p_item_id, p_qty, p_start_date, p_due_date,
            COALESCE(NULLIF(p_status,''),'planned'),
            COALESCE(p_memo,''))
    RETURNING id INTO new_id;
    RETURN new_id;
  ELSE
    UPDATE aps_plans
    SET item_id = p_item_id,
        qty = p_qty,
        start_date = p_start_date,
        due_date = p_due_date,
        status = COALESCE(NULLIF(p_status,''),'planned'),
        memo = COALESCE(p_memo,''),
        updated_at = now()
    WHERE id = p_id;
    RETURN p_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_delete_plan(p_admin_hash TEXT, p_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_plans WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════
-- 재고 / 입출고 RPC
-- ═══════════════════════════════════════════

CREATE OR REPLACE FUNCTION aps_list_inventory(p_admin_hash TEXT)
RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(json_build_object(
      'item_id',       item_id,
      'code',          code,
      'name',          name,
      'type',          type,
      'unit',          unit,
      'safety_stock',  safety_stock,
      'current_stock', current_stock,
      'stock_diff',    stock_diff,
      'stock_status',  stock_status
    ) ORDER BY
      CASE stock_status WHEN 'out' THEN 0 WHEN 'low' THEN 1 ELSE 2 END,
      type, code), '[]'::json)
    FROM aps_inventory_view
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 입출고 기록
--   p_txn_type='in'     → 부호 + (사용자는 양수 입력)
--   p_txn_type='out'    → 부호 - (내부에서 음수 변환)
--   p_txn_type='adjust' → p_qty 그대로 (사용자가 ± 입력)
CREATE OR REPLACE FUNCTION aps_record_stock(
  p_admin_hash TEXT,
  p_item_id BIGINT,
  p_txn_type TEXT,
  p_qty NUMERIC,
  p_related_plan_id BIGINT,
  p_memo TEXT
) RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
  signed_qty NUMERIC;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  IF p_txn_type IN ('in','out') AND p_qty <= 0 THEN
    RAISE EXCEPTION 'invalid_qty';
  END IF;
  IF p_txn_type = 'adjust' AND p_qty = 0 THEN
    RAISE EXCEPTION 'invalid_qty';
  END IF;
  IF p_txn_type = 'in' THEN
    signed_qty := p_qty;
  ELSIF p_txn_type = 'out' THEN
    signed_qty := -p_qty;
  ELSE
    signed_qty := p_qty;
  END IF;
  INSERT INTO aps_stock_txns (item_id, txn_type, qty, related_plan_id, memo)
  VALUES (p_item_id, p_txn_type, signed_qty, p_related_plan_id, COALESCE(p_memo,''))
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_list_stock_txns(
  p_admin_hash TEXT,
  p_item_id BIGINT DEFAULT NULL,
  p_limit INT DEFAULT 100
) RETURNS JSON AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN (
    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.created_at DESC), '[]'::json)
    FROM (
      SELECT
        t.id, t.item_id, i.code AS item_code, i.name AS item_name, i.unit,
        t.txn_type, t.qty, t.related_plan_id, t.memo, t.created_at
      FROM aps_stock_txns t
      JOIN aps_items i ON i.id = t.item_id
      WHERE p_item_id IS NULL OR t.item_id = p_item_id
      ORDER BY t.created_at DESC
      LIMIT COALESCE(p_limit, 100)
    ) x
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION aps_delete_stock_txn(p_admin_hash TEXT, p_id BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_stock_txns WHERE id = p_id;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
