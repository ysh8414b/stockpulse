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
  const itemId = u.searchParams.get("itemId") || "";

  // 품절 여부 — ① 페이지 데이터의 "itemId":N … "soldOut":true/false ② schema.org Offer availability ③ 구매 버튼 글씨
  let soldOut = null;
  const avail = [];
  let skuItem = "";
  const walk = (o) => {
    if (!o || typeof o !== "object") return;
    if (Array.isArray(o)) { o.forEach(walk); return; }
    if (o["@type"] === "Product" && !skuItem) skuItem = (String(o.sku || "").match(/-(\d+)$/) || [])[1] || "";
    if (o.availability) avail.push({ a: String(o.availability), url: String(o.url || "") });
    for (const k in o) if (k !== "availability") walk(o[k]);
  };
  for (const s of document.querySelectorAll('script[type="application/ld+json"]')) { try { walk(JSON.parse(s.textContent)); } catch (e) {} }
  const curItem = itemId || skuItem;   // 링크에 itemId가 없으면 페이지가 보여 주는 옵션
  if (curItem) {
    const re = new RegExp('\\\\*"itemId\\\\*":' + curItem + '[\\s\\S]{0,800}?\\\\*"soldOut\\\\*":(true|false)');
    for (const s of document.scripts) { const m = (s.textContent || "").match(re); if (m) { soldOut = m[1] === "true"; break; } }
  }
  if (soldOut == null) {
    const hit = avail.find((x) => curItem && x.url.includes(curItem)) || avail[0];
    if (hit) soldOut = /OutOfStock|SoldOut|Discontinued/i.test(hit.a) ? true : /InStock|LimitedAvailability|PreOrder/i.test(hit.a) ? false : null;
  }
  // 구매 버튼 글씨 (추천 상품 칸은 제외)
  const buyText = [...document.querySelectorAll(".prod-buy-footer, .prod-buy-btn")].map((e) => e.innerText || "").join(" ");
  if (soldOut == null && /일시\s*품절|품절(?!\s*임박)|구매\s*불가/.test(buyText)) soldOut = true;
  // 품절임박 N개
  const lm = ((document.querySelector(".product-buy-header") || document.body).innerText || "").match(/품절\s*임박\s*[•·]?\s*(\d+)\s*개/);
  const stockLeft = soldOut ? 0 : lm ? Number(lm[1]) : null;

  // 페이지 데이터의 쿠팡판매가 (화면 칸이 늦게 그려질 때 대비)
  //  "salesPrice":{"displayType":"SALES",…"price":9700 / "nonWowMemberPrice":{"price":9700
  let dataSales = null;
  for (const s of document.scripts) {
    const t = s.textContent || "";
    if (t.indexOf("salesPrice") < 0 && t.indexOf("nonWowMemberPrice") < 0) continue;
    const m = t.match(/\\*"salesPrice\\*":\{\\*"displayType\\*":\\*"SALES[^{}]{0,400}?\\*"price\\*":(\d+)/) ||
      t.match(/\\*"nonWowMemberPrice\\*":\{\\*"price\\*":(\d+)/);
    if (m) { dataSales = Number(m[1]); break; }
  }

  return {
    blocked,
    soldOut, stockLeft,
    dataSales,
    isProduct: /\/v[pm]\/products\/\d+/.test(location.pathname),
    sales: pick(".sales-price-amount"),
    final: pick(".final-price-amount"),
    orig: pick(".original-price-amount"),
    title: title.slice(0, 150),
    host: location.hostname,
    itemId,
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
      // 쿠팡판매가 칸이 와우할인 칸보다 늦게 그려질 수 있어, 최종가만 보이면 3초까지 더 기다림
      if (r && (r.blocked || r.error || r.sales != null || r.soldOut === true)) break;
      if (r && r.final != null && i >= 6) break;
      await sleep(500);
    }
    if (!r) return { error: "페이지를 읽지 못했습니다" };
    if (r.blocked) { keepTab = true; return { blocked: true, tabId: tab.id, windowId: tab.windowId }; }
    if (r.error) return { error: r.error };
    if (!r.isProduct) return { error: "상품 페이지가 아닌 쿠팡 메인으로 이동했습니다 (판매중지·링크 변경 가능 — 링크를 확인하세요)", title: r.title };
    const want = (url.match(/[?&]itemId=(\d+)/) || [])[1];
    if (want && r.itemId && r.itemId !== want) return { error: "다른 옵션 페이지로 바뀌었습니다 (옵션 품절·판매중지 가능)", title: r.title };
    // 판매가: 화면의 쿠팡판매가 → 페이지 데이터의 판매가(최종가 이상일 때만) → 최종가
    const sale = r.sales != null ? r.sales
      : (r.dataSales != null && (r.final == null || r.dataSales >= r.final)) ? r.dataSales
      : r.final;
    const disc = r.final != null ? r.final : r.sales;
    const stock = { sold_out: r.soldOut, stock_left: r.stockLeft };
    if (sale == null) {
      if (r.soldOut === true) return { sale_price: null, discount_price: null, ...stock, title: r.title };   // 품절이라 가격이 안 보임
      return { error: "가격을 찾지 못했습니다 (판매중지·품절 또는 페이지 구조 변경)", title: r.title };
    }
    return { sale_price: sale, discount_price: disc, orig: r.orig, ...stock, title: r.title };
  } finally {
    if (!keepTab) { try { await chrome.tabs.remove(tab.id); } catch (err) {} }
  }
}

// ── 시장조사: 쿠팡 검색 결과 페이지에서 상품 목록 읽기 ──
// 쿠팡 화면 구조가 자주 바뀌므로 특정 클래스에 기대지 않고
// "상품 링크(/vp/products/)를 가진 카드"를 찾아 그 안의 글씨·가격을 읽음
function extractCoupangSearch(limit) {
  const max = Math.min(Math.max(Number(limit) || 36, 1), 72);
  const toNum = (s) => { const m = String(s || "").replace(/\s/g, "").match(/\d{1,3}(?:,\d{3})+|\d+/); return m ? Number(m[0].replace(/,/g, "")) : null; };
  const title = document.title || "";
  const head = (document.body && document.body.innerText || "").slice(0, 600);
  const blocked = /access denied/i.test(title) || /access denied/i.test(head) ||
    /사용권한이\s*(없습니다|제한된)/.test(head) ||
    !!document.querySelector('iframe[src*="captcha" i], [id*="captcha" i], [class*="captcha" i]');
  if (blocked) return { blocked: true };

  const root = document.querySelector('#product-list, #productList, ul[class*="productList" i], ul[class*="ProductList"]') ||
    document.querySelector("main") || document.body;
  const links = [...root.querySelectorAll('a[href*="/vp/products/"]')];
  const cardOf = (a) => {
    // 상품 링크를 감싼 가장 가까운 목록 칸 (li) — 없으면 가격이 들어 있는 조상
    const li = a.closest("li");
    if (li && root.contains(li)) return li;
    let el = a;
    for (let i = 0; i < 6 && el.parentElement && el.parentElement !== root; i++) {
      el = el.parentElement;
      if (/\d[\d,]*\s*원/.test(el.innerText || "")) break;
    }
    return el;
  };
  const leafs = (card) => [...card.querySelectorAll("*")].filter((e) => !e.children.length && (e.textContent || "").trim());

  const seen = new Set();
  const items = [];
  for (const a of links) {
    if (items.length >= max) break;
    let u;
    try { u = new URL(a.getAttribute("href"), location.href); } catch (e) { continue; }
    const pm = u.pathname.match(/\/vp\/products\/(\d+)/);
    if (!pm) continue;
    const productId = pm[1];
    const itemId = u.searchParams.get("itemId") || "";
    const vendorItemId = u.searchParams.get("vendorItemId") || "";
    const key = productId + "|" + itemId;
    if (seen.has(key)) continue;
    const card = cardOf(a);
    const text = (card.innerText || "").replace(/ /g, " ");
    if (!/\d\s*원/.test(text)) continue;   // 가격 없는 링크(리뷰·이미지 등) 제외
    seen.add(key);

    // 상품명
    const nameEl = card.querySelector('[class*="productName" i], [class*="ProductName"], .name, [class*="name" i]');
    const img = card.querySelector("img");
    let name = nameEl ? (nameEl.innerText || nameEl.textContent || "").trim() : "";
    if (!name && img) name = (img.getAttribute("alt") || "").trim();
    if (!name) name = text.split("\n").map((s) => s.trim()).filter((s) => !/원|%|^\(|리뷰|배송|도착/.test(s)).sort((x, y) => y.length - x.length)[0] || "";

    // 가격 후보: "12,800원" 또는 숫자칸 + 옆의 "원"
    const prices = [];
    let rate = null, reviews = null, rating = null;
    for (const e of leafs(card)) {
      const t = e.textContent.replace(/ /g, " ").trim();
      if (/^\d{1,2}\s*%$/.test(t) && rate == null) { rate = Number(t.replace(/\D/g, "")); continue; }
      if (/^\(\s*\d[\d,]*\s*\)$/.test(t) && reviews == null) { reviews = toNum(t); continue; }
      if (/^[0-5](\.\d)?$/.test(t) && rating == null && /rating|star/i.test(e.className + " " + (e.parentElement && e.parentElement.className))) { rating = Number(t); continue; }
      const isPrice = /^[\d,]+\s*원?$/.test(t) || /^[\d,]+\s*원$/.test(t);
      if (!isPrice) continue;
      const v = toNum(t);
      if (v == null || v < 100) continue;
      const ctxEl = e.parentElement && e.parentElement.parentElement ? e.parentElement.parentElement : e.parentElement || e;
      const ctx = (ctxEl.textContent || "").replace(/\s+/g, " ");
      const own = (e.parentElement ? e.parentElement.textContent : t).replace(/\s+/g, "");
      const tt = t.replace(/\s/g, "");
      const at = own.indexOf(tt);
      const before = at >= 0 ? own.slice(Math.max(0, at - 14), at) : "";
      const after = at >= 0 ? own.slice(at + tt.length, at + tt.length + 6) : "";
      let strike = false;
      for (let x = e; x && x !== card; x = x.parentElement) {
        if (/^(DEL|S|STRIKE)$/.test(x.tagName)) { strike = true; break; }
        const td = getComputedStyle(x).textDecorationLine || "";
        if (td.includes("line-through")) { strike = true; break; }
        if (/base-price|basePrice|original|origin-price/i.test(x.className || "")) { strike = true; break; }
      }
      if (!strike && !/원/.test(tt) && !/^원/.test(after)) continue;  // "원"이 붙지 않은 숫자는 가격이 아님 (줄 그은 정상가는 예외)
      if (/당\(?$/.test(before)) continue;                         // 단위가격 "100g당 1,234원"
      if (/(배송비|적립|캐시|최대)\s*$/.test(before) || /^원?\s*(적립|캐시)/.test(after)) continue;
      const fs = parseFloat(getComputedStyle(e).fontSize) || 0;
      // 이 가격에만 해당하는 가장 작은 묶음 (다른 가격이 들어오기 직전까지 위로) — 그 안의 글씨·뱃지로 와우/쿠폰 판단
      let box = e;
      while (box.parentElement && box.parentElement !== card &&
        ((box.parentElement.textContent || "").match(/\d[\d,]*\s*원/g) || []).length <= 1) box = box.parentElement;
      const boxText = (box.textContent || "").replace(/\s+/g, "");
      let wowMark = false;
      for (let x = e; x && x !== card; x = x.parentElement) { if (/wow/i.test(typeof x.className === "string" ? x.className : "")) { wowMark = true; break; } if (x === box) break; }
      const wow = wowMark || /(^|[^켓])와우/.test(boxText) ||
        !!box.querySelector('img[alt*="와우"], img[src*="wow" i], [class*="wow" i]');
      const coupon = /쿠폰/.test(boxText) || /쿠폰/.test(ctx) && !wow;
      prices.push({ v, strike, fs, wow, coupon });
    }
    const live = prices.filter((p) => !p.strike);
    // 가장 큰 글씨의 가격 = 화면에 크게 보이는 판매가 (같은 크기면 먼저 나온 것)
    let main = null;
    for (const p of live) if (!main || p.fs > main.fs + 0.5) main = p;
    // 최종 할인가 = 와우할인가만 인정. 그 외 할인(즉시할인·쿠폰 등)은 무시하고 정상가로 봄
    const wowPrice = live.filter((p) => p.wow).reduce((m, p) => (m == null || p.v < m ? p.v : m), null);
    // 정상가 = 와우가 아닌 판매가 (크게 보이는 가격). 줄 그은 가격은 쿠팡 "기준가"라 쓰지 않음
    const listPrice = prices.filter((p) => p.strike).reduce((m, p) => (m == null || p.v > m ? p.v : m), null);
    const nonWowMax = live.filter((p) => !p.wow).reduce((m, p) => (m == null || p.v > m ? p.v : m), null);
    const base = main && !main.wow ? main.v : nonWowMax != null ? nonWowMax : (main ? main.v : null);
    const salePrice = main ? main.v : null;   // 참고: 화면에 크게 보인 가격
    const finalPrice = wowPrice != null ? wowPrice : base;
    const wowRate = wowPrice != null && base && base > wowPrice ? Math.round((base - wowPrice) / base * 100) : null;
    const couponPrice = live.filter((p) => p.coupon && !p.wow && p !== main).reduce((m, p) => (m == null || p.v < m ? p.v : m), null);

    // 단위가격 "(100g당 1,234원)"
    let unit = null;
    const um = text.replace(/\s+/g, " ").match(/(\d+(?:\.\d+)?)\s*(g|kg|ml|l|개|매|입|장|팩)\s*당\s*([\d,]+)\s*원/i);
    if (um) unit = { amount: Number(um[1]), unit: um[2].toLowerCase(), price: toNum(um[3]) };

    // 배송 뱃지 (로켓배송/로켓프레시/로켓직구/판매자로켓 등)
    let ship = "";
    for (const im of card.querySelectorAll("img[alt]")) { const al = im.getAttribute("alt") || ""; if (/로켓|rocket/i.test(al)) { ship = al.trim(); break; } }
    if (!ship) { const m = text.match(/(로켓프레시|로켓배송|로켓직구|판매자로켓|로켓그로스)/); if (m) ship = m[1]; }
    if (!ship && card.querySelector('[class*="rocket" i], img[src*="rocket" i]')) ship = "로켓";

    const lines = text.split("\n").map((s) => s.trim());
    const ad = lines.some((s) => s === "AD" || s === "광고") || !!card.querySelector('[class*="ad-badge" i], [class*="adMark" i], [class*="AdBadge"]');
    const soldOut = /일시품절|품절(?!\s*임박)/.test(text);   // "품절임박"은 판매 중
    let thumb = img ? (img.getAttribute("src") || img.getAttribute("data-src") || img.getAttribute("data-img-src") || "") : "";
    if (thumb.startsWith("//")) thumb = "https:" + thumb;
    if (thumb.startsWith("data:")) thumb = "";

    items.push({
      rank: items.length + 1, productId, itemId, vendorItemId,
      url: "https://www.coupang.com/vp/products/" + productId + (itemId ? "?itemId=" + itemId + (vendorItemId ? "&vendorItemId=" + vendorItemId : "") : ""),
      name: name.slice(0, 200), thumb: thumb.slice(0, 400),
      price: finalPrice, base, rate: wowRate, shownRate: rate, salePrice, listPrice, wowPrice, couponPrice, unit,
      ship, ad, soldOut, reviews, rating,
    });
  }
  return {
    items, title: title.slice(0, 120), url: location.href,
    sample: items.length ? "" : (root.innerText || "").slice(0, 300),
    linkCount: links.length,
  };
}

async function readSearch(query, limit, page) {
  const q = String(query || "").trim().slice(0, 100);
  if (!q) return { error: "검색어가 없습니다" };
  const pg = Math.min(Math.max(Number(page) || 1, 1), 10);
  const url = "https://www.coupang.com/np/search?q=" + encodeURIComponent(q) + "&channel=user&listSize=" + Math.min(Math.max(Number(limit) || 36, 12), 72) + (pg > 1 ? "&page=" + pg : "");
  const tab = await chrome.tabs.create({ url, active: false });
  let keepTab = false;
  try {
    await waitComplete(tab.id, 30000);
    let r = null;
    for (let i = 0; i < 16; i++) {           // 목록이 늦게 그려지면 최대 8초 더 기다림
      try {
        const [inj] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: extractCoupangSearch, args: [limit] });
        r = inj && inj.result;
      } catch (err) {
        r = { error: "검색 페이지를 읽지 못했습니다 (" + String(err && err.message || err).slice(0, 80) + ")" };
      }
      if (r && (r.blocked || r.error || (r.items && r.items.length >= 4))) break;
      await sleep(500);
    }
    if (!r) return { error: "검색 페이지를 읽지 못했습니다" };
    if (r.blocked) { keepTab = true; try { await chrome.tabs.update(tab.id, { active: true }); await chrome.windows.update(tab.windowId, { focused: true }); } catch (e) {} return { blocked: true }; }
    if (r.error) return { error: r.error };
    if (!r.items || !r.items.length) return { error: "검색 결과에서 상품을 찾지 못했습니다 (결과 없음 또는 쿠팡 화면 구조 변경)", sample: r.sample, linkCount: r.linkCount };
    return { items: r.items, url };
  } finally {
    if (!keepTab) { try { await chrome.tabs.remove(tab.id); } catch (err) {} }
  }
}

let searching = false;
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "olsearch") return;
  let gone = false;
  port.onDisconnect.addListener(() => { gone = true; });
  port.onMessage.addListener(async (m) => {
    if (!m || m.type !== "search") return;
    const reply = (r) => { if (!gone) { try { port.postMessage(r); } catch (err) {} } };
    if (searching) { reply({ error: "이미 검색 중입니다 — 잠시 뒤 다시 누르세요" }); return; }
    searching = true;
    try { reply(await readSearch(m.query, m.limit, m.page)); }
    catch (err) { reply({ error: String(err && err.message || err).slice(0, 120) }); }
    finally { searching = false; }
  });
});

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
