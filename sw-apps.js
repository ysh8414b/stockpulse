// APS·발주리스트 앱(PWA)용 서비스 워커
// - 사이트 파일(같은 주소): 항상 네트워크 먼저 → 실패하면(오프라인) 저장해 둔 사본
// - CDN 라이브러리(버전 고정 주소): 저장해 둔 사본 먼저 → 없으면 네트워크
// - Supabase·POST·cache:no-store 요청(새 버전 감지)은 건드리지 않음
const CACHE = "sp-apps-v1";
const SHELL = ["aps.html", "orders.html", "shared.js", "style.css",
  "icons/aps-192.png", "icons/orders-192.png"];
const CDN_HOSTS = ["cdnjs.cloudflare.com", "cdn.jsdelivr.net"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE)
    .then((c) => Promise.all(SHELL.map((u) => c.add(u).catch(() => {}))))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((ks) => Promise.all(ks.filter((k) => k.startsWith("sp-apps-") && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

function keep(req, res) {
  if (res && (res.ok || res.type === "opaque")) {
    const copy = res.clone();
    caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
  }
  return res;
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET" || req.cache === "no-store") return;
  const url = new URL(req.url);

  if (url.origin === self.location.origin) {
    e.respondWith(fetch(req).then((res) => keep(req, res)).catch(() =>
      caches.match(req).then((hit) => hit ||
        (req.mode === "navigate" ? caches.match(req, { ignoreSearch: true }) : undefined))
        .then((hit) => hit || Response.error())));
    return;
  }
  if (CDN_HOSTS.includes(url.hostname)) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => keep(req, res))));
  }
});
