-- =============================================
-- 카카오톡 알림용 토큰 보관 (app_secrets)
--
-- 크롤러가 카카오톡 "나에게 보내기"를 쓰려면 카카오 로그인 refresh token이 필요하다.
-- refresh token은 쓸 때마다 새로 바뀔 수 있어서 GitHub Secrets 대신 여기에 저장하고,
-- 크롤러(service role 키)가 읽고 갱신한다.
--
-- RLS를 켜고 정책을 하나도 만들지 않음 → 공개(anon) 키로는 읽기·쓰기 모두 불가.
-- service role 키(크롤러)만 RLS를 우회해서 접근한다.
--
-- 1회 실행. 재실행 안전.
-- =============================================

CREATE TABLE IF NOT EXISTS app_secrets (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE app_secrets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON app_secrets FROM anon, authenticated;

-- 최초 연결은 kakao_setup.py 가 이 테이블에 직접 저장한다.
-- (스크립트 없이 넣으려면 아래 줄의 값을 바꿔 실행)
-- INSERT INTO app_secrets(key, value) VALUES ('kakao_refresh_token', '여기에_refresh_token')
--   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
