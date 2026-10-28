// web/sw.js: STAR:DOM POS app-shell cache. One immutable cache per build.
const BUILD = '__BUILD_HASH__'; // replaced by scripts/build-web.js in build/web ONLY (never in source)
const PREFIX = 'stardom-pos:';
const CACHE = PREFIX + BUILD;
const NEVER_CACHE = [/\/rest\/v1\//, /\/storage\/v1\//, /\/auth\/v1\//, /\/realtime\/v1/];

async function sha256Hex(buf) {
  const d = await crypto.subtle.digest('SHA-256', buf);
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, '0')).join('');
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    try {
      const mres = await fetch('build-manifest.json', { cache: 'reload' });
      if (!mres.ok) throw new Error('build-manifest.json ' + mres.status);
      const manifest = await mres.json();
      if (manifest.build !== BUILD) throw new Error('build mismatch');
      const cache = await caches.open(CACHE);
      try {
        for (const [path, want] of Object.entries(manifest.required)) {
          const res = await fetch(path, { cache: 'reload' });
          if (!res.ok) throw new Error(path + ' ' + res.status);
          if ((await sha256Hex(await res.clone().arrayBuffer())) !== want) {
            throw new Error(path + ' hash mismatch');
          }
          await cache.put(path, res);
        }
        for (const path of manifest.optional || []) {
          try {
            const res = await fetch(path, { cache: 'reload' });
            if (res.ok) await cache.put(path, res);
          } catch (e) { /* optional files may fail */ }
        }
      } catch (e) {
        await caches.delete(CACHE); // never keep a partial cache
        throw e;
      }
    } catch (_) {
      // Install failed: empty cache is fine — fetch handler falls back to network.
      try { await caches.delete(CACHE); } catch (_) { /* fall through */ }
    }
    self.skipWaiting(); // activate immediately so refreshes pick up the new build
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const n of await caches.keys()) {
      if (n.startsWith(PREFIX) && n !== CACHE) await caches.delete(n);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  const t = event.data && event.data.type;
  if (t === 'SKIP_WAITING') self.skipWaiting();
  if (t === 'GET_BUILD' && event.source) event.source.postMessage({ type: 'BUILD', build: BUILD });
  if (t === 'GET_MISSES' && event.source) event.source.postMessage({ type: 'MISSES', misses: MISSES });
});

const MISSES = [];

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  let url;
  try { url = new URL(req.url); } catch { return; }
  if (url.origin !== self.location.origin) return; // Supabase etc.: untouched
  if (NEVER_CACHE.some((re) => re.test(url.pathname))) return;
  if (url.pathname.endsWith('/sw.js') || url.pathname.endsWith('/build-manifest.json')) return; // always network

  event.respondWith((async () => {
    // NAVIGATION (page refresh): network first so a reload always gets fresh HTML,
    // then fall back to cached shell only when offline.
    if (req.mode === 'navigate') {
      try {
        return await fetch(req);
      } catch (_) {
        try {
          const cache = await caches.open(CACHE);
          const shell = await cache.match('index.html', { ignoreSearch: true });
          if (shell) return shell;
        } catch (_) { /* fall through */ }
      }
    }

    // ASSETS: cache first, then network.
    try {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req, { ignoreSearch: true });
      if (hit) return hit;
    } catch (_) { /* fall through to network */ }

    try {
      return await fetch(req);
    } catch (_) {
      // Truly offline with nothing cached.
      return new Response('', { status: 504, statusText: 'Offline' });
    }
  })());
});
