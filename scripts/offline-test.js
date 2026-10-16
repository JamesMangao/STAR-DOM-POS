'use strict';

// scripts/offline-test.js — W4 offline proof, in a REAL browser.
//
//   node scripts/offline-test.js            # Chromium (headless)
//   node scripts/offline-test.js --headed
//
// What it proves, in order:
//   1. build/web serves and the app BOOTS (Flutter engine initialises).
//   2. The boot facts are on screen-side JS: which storage backend drift picked
//      (reported, not assumed) and that the local database opened.
//   3. NOTHING was fetched from a CDN — no gstatic.com, no fonts.googleapis.com,
//      no jsdelivr/unpkg. CanvasKit, the fonts and the wasm are all same-origin.
//   4. After the network is switched OFF and the page RELOADED, the app still
//      boots from the service-worker cache and the database opens again.
//
// Which browser: Playwright's Chromium. WebKit-on-Windows does not reproduce
// iOS Safari's storage engine, so claiming WebKit here would be misleading —
// real-Safari-on-iPad remains UNTESTED (see docs/plan.md).
//
// Exit non-zero on any failed step. Prints its own summary.

const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DIR = path.join(ROOT, 'build', 'web');
const HEADED = process.argv.includes('--headed');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.bin': 'application/octet-stream',
  '.symbols': 'text/plain; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
};

/** Static file server with the MIME types the engine needs (.wasm especially). */
function serve() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    let rel = decodeURIComponent(url.pathname);
    if (rel === '/' || rel === '') rel = '/index.html';
    const file = path.join(DIR, rel);
    if (!file.startsWith(DIR) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
      'Cache-Control': 'no-cache',
      'Service-Worker-Allowed': '/',
    });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

const failures = [];
function check(label, ok, detail = '') {
  console.log(`  ${ok ? 'OK  ' : 'FAIL'} ${label}${detail ? ' — ' + detail : ''}`);
  if (!ok) failures.push(label);
}

