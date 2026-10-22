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
    } else if (d.type === "search") {
      // 시장조사: 쿠팡 검색 결과 1페이지 읽기 (가격 갱신과 같은 포트 연결 방식)
      const fail = (msg) => post({ type: "searchResult", reqId: d.reqId, error: msg });
      let sp;
      try {
        sp = chrome.runtime.connect({ name: "olsearch" });
      } catch (err) {
        fail("확장 프로그램이 다시 로드됐습니다. 이 페이지를 새로고침하세요.");
        return;
      }
      let answered = false;
      sp.onMessage.addListener((r) => {
        answered = true;
        post({ type: "searchResult", reqId: d.reqId, ...(r || { error: "응답 없음" }) });
        try { sp.disconnect(); } catch (err) {}
      });
      sp.onDisconnect.addListener(() => {
        if (answered) return;
        const le = chrome.runtime.lastError;
        fail("확장 프로그램의 백그라운드와 연결되지 않았습니다 — 크롬 주소창에 chrome://extensions 를 열어 이 확장 프로그램의 ↻(새로고침)을 누르고, 이 페이지도 새로고침하세요. 계속되면 확장 카드의 '오류' 버튼 내용을 알려주세요." + (le && le.message ? " (" + le.message + ")" : ""));
      });
      sp.postMessage({ type: "search", query: d.query, limit: d.limit });
    }
  });

  post({ type: "ready", version: VER });
})();
