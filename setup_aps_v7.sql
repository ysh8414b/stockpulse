-- ═══════════════════════════════════════════
-- STOCKPULSE APS v7 — 원자재 매칭 키워드 (재고시트 원육 ↔ BOM 원자재 자동 연동)
-- Supabase SQL Editor에서 1회 실행
-- 전제: setup_aps.sql + v2 + v3 + v4 + v5 + v6 실행 완료
-- 목적:
--   1) 원자재(type='material')에 매칭 키워드 배열(JSONB) 추가
--   2) 재고시트 원육 이름(예: "냉동우육 삼겹양지 SWIFT 3D")과 원자재 매칭 규칙 저장
--   3) 생산계획 작성 시 제품 → BOM → 원자재 필요량 vs 재고시트 매칭 kg 자동 비교
-- 안전: 컬럼/함수 모두 IF NOT EXISTS / OR REPLACE 패턴. 기존 데이터 보존.
-- ═══════════════════════════════════════════

-- ═══ 1. 매칭 키워드 컬럼 추가 ═══
-- 예:
--   name = "삼겹양지(미국)"
--   match_keywords = ["삼겹양지 SWIFT", "삼겹양지 CARGILL"]
--   → 재고시트 원육 이름에 두 키워드 중 하나라도 포함되면 이 원자재로 매칭
-- 각 키워드는 공백으로 여러 단어를 AND 매칭 (예: "삼겹양지 SWIFT" → 이름에 "삼겹양지"와 "SWIFT" 둘 다 포함되어야 매칭)
-- 대소문자 무관 (프론트에서 toLowerCase 후 비교)
ALTER TABLE aps_items ADD COLUMN IF NOT EXISTS match_keywords JSONB NOT NULL DEFAULT '[]'::jsonb;

-- ═══ 2. aps_list_items 재정의 (match_keywords 포함) ═══
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
      'match_keywords', match_keywords,
      'created_at', created_at, 'updated_at', updated_at
    ) ORDER BY type, code), '[]'::json)
    FROM aps_items
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══ 3. aps_upsert_item 재정의 (match_keywords 파라미터 추가) ═══
-- 기존 시그니처: (hash,id,code,name,type,unit,spec,safety_stock,lead_time_days,memo)
-- 새 시그니처:   (hash,id,code,name,type,unit,spec,safety_stock,lead_time_days,memo, match_keywords JSONB)
-- 시그니처가 바뀌므로 DROP → CREATE. 클라이언트는 항상 match_keywords 파라미터를 함께 전송해야 함.
DROP FUNCTION IF EXISTS aps_upsert_item(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, INT, TEXT);
DROP FUNCTION IF EXISTS aps_upsert_item(TEXT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, INT, TEXT, JSONB);

CREATE FUNCTION aps_upsert_item(
  p_admin_hash TEXT,
  p_id BIGINT,
  p_code TEXT,
  p_name TEXT,
  p_type TEXT,
  p_unit TEXT,
  p_spec TEXT,
  p_safety_stock NUMERIC,
  p_lead_time_days INT,
  p_memo TEXT,
  p_match_keywords JSONB DEFAULT '[]'::jsonb
) RETURNS BIGINT AS $$
DECLARE
  new_id BIGINT;
  v_keywords JSONB;
BEGIN
  PERFORM aps_assert_admin(p_admin_hash);

  -- 원자재(material)가 아니면 매칭 키워드 무시 (제품/반제품은 재고시트 원육 매칭 불필요)
  IF p_type = 'material' THEN
    v_keywords := COALESCE(p_match_keywords, '[]'::jsonb);
  ELSE
    v_keywords := '[]'::jsonb;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO aps_items (code, name, type, unit, spec, safety_stock, lead_time_days, memo, match_keywords)
    VALUES (p_code, p_name, p_type,
            COALESCE(NULLIF(p_unit,''),'EA'),
            COALESCE(p_spec,''), p_safety_stock, p_lead_time_days,
            COALESCE(p_memo,''),
            v_keywords)
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
        match_keywords = v_keywords,
        updated_at = now()
    WHERE id = p_id;
    RETURN p_id;
  END IF;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'duplicate_code';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