async function main() {
  if (!fs.existsSync(path.join(DIR, 'index.html'))) {
    console.error('offline-test: build/web is missing — run scripts/build-web.js first.');
    process.exit(2);
  }
  const { chromium } = require('playwright');
  const { server, port } = await serve();
  const origin = `http://127.0.0.1:${port}`;
  console.log(`offline-test: serving build/web on ${origin} (Chromium${HEADED ? ', headed' : ', headless'})`);

  const browser = await chromium.launch({ headless: !HEADED });
  const context = await browser.newContext();
  const cdnHits = [];
  context.on('request', (r) => {
    const u = r.url();
    if (/gstatic\.com|fonts\.googleapis\.com|jsdelivr|unpkg\.com|cdnjs/.test(u)) cdnHits.push(u);
  });

  const page = await context.newPage();
  const consoleErrors = [];
  const consoleAll = [];
  page.on('console', (m) => {
    consoleAll.push(`${m.type()}: ${m.text()}`);
    if (m.type() === 'error') consoleErrors.push(m.text());
  });
  page.on('pageerror', (e) => {
    // The stack matters here: a Dart exception during boot surfaces as a bare
    // `Error`, and without the stack there is nothing to act on.
    consoleAll.push(`pageerror: ${String(e)}\n      ${String(e.stack || '').slice(0, 900)}`);
    consoleErrors.push(String(e));
  });
  page.on('requestfailed', (r) => {
    consoleAll.push(`requestfailed: ${r.url()}`);
  });
  const requests = [];
  page.on('request', (r) => requests.push(r.url()));

  /** Dump enough state to see WHY a boot check failed. */
  async function diagnose(label) {
    console.log(`\n--- ${label}: diagnostics ---`);
    for (const m of consoleAll.slice(-25)) console.log(`    ${m.slice(0, 300)}`);
    try {
      const state = await page.evaluate(() => ({
        bootInfo: window.__stardomBootInfo || null,
        glass: document.querySelectorAll('flt-glass-pane').length,
        canvases: document.querySelectorAll('canvas').length,
        swController: !!navigator.serviceWorker.controller,
        body: (document.body.innerHTML || '').slice(0, 200),
      }));
      console.log(`    DOM: ${JSON.stringify(state)}`);
      console.log(`    requests: ${requests.length}`);
      for (const u of requests.slice(-15)) console.log(`      ${u.slice(0, 130)}`);
    } catch (e) {
      console.log(`    (page evaluate failed: ${e.message.split('\n')[0]})`);
    }
    console.log('--- end diagnostics ---\n');
  }

  const bootInfo = async () =>
    page.evaluate(() => {
      const raw = window.__stardomBootInfo;
      try {
        return raw ? JSON.parse(raw) : null;
      } catch {
        return null;
      }
    });

  // ---------------------------------------------------------- 1. online boot
  await page.goto(origin + '/', { waitUntil: 'load' });
  try {
    // The Flutter view mounts a glass pane once the engine is up.
    await page.waitForSelector('flt-glass-pane, flutter-view, flt-scene-host', { timeout: 60000 });
    await page.waitForFunction(() => !!window.__stardomBootInfo, null, { timeout: 60000 });
  } catch (e) {
    await diagnose('online boot');
    failures.push(`online boot (${e.message.split('\n')[0]})`);
    await browser.close();
    server.close();
    console.log(`\noffline-test: FAIL (${failures.length}): ${failures.join('; ')}`);
    process.exit(1);
  }
  const online = await bootInfo();
  check('app boots online (Flutter view mounted)', true);
  check(
    'drift reports which storage backend it picked',
    !!(online && online.storageMode),
    online ? `storageMode=${online.storageMode} persistent=${online.persistent}` : 'no boot info',
  );
  check(
    "navigator.storage.persist()'s answer is recorded",
    !!(online && typeof online.storagePersisted === 'string'),
    online ? `storagePersisted=${online.storagePersisted}` : '',
  );
  check('zero CDN requests while online', cdnHits.length === 0, cdnHits.slice(0, 3).join(' '));

  // The service worker must be the one we wrote, installed and activated.
  const swReady = await page.evaluate(async () => {
    const reg = await navigator.serviceWorker.getRegistration();
    return !!(reg && (reg.active || reg.waiting || reg.installing));
  });
  check('our service worker is registered', swReady);

  // Let the worker finish precaching the shell.
  await page.waitForTimeout(4000);

  // --------------------------------------------------------- 2. offline boot
  await context.setOffline(true);
  let offlineOk = true;
  try {
    await page.reload({ waitUntil: 'load', timeout: 60000 });
    await page.waitForSelector('flt-glass-pane, flutter-view, flt-scene-host', { timeout: 60000 });
    await page.waitForFunction(() => !!window.__stardomBootInfo, null, { timeout: 60000 });
  } catch (e) {
    offlineOk = false;
    await diagnose('offline reload');
    console.log(`  (offline reload failed: ${e.message.split('\n')[0]})`);
  }
  const offline = offlineOk ? await bootInfo() : null;
  check('app OPENS with the network off (shell served from cache)', offlineOk);
  check(
    'the local database opens offline too (same storage backend)',
    !!(offline && offline.storageMode && offline.storageMode === (online && online.storageMode)),
    offline ? `storageMode=${offline.storageMode}` : 'no boot info',
  );
  check(
    'the outbox state is readable offline (no sale is lost)',
    !!(offline && typeof offline.pendingSales === 'number'),
    offline ? `pendingSales=${offline.pendingSales} imagesCached=${offline.imagesCached}` : '',
  );
  check('zero CDN requests while offline', cdnHits.length === 0, cdnHits.slice(0, 3).join(' '));

  if (consoleErrors.length) {
    console.log('  console errors seen:');
    for (const e of consoleErrors.slice(0, 5)) console.log(`    ${e.slice(0, 200)}`);
  }

  await browser.close();
  server.close();

  console.log(
    failures.length === 0
      ? '\noffline-test: PASS'
      : `\noffline-test: FAIL (${failures.length}): ${failures.join('; ')}`,
  );
  console.log(
    'note: Chromium only. WebKit on Windows is not iOS Safari, so real-Safari-on-iPad is still untested.',
  );
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
