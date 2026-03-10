const CACHE_NAME = "tily-cergy-v7";

// Assets/pages publics sûrs à mettre en cache
const ASSETS = [
  "/",
  "/nous-connaitre",
  "/nous-soutenir",
  "/contact",
  "/espace",
  "/static/css/style.css",
  "/static/manifest.json",
  "/static/sw.js"
];

// Pages dynamiques / privées : toujours réseau d'abord
const NETWORK_FIRST_PATHS = [
  "/actus",
  "/albums"
];

const NETWORK_FIRST_PREFIXES = [
  "/album",
  "/admin",
  "/staff"
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

  // On ne gère que les requêtes du même domaine
  if (url.origin !== self.location.origin) return;

  const isNetworkFirstPath = NETWORK_FIRST_PATHS.includes(url.pathname);
  const isNetworkFirstPrefix = NETWORK_FIRST_PREFIXES.some((prefix) => url.pathname.startsWith(prefix));

  // Pages dynamiques / privées : réseau d'abord, fallback cache
  if (isNetworkFirstPath || isNetworkFirstPrefix) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (req.method === "GET") {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
          }
          return res;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match("/")))
    );
    return;
  }

  // Navigation sur pages publiques : cache puis mise à jour en arrière-plan
  if (req.mode === "navigate") {
    event.respondWith(
      caches.match(req).then((cached) => {
        const fetchPromise = fetch(req)
          .then((res) => {
            if (req.method === "GET") {
              const copy = res.clone();
              caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
            }
            return res;
          })
          .catch(() => cached || caches.match("/"));

        return cached || fetchPromise;
      })
    );
    return;
  }

  // Fichiers statiques : cache first puis réseau
  event.respondWith(
    caches.match(req).then((cached) =>
      cached ||
      fetch(req).then((res) => {
        if (req.method === "GET") {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
        }
        return res;
      })
    )
  );
});
