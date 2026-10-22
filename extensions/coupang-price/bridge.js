// orders.html 페이지 ↔ 확장 프로그램(background) 연결
// 페이지는 window.postMessage({__olpage:true, type}) 로 보내고, 확장은 {__olext:true, type} 로 답함
(() => {
  const VER = chrome.runtime.getManifest().version;
  let port = null;
  const post = (m) => window.postMessage({ __olext: true, ...m }, location.origin);

  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || e.data.__olpage !== true) return;
    const d = e.data;
    if (d.type === "ping") {
      post({ type: "pong", version: VER, running: !!port });
    } else if (d.type === "run") {
      if (port) { post({ type: "error", message: "이미 갱신 중입니다" }); return; }
      try {
        port = chrome.runtime.connect({ name: "olprice" });
      } catch (err) {
        port = null;
        post({ type: "error", message: "확장 프로그램이 다시 로드됐습니다. 이 페이지를 새로고침하세요." });
        return;
      }
      port.onMessage.addListener((m) => {
        post(m);
        if (m.type === "done" || m.type === "stopped") {
          const p = port; port = null;
          try { p.disconnect(); } catch (err) {}
        }
      });
      port.onDisconnect.addListener(() => {
        if (port) { port = null; post({ type: "stopped", reason: "disconnected" }); }
      });
      port.postMessage({ type: "run", jobs: d.jobs || [], delayMs: d.delayMs });
    } else if (d.type === "stop") {
      if (port) port.postMessage({ type: "stop" });
    }
  });

  post({ type: "ready", version: VER });
})();
