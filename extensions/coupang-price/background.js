// 쿠팡 상품 페이지를 하나씩 백그라운드 탭으로 열어 가격을 읽고 닫음.
// 쿠팡 보안 확인(Access Denied 등)이 뜨면 그 탭을 보여 주고 멈춤 — 자동으로 넘기지 않음.

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 쿠팡 페이지 안에서 실행되는 함수 (2026-10 화면 구조 기준)
//  .sales-price-amount = 쿠팡판매가 → 판매가
//  .final-price-amount = 와우할인 등 최종가 → 현재 할인가
//  할인이 없으면 최종가 칸만 있음 → 판매가 = 할인가 = 최종가
function extractCoupangPrice() {
  const num = (s) => {
    const m = String(s || "").replace(/\s/g, "").match(/\d{1,3}(?:,\d{3})+|\d+/);
    return m ? Number(m[0].replace(/,/g, "")) : null;
  };
  const box = document.querySelector(".price-container") || document;
  const pick = (cls) => {
    const e = box.querySelector(cls) || document.querySelector(cls);
    return e ? num(e.textContent) : null;
  };
  const title = document.title || "";
  const head = (document.body && document.body.innerText || "").slice(0, 600);
  // 쿠팡 접속 차단 화면: "요청하신 페이지의 사용권한이 없습니다" / Access Denied / 보안 확인
  const blocked = /access denied/i.test(title) || /access denied/i.test(head) ||
    /사용권한이\s*(없습니다|제한된)/.test(head) ||
    !!document.querySelector('iframe[src*="captcha" i], [id*="captcha" i], [class*="captcha" i]');
  const u = new URL(location.href);
  return {
    blocked,
    isProduct: /\/v[pm]\/products\/\d+/.test(location.pathname),
    sales: pick(".sales-price-amount"),
    final: pick(".final-price-amount"),
    orig: pick(".original-price-amount"),
    title: title.slice(0, 150),
    host: location.hostname,
    itemId: u.searchParams.get("itemId") || "",
  };
}

function waitComplete(tabId, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => { if (done) return; done = true; chrome.tabs.onUpdated.removeListener(fn); clearTimeout(t); resolve(); };
    const fn = (id, info) => { if (id === tabId && info.status === "complete") finish(); };
    const t = setTimeout(finish, timeoutMs);
    chrome.tabs.onUpdated.addListener(fn);
    chrome.tabs.get(tabId).then((tab) => { if (tab && tab.status === "complete") finish(); }).catch(finish);
  });
}

async function readPrice(url) {
  const tab = await chrome.tabs.create({ url, active: false });
  let keepTab = false;
  try {
    await waitComplete(tab.id, 30000);
    let r = null;
    for (let i = 0; i < 12; i++) {           // 가격이 늦게 그려지면 최대 6초 더 기다림
      try {
        const [inj] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: extractCoupangPrice });
        r = inj && inj.result;
      } catch (err) {
        r = { error: "페이지를 읽지 못했습니다 (" + String(err && err.message || err).slice(0, 80) + ")" };
      }
      if (r && (r.blocked || r.error || r.sales != null || r.final != null)) break;
      await sleep(500);
    }
    if (!r) return { error: "페이지를 읽지 못했습니다" };
    if (r.blocked) { keepTab = true; return { blocked: true, tabId: tab.id, windowId: tab.windowId }; }
    if (r.error) return { error: r.error };
    if (!r.isProduct) return { error: "상품 페이지가 아닌 쿠팡 메인으로 이동했습니다 (판매중지·링크 변경 가능 — 링크를 확인하세요)", title: r.title };
    const want = (url.match(/[?&]itemId=(\d+)/) || [])[1];
    if (want && r.itemId && r.itemId !== want) return { error: "다른 옵션 페이지로 바뀌었습니다 (옵션 품절·판매중지 가능)", title: r.title };
    const sale = r.sales != null ? r.sales : r.final;
    const disc = r.final != null ? r.final : r.sales;
    if (sale == null) return { error: "가격을 찾지 못했습니다 (판매중지·품절 또는 페이지 구조 변경)", title: r.title };
    return { sale_price: sale, discount_price: disc, orig: r.orig, title: r.title };
  } finally {
    if (!keepTab) { try { await chrome.tabs.remove(tab.id); } catch (err) {} }
  }
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "olprice") return;
  let stop = false;
  let running = false;
  port.onDisconnect.addListener(() => { stop = true; });
  const send = (m) => { try { port.postMessage(m); } catch (err) { stop = true; } };

  port.onMessage.addListener(async (m) => {
    if (m.type === "stop") { stop = true; return; }
    if (m.type !== "run" || running) return;
    running = true;
    const jobs = (m.jobs || []).filter((j) => j && /^https:\/\/(www\.|m\.)?coupang\.com\//.test(j.url || ""));
    // 쿠팡에 부담을 주지 않도록 최소 5초 간격
    const delay = Math.min(Math.max(Number(m.delayMs) || 8000, 5000), 60000);
    let ok = 0, fail = 0, failRow = 0;
    send({ type: "start", total: jobs.length });
    for (let i = 0; i < jobs.length; i++) {
      if (stop) break;
      const job = jobs[i];
      send({ type: "progress", index: i, id: job.id });
      let res;
      try { res = await readPrice(job.url); } catch (err) { res = { error: String(err && err.message || err).slice(0, 120) }; }
      if (res.blocked) {
        try { await chrome.tabs.update(res.tabId, { active: true }); await chrome.windows.update(res.windowId, { focused: true }); } catch (err) {}
        send({ type: "stopped", reason: "blocked", index: i, id: job.id, ok, fail });
        running = false;
        return;
      }
      if (res.error) { fail++; failRow++; } else { ok++; failRow = 0; }
      send({ type: "result", index: i, id: job.id, ...res });
      // 연속 3번 실패하면 멈춤 (차단·구조 변경일 수 있으니 계속 열지 않음)
      if (failRow >= 3) {
        send({ type: "stopped", reason: "fails", index: i, id: job.id, ok, fail });
        running = false;
        return;
      }
      if (i < jobs.length - 1 && !stop) await sleep(delay);
    }
    send(stop ? { type: "stopped", reason: "user", ok, fail } : { type: "done", ok, fail });
    running = false;
  });
});
