// APS·발주리스트 앱 설치 지원
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
    d.style.cssText = "position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:99998;max-width:calc(100% - 32px);" +
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

  // 안드로이드·PC 크롬/엣지/웨일: 설치 버튼
  window.addEventListener("beforeinstallprompt", function (ev) {
    ev.preventDefault();
    var promptEv = ev;
    bar("📲 " + appName + "을(를) 앱으로 설치할 수 있어요", function () {
      promptEv.prompt();
      promptEv.userChoice.then(function (r) { if (r && r.outcome !== "accepted") hideLater(); }).catch(function () {});
    });
  });

  // 아이폰·아이패드 사파리: 직접 추가 안내
  var ua = navigator.userAgent || "";
  var ios = /iPhone|iPad|iPod/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (ios && /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|Whale/.test(ua)) {
    window.addEventListener("load", function () {
      setTimeout(function () { bar("📲 앱으로 쓰려면 아래 <b>공유</b> 버튼 → <b>홈 화면에 추가</b>"); }, 1500);
    });
  }
})();
