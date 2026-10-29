-- ═══════════════════════════════════════════
-- APS — 🤖 자동 생성 제안 기록 (보정 모델 학습용) — 1회 실행
--  자동 생성으로 계획을 만들 때 규칙이 처음 제안한 품목·수량·라인·시간을
--  계획 번호와 함께 따로 남긴다. 나중에 계획을 고치거나 지워도 이 기록은 그대로.
--  → 처음 제안 vs 지금 계획(aps_plans) vs 실제 생산량 비교 가능.
--  setup_aps.sql 실행 전제 (aps_assert_admin 사용). 다시 실행해도 안전.
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS aps_autoplan_log (
  id BIGSERIAL PRIMARY KEY,
  batch_id TEXT NOT NULL,              -- 한 번 "생성" 누를 때마다 같은 값
  created_at TIMESTAMPTZ DEFAULT now(),
  day DATE NOT NULL,                   -- 계획 날짜
  item_id BIGINT,
  item_code TEXT DEFAULT '',
  item_name TEXT DEFAULT '',
  created BOOLEAN NOT NULL DEFAULT TRUE, -- false = 제안됐지만 체크를 빼서 안 만듦
  plan_id BIGINT,                      -- 만든 계획 번호 (FK 없음 — 계획을 지워도 기록 유지)
  rule_qty NUMERIC,                    -- 규칙이 제안한 수량 (AI가 추가한 품목이면 NULL)
  saved_qty NUMERIC,                   -- 생성 때 저장한 수량 (AI 반영 후)
  line_id BIGINT,
  start_at TIMESTAMPTZ,
  end_at TIMESTAMPTZ,
  fill BOOLEAN DEFAULT FALSE,          -- 여유 생산 여부
  partial BOOLEAN DEFAULT FALSE,       -- 시간 부족으로 일부만
  need NUMERIC,                        -- 원래 필요한 수량
  stock_now NUMERIC,                   -- 재고시트 재고
  start_stock NUMERIC,                 -- 그날 시작 예상 재고
  first_short DATE,                    -- 부족 예상일
  avg_daily NUMERIC,                   -- 하루 평균 수요
  floor_qty NUMERIC,                   -- 바닥(안전재고)
  target_demand NUMERIC,               -- 그날 예상 수요
  demand_src TEXT DEFAULT '',          -- ml | dow
  rate NUMERIC,                        -- 시간당 생산량
  rate_src TEXT DEFAULT '',
  ai_qty NUMERIC,                      -- 🧠 AI가 바꾼 수량 (없으면 NULL)
  extra JSONB DEFAULT '{}'::jsonb      -- 옵션 등
);
CREATE INDEX IF NOT EXISTS idx_aps_autoplan_log_day ON aps_autoplan_log(day DESC);
CREATE INDEX IF NOT EXISTS idx_aps_autoplan_log_plan ON aps_autoplan_log(plan_id);
CREATE INDEX IF NOT EXISTS idx_aps_autoplan_log_item ON aps_autoplan_log(item_id);
ALTER TABLE aps_autoplan_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON aps_autoplan_log FROM anon, authenticated;

-- 기록 저장 (rows: JSONB 배열). 365일 지난 기록은 같이 정리
CREATE OR REPLACE FUNCTION aps_log_autoplan(p_admin_hash TEXT, p_batch_id TEXT, p_rows JSONB)
RETURNS INT AS $$
DECLARE n INT;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  DELETE FROM aps_autoplan_log WHERE created_at < now() - INTERVAL '365 days';
  INSERT INTO aps_autoplan_log (batch_id, day, item_id, item_code, item_name, created, plan_id,
    rule_qty, saved_qty, line_id, start_at, end_at, fill, partial, need, stock_now, start_stock,
    first_short, avg_daily, floor_qty, target_demand, demand_src, rate, rate_src, ai_qty, extra)
  SELECT COALESCE(p_batch_id, ''),
    (r->>'day')::date,
    NULLIF(r->>'item_id','')::bigint,
    COALESCE(r->>'item_code',''), COALESCE(r->>'item_name',''),
    COALESCE((r->>'created')::boolean, true),
    NULLIF(r->>'plan_id','')::bigint,
    NULLIF(r->>'rule_qty','')::numeric, NULLIF(r->>'saved_qty','')::numeric,
    NULLIF(r->>'line_id','')::bigint,
    NULLIF(r->>'start_at','')::timestamptz, NULLIF(r->>'end_at','')::timestamptz,
    COALESCE((r->>'fill')::boolean, false), COALESCE((r->>'partial')::boolean, false),
    NULLIF(r->>'need','')::numeric, NULLIF(r->>'stock_now','')::numeric, NULLIF(r->>'start_stock','')::numeric,
    NULLIF(r->>'first_short','')::date,
    NULLIF(r->>'avg_daily','')::numeric, NULLIF(r->>'floor_qty','')::numeric, NULLIF(r->>'target_demand','')::numeric,
    COALESCE(r->>'demand_src',''),
    NULLIF(r->>'rate','')::numeric, COALESCE(r->>'rate_src',''),
    NULLIF(r->>'ai_qty','')::numeric,
    COALESCE(r->'extra','{}'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_rows,'[]'::jsonb)) r
  WHERE r ? 'day';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 기록 조회: 처음 제안 + 지금 계획 상태(수량·품목·상태·실제 수량, 지워졌는지)
CREATE OR REPLACE FUNCTION aps_list_autoplan_log(p_admin_hash TEXT, p_days INT DEFAULT 90)
RETURNS JSONB AS $$
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);
  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.day DESC, x.id) FROM (
      SELECT l.*,
        (l.plan_id IS NOT NULL AND p.id IS NULL) AS plan_deleted,
        p.item_id AS now_item_id, p.qty AS now_qty, p.line_id AS now_line_id,
        p.status AS now_status, p.actual_qty AS now_actual_qty,
        p.start_at AS now_start_at, p.end_at AS now_end_at
      FROM aps_autoplan_log l
      LEFT JOIN aps_plans p ON p.id = l.plan_id
      WHERE l.day >= (now() AT TIME ZONE 'Asia/Seoul')::date - COALESCE(p_days, 90)
    ) x
  ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
