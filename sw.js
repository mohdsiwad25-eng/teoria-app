const CACHE = "teoria-v1";
self.addEventListener("install", e => { self.skipWaiting(); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET") return;
  // صور الإشارات والأيقونات: كاش أولاً (ثابتة)
  if (/\.(png|jpg|jpeg|webp|svg|woff2?)$/.test(url.pathname)) {
    e.respondWith(
      caches.open(CACHE).then(c => c.match(e.request).then(hit =>
        hit || fetch(e.request).then(res => { c.put(e.request, res.clone()); return res; })
      ))
    );
    return;
  }
  // كل الباقي (الصفحة، الداتا، API): الشبكة أولاً — والكاش وقت انقطاع النت بس
  e.respondWith(
    fetch(e.request).then(res => {
      if (url.origin === location.origin && res.ok) {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
      }
      return res;
    }).catch(() => caches.match(e.request))
  );
});
