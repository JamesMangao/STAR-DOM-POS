// web/sw.js: STAR:DOM POS app-shell cache. One immutable cache per build.
const BUILD = '__BUILD_HASH__'; // replaced by scripts/build-web.js in build/web ONLY (never in source)
const PREFIX = 'stardom-pos:';
const CACHE = PREFIX + BUILD;
const NEVER_CACHE = [/\/rest\/v1\//, /\/storage\/v1\//, /\/auth\/v1\//, /\/realtime\/v1\//];
const MISSES = [];

async function sha256Hex(buf) {
  const d = await crypto.subtle.digest('SHA-256', buf);
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, '0')).join('');
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
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
      throw e; // install fails -> the active worker keeps running
    }
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

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // Supabase etc.: untouched
  if (NEVER_CACHE.some((re) => re.test(url.pathname))) return;
  if (url.pathname.endsWith('/sw.js') || url.pathname.endsWith('/build-manifest.json')) return; // always network
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const hit = await cache.match(req.mode === 'navigate' ? 'index.html' : req, { ignoreSearch: true });
    if (hit) return hit;
    MISSES.push(url.pathname); // a miss = a file missing from build-manifest.json
    try { return await fetch(req); } catch (e) { return new Response('', { status: 504 }); }
  })());
});
