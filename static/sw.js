const CACHE_NAME = "tily-cergy-v2";

// Assets "statiques" (safe à mettre en cache)
const ASSETS = [
  "/",
  "/nous-connaitre",
  "/nous-soutenir",
  "/contact",
  "/static/css/style.css",
  "/static/manifest.json",
  "/static/sw.js"
];

// Pages dynamiques : toujours réseau (sinon actus peut être "ancienne")
const NETWORK_FIRST_PATHS = [
  "/actus"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Only handle same-origin requests
  if (url.origin !== self.location.origin) return;

  // For /actus: network first (fresh content), fallback cache
  if (NETWORK_FIRST_PATHS.includes(url.pathname)) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match("/")))
    );
    return;
  }

  // Navigation (pages) : stale-while-revalidate simple
  if (req.mode === "navigate") {
    event.respondWith(
      caches.match(req).then((cached) => {
        const fetchPromise = fetch(req)
          .then((res) => {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
            return res;
          })
          .catch(() => cached || caches.match("/"));

        return cached || fetchPromise;
      })
    );
    return;
  }

  // Static assets : cache first, then network
  event.respondWith(
    caches.match(req).then((cached) =>
      cached ||
      fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
        return res;
      })
    )
  );
});