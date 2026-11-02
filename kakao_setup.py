"""
카카오톡 알림 최초 연결 (한 번만 실행)

하는 일
  1) 카카오 로그인 주소를 브라우저로 연다 → 동의
  2) 이동한 주소(https://localhost/?code=...)를 붙여넣으면 토큰을 받는다
  3) 나에게 테스트 메시지를 보낸다
  4) refresh token 을 Supabase app_secrets 테이블에 저장한다
     (SUPABASE_KEY(service role) 환경변수가 없으면 Supabase SQL Editor에 붙여넣을 SQL을 출력)

사용법
  python kakao_setup.py <REST_API_키> [클라이언트_시크릿]
  (또는 환경변수 KAKAO_REST_API_KEY / KAKAO_CLIENT_SECRET)

준비 (developers.kakao.com → 내 애플리케이션)
  - 앱 설정 > 플랫폼 > Web 사이트 도메인: https://ainsightlab.kr
  - 제품 설정 > 카카오 로그인: 활성화 ON, Redirect URI: https://localhost
  - 제품 설정 > 카카오 로그인 > 동의항목: "카카오톡 메시지 전송" 선택 동의
"""
import json
import os
import sys
import urllib.parse
import webbrowser

import requests

REDIRECT_URI = os.environ.get("KAKAO_REDIRECT_URI", "https://localhost")
SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://mmmpqmvwpuxqyxlxytsh.supabase.co")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")
SITE_URL = os.environ.get("SITE_URL", "https://ainsightlab.kr")


def main():
    rest_key = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("KAKAO_REST_API_KEY", "")).strip()
    secret = (sys.argv[2] if len(sys.argv) > 2 else os.environ.get("KAKAO_CLIENT_SECRET", "")).strip()
    if not rest_key:
        print("사용법: python kakao_setup.py <REST_API_키> [클라이언트_시크릿]")
        sys.exit(1)

    auth_url = "https://kauth.kakao.com/oauth/authorize?" + urllib.parse.urlencode({
        "client_id": rest_key,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": "talk_message",
    })
    print("\n1) 아래 주소가 브라우저에서 열립니다. 카카오 로그인 → '카카오톡 메시지 전송' 동의")
    print("   (안 열리면 직접 복사해서 여세요)\n   " + auth_url)
    try:
        webbrowser.open(auth_url)
    except Exception:
        pass
    print("\n2) 동의 후 '사이트에 연결할 수 없음' 화면이 나와도 정상입니다.")
    pasted = input("   그때 주소창의 전체 주소(https://localhost/?code=...)를 붙여넣고 Enter: ").strip()
    code = urllib.parse.parse_qs(urllib.parse.urlparse(pasted).query).get("code", [pasted])[0]
    if not code:
        print("code 를 찾지 못했습니다.")
        sys.exit(1)

    data = {"grant_type": "authorization_code", "client_id": rest_key,
            "redirect_uri": REDIRECT_URI, "code": code}
    if secret:
        data["client_secret"] = secret
    r = requests.post("https://kauth.kakao.com/oauth/token", data=data, timeout=15)
    tok = r.json()
    if "access_token" not in tok:
        print("토큰 발급 실패:", tok)
        sys.exit(1)
    access, refresh = tok["access_token"], tok.get("refresh_token", "")
    print("\n✅ 토큰 발급 완료 (refresh token 유효 약 2개월 — 크롤러가 매일 쓰면서 자동 연장)")

    template = {
        "object_type": "text",
        "text": "✅ STOCKPULSE 카카오톡 알림이 연결됐습니다.\n장 마감 후 성과 추적 종목이 편입·매도되면 이 대화방으로 알려드립니다.",
        "link": {"web_url": SITE_URL, "mobile_web_url": SITE_URL},
        "button_title": "사이트 열기",
    }
    s = requests.post("https://kapi.kakao.com/v2/api/talk/memo/default/send",
                      headers={"Authorization": f"Bearer {access}"},
                      data={"template_object": json.dumps(template, ensure_ascii=False)}, timeout=15)
    print("3) 테스트 메시지:", "✅ 보냄 (카카오톡 '나와의 채팅' 확인)" if s.status_code == 200 else f"❌ {s.status_code} {s.text[:200]}")

    if SUPABASE_KEY:
        h = {"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}",
             "Content-Type": "application/json", "Prefer": "resolution=merge-duplicates"}
        u = requests.post(f"{SUPABASE_URL}/rest/v1/app_secrets", headers=h,
                          json=[{"key": "kakao_refresh_token", "value": refresh}], timeout=15)
        print("4) Supabase 저장:", "✅" if u.status_code < 300 else f"❌ {u.status_code} {u.text[:200]}")
    else:
        print("\n4) SUPABASE_KEY 환경변수가 없어서 직접 저장해야 합니다.")
        print("   Supabase → SQL Editor 에 아래 SQL을 붙여넣고 실행하세요 (setup_kakao.sql 먼저 실행):\n")
        print(f"INSERT INTO app_secrets(key, value) VALUES ('kakao_refresh_token', '{refresh}')\n"
              f"  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();\n")
    print("마지막으로 GitHub → Settings → Secrets and variables → Actions 에 KAKAO_REST_API_KEY"
          + (" 와 KAKAO_CLIENT_SECRET" if secret else "") + " 를 등록하세요.")


if __name__ == "__main__":
    main()
