// web/sw.js — the STAR:DOM POS service worker (W4).
//
// WHY THIS FILE EXISTS: Flutter 3.47's generated `flutter_service_worker.js` is
// a stub that calls `self.registration.unregister()` on activate, and it does
// no caching at all. A booth iPad that loses Wi-Fi and reloads would therefore
// show the browser's offline error instead of the POS. This worker replaces it:
// `flutter_bootstrap.js`'s serviceWorkerSettings is neutralised at build time
// (scripts/build-web.js) so Flutter's stub is never registered.
//
// TWO RULES:
//   1. Cache the app shell: entry point, engine (main.dart.js + canvaskit),
//      the sqlite3 wasm + drift worker, fonts, logo, placeholder and icons.
//      Everything is same-origin — the build uses --no-web-resources-cdn — so
//      a cold start with no network still boots the app.
//   2. NEVER cache the backend. Supabase REST/Storage/Auth responses are
//      cross-origin and hold live data; caching them would serve stale sales
//      data and could hand a stale signed URL to an image request. They are
//      passed straight through to the network, and the app's own local
//      database is the offline source of truth.

const VERSION = 'stardom-pos-v1';
const CACHE = `${VERSION}:shell`;

// Same-origin URLs the app cannot start without. Cached tolerantly: a path that
// 404s (an optional engine file) must not fail the whole install, which would
// leave the app with NO offline cache at all.
//
// The list between the two BUILD_SHELL markers is REPLACED at build time by
// scripts/build-web.js with every file the build actually emitted (the engine
// fetches e.g. canvaskit/chromium/canvaskit.wasm, which a hand-written list got
// wrong once already). The list below is only the hand-serve fallback.
// BUILD_SHELL_START
const SHELL = [
  './',
  'index.html',
  'main.dart.js',
  'flutter.js',
  'flutter_bootstrap.js',
  'manifest.json',
  'version.json',
  'sqlite3.wasm',
  'drift_worker.js',
  'icons/Icon-180.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
  'favicon.png',
  'assets/FontManifest.json',
  'assets/AssetManifest.bin.json',
  'assets/assets/fonts/Sora.ttf',
  'assets/assets/fonts/PlusJakartaSans.ttf',
  'assets/assets/images/stardom-logo.webp',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/fonts/fallback/Roboto-Regular.ttf',
  'assets/packages/material_symbols_icons/lib/fonts/MaterialSymbolsOutlined.ttf',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
];
// BUILD_SHELL_END

/** Never intercepted: the Supabase API, storage and auth. */
const NEVER_CACHE = [/\/rest\/v1\//, /\/storage\/v1\//, /\/auth\/v1\//, /\/realtime\/v1\//];

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      await Promise.all(
        SHELL.map(async (url) => {
          try {
            const res = await fetch(new Request(url, { cache: 'reload' }));
            if (res && res.ok) await cache.put(url, res);
          } catch (e) {
            // Offline install, or an optional file that is not in this build.
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names.filter((n) => n !== CACHE).map((n) => caches.delete(n)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  // Cross-origin (Supabase, anything else) is never touched.
  if (url.origin !== self.location.origin) return;
  if (NEVER_CACHE.some((re) => re.test(url.pathname))) return;

  // The entry point is NETWORK FIRST: a new deploy must be picked up as soon as
  // the app is reopened online. Offline, the cached shell is served instead.
  if (request.mode === 'navigate') {
    event.respondWith(
      (async () => {
        try {
          const fresh = await fetch(request);
          if (fresh && fresh.ok) {
            const cache = await caches.open(CACHE);
            await cache.put('index.html', fresh.clone());
          }
          return fresh;
        } catch (e) {
          const cache = await caches.open(CACHE);
          return (
            (await cache.match('index.html')) ||
            (await cache.match('./')) ||
            new Response('Offline and the app shell was never cached.', {
              status: 503,
              headers: { 'Content-Type': 'text/plain' },
            })
          );
        }
      })(),
    );
    return;
  }

  // Everything else same-origin is CACHE FIRST, with a background refresh so a
  // redeployed asset is picked up on the next load.
  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(request);
      if (hit) {
        event.waitUntil(
          (async () => {
            try {
              const fresh = await fetch(request);
              if (fresh && fresh.ok) await cache.put(request, fresh);
            } catch (e) {
              // Offline: the cached copy is the answer.
            }
          })(),
        );
        return hit;
      }
      try {
        const fresh = await fetch(request);
        if (fresh && fresh.ok && fresh.type === 'basic') {
          await cache.put(request, fresh.clone());
        }
        return fresh;
      } catch (e) {
        return new Response('', { status: 504 });
      }
    })(),
  );
});
