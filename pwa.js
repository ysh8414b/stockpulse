// 메인·APS·발주리스트 앱 설치 지원 (크롬이 아니면 크롬에서 설치하라고 안내)
// 사용: <script src="pwa.js" data-scope="./aps.html" data-name="APS" defer></script>
(function () {
  var me = document.currentScript;
  var scope = (me && me.getAttribute("data-scope")) || "./";
  var appName = (me && me.getAttribute("data-name")) || "앱";
  if (!/^https?:$/.test(location.protocol)) return;

  if ("serviceWorker" in navigator) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("sw-apps.js", { scope: scope }).catch(function () {});
    });
  }

  var standalone = (window.matchMedia && matchMedia("(display-mode: standalone)").matches) || navigator.standalone === true;
  if (standalone || window !== window.top) return;

  var KEY = "sp-pwa-hide:" + scope;
  function hidden() { try { return Date.now() - Number(localStorage.getItem(KEY) || 0) < 14 * 864e5; } catch (e) { return false; } }
  function hideLater() { try { localStorage.setItem(KEY, String(Date.now())); } catch (e) {} }

  function bar(html, onInstall) {
    if (hidden() || document.getElementById("sp-pwa-bar")) return;
    var d = document.createElement("div");
    d.id = "sp-pwa-bar";
    d.setAttribute("data-html2canvas-ignore", "true");
    d.style.cssText = "position:fixed;left:50%;bottom:calc(16px + var(--sp-bottom,0px));transform:translateX(-50%);z-index:99998;max-width:calc(100% - 32px);" +
      "display:flex;align-items:center;gap:10px;padding:10px 12px 10px 16px;border-radius:12px;background:#111827;color:#f9fafb;" +
      "font:600 13px/1.4 Pretendard,-apple-system,sans-serif;box-shadow:0 6px 24px rgba(0,0,0,.35)";
    d.innerHTML = "<span style='flex:1'>" + html + "</span>" +
      (onInstall ? "<button data-a='go' style='border:0;border-radius:8px;padding:7px 12px;background:#06b6d4;color:#fff;font:inherit;cursor:pointer'>설치</button>" : "") +
      "<button data-a='x' aria-label='닫기' style='border:0;background:none;color:#9ca3af;font:inherit;font-size:16px;cursor:pointer;padding:4px'>✕</button>";
    d.addEventListener("click", function (ev) {
      var a = ev.target && ev.target.getAttribute && ev.target.getAttribute("data-a");
      if (a === "go") { onInstall(); d.remove(); }
      if (a === "x") { hideLater(); d.remove(); }
    });
    document.body.appendChild(d);
  }

  var ua = navigator.userAgent || "";
  var ios = /iPhone|iPad|iPod/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  var android = /Android/.test(ua);
  // 진짜 크롬인지 (엣지·웨일·삼성 인터넷·카카오톡/네이버 앱 안 브라우저 등은 제외)
  var isChrome = /Chrome\/|CriOS\//.test(ua) &&
    !/Edg|OPR|Opera|Whale|SamsungBrowser|NAVER|KAKAOTALK|DaumApps|Line\/|FBAN|FBAV|Instagram|YaBrowser|UCBrowser|MiuiBrowser|HuaweiBrowser|; wv\)/.test(ua) &&
    !navigator.brave;
  var iosSafari = ios && /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|Whale|NAVER|KAKAOTALK|DaumApps/.test(ua);

  // 크롬이 아닐 때: 크롬에서 설치하라는 안내 창
  function chromeMsg() {
    if (document.getElementById("sp-pwa-msg")) return;
    var bg = document.createElement("div");
    bg.id = "sp-pwa-msg";
    bg.setAttribute("data-html2canvas-ignore", "true");
    bg.style.cssText = "position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;padding:16px";
    var btn = "border:0;border-radius:8px;padding:10px 14px;font:inherit;cursor:pointer;";
    bg.innerHTML = "<div style='max-width:340px;width:100%;background:#111827;color:#f9fafb;border-radius:14px;padding:20px;" +
      "font:500 14px/1.6 Pretendard,-apple-system,sans-serif;box-shadow:0 10px 40px rgba(0,0,0,.4)'>" +
      "<div style='font-size:16px;font-weight:700;margin-bottom:8px'>📲 크롬에서 설치해 주세요</div>" +
      "<div style='color:#d1d5db'>" + appName + " 앱은 <b style='color:#fff'>Chrome(크롬) 브라우저</b>에서 설치해야 제대로 동작해요. " +
      "지금 브라우저에서는 설치나 일부 기능이 안 될 수 있어요.</div>" +
      (android ? "" : "<div style='color:#9ca3af;font-size:13px;margin-top:8px'>크롬을 열고 아래 주소로 접속한 뒤 설치 버튼을 눌러 주세요.</div>") +
      "<div style='display:flex;gap:8px;margin-top:16px;flex-wrap:wrap'>" +
      (android ? "<button data-a='open' style='" + btn + "flex:1;background:#06b6d4;color:#fff;font-weight:700'>크롬으로 열기</button>" : "") +
      "<button data-a='copy' style='" + btn + "flex:1;background:" + (android ? "#374151" : "#06b6d4") + ";color:#fff;font-weight:700'>주소 복사</button>" +
      "<button data-a='close' style='" + btn + "background:none;color:#9ca3af'>닫기</button>" +
      "</div></div>";
    bg.addEventListener("click", function (ev) {
      var a = ev.target && ev.target.getAttribute && ev.target.getAttribute("data-a");
      if (ev.target === bg || a === "close") { bg.remove(); return; }
      if (a === "open") {
        location.href = "intent://" + location.host + location.pathname + location.search +
          "#Intent;scheme=" + location.protocol.replace(":", "") + ";package=com.android.chrome;S.browser_fallback_url=" +
          encodeURIComponent("https://play.google.com/store/apps/details?id=com.android.chrome") + ";end";
      }
      if (a === "copy") {
        var url = location.href.split("#")[0];
        var done = function () { ev.target.textContent = "✓ 복사됨"; };
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(url).then(done, function () { window.prompt("주소를 복사해 주세요", url); });
        else window.prompt("주소를 복사해 주세요", url);
      }
    });
    document.body.appendChild(bg);
  }

  // 안드로이드·PC: 설치 버튼 (크롬이면 바로 설치, 다른 브라우저면 크롬 안내)
  var prompted = false;
  window.addEventListener("beforeinstallprompt", function (ev) {
    ev.preventDefault();
    prompted = true;
    var promptEv = ev;
    bar("📲 " + appName + "을(를) 앱으로 설치할 수 있어요", function () {
      if (!isChrome) { chromeMsg(); return; }
      promptEv.prompt();
      promptEv.userChoice.then(function (r) { if (r && r.outcome !== "accepted") hideLater(); }).catch(function () {});
    });
  });

  if (iosSafari || (ios && /CriOS/.test(ua))) {
    // 아이폰·아이패드 사파리/크롬: 직접 추가 안내
    window.addEventListener("load", function () {
      setTimeout(function () { bar("📲 앱으로 쓰려면 <b>공유</b> 버튼 → <b>홈 화면에 추가</b>"); }, 1500);
    });
  } else if (!isChrome) {
    // 설치 버튼 이벤트가 없는 브라우저(파이어폭스·앱 안 브라우저 등)도 안내
    window.addEventListener("load", function () {
      setTimeout(function () { if (!prompted) bar("📲 " + appName + "을(를) 앱으로 설치할 수 있어요", chromeMsg); }, 1500);
    });
  }
})();
