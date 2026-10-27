// scripts/sw-test.js — PWA Service Worker E2E Tests using Playwright (Chromium)
//   node scripts/sw-test.js
'use strict';

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

function sha256Hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// Read web/sw.js template from source
const SW_TEMPLATE = fs.readFileSync(path.join(__dirname, '..', 'web', 'sw.js'), 'utf8');
const INDEX_HTML = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');

function createBuild(filesMap) {
  const required = {};
  const optional = ['favicon.png', 'version.json'];
  for (const [p, content] of Object.entries(filesMap)) {
    if (p === 'sw.js' || p === 'build-manifest.json' || optional.includes(p)) continue;
    required[p] = sha256Hex(Buffer.from(content));
  }
  const lines = Object.entries(required)
    .map(([p, h]) => `${p}:${h}`)
    .sort()
    .join('\n');
  const buildHash = sha256Hex(Buffer.from(lines)).slice(0, 16);

  const manifest = {
    build: buildHash,
    required,
    optional,
  };

  const swCode = SW_TEMPLATE.replace('__BUILD_HASH__', buildHash);

  return {
    buildHash,
    files: {
      ...filesMap,
      'sw.js': swCode,
      'build-manifest.json': JSON.stringify(manifest),
    },
  };
}

// Build A base files
const BASE_FILES_A = {
  'index.html': INDEX_HTML,
  'main.dart.js': '// main.dart.js build A content',
  'flutter.js': '// flutter.js',
  'flutter_bootstrap.js': 'window._flutter = {}; serviceWorkerSettings: null;',
  'sqlite3.wasm': 'WASM_SQLITE3_BYTES_A',
  'drift_worker.js': '// drift_worker.js A',
  'canvaskit.wasm': 'CANVASKIT_BYTES_A',
  'manifest.json': '{"name":"Stardom"}',
  'version.json': '{"version":"1.0.0"}',
  'favicon.png': 'FAVICON_BYTES',
};

const buildA = createBuild(BASE_FILES_A);

// Build B: touch main.dart.js
const BASE_FILES_B = {
  ...BASE_FILES_A,
  'main.dart.js': '// main.dart.js build B updated content',
};
const buildB = createBuild(BASE_FILES_B);

let currentBuild = buildA;
let force500File = null;
let networkDown = false;
let tamperFileContent = null; // for mixed deploy

const server = http.createServer((req, res) => {
  if (networkDown) {
    req.socket.destroy();
    return;
  }
  const u = new URL(req.url, 'http://localhost:8888');
  let pathname = u.pathname.replace(/^\//, '');
  if (!pathname) pathname = 'index.html';

  if (force500File && pathname === force500File) {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end('Internal Server Error simulation');
    return;
  }

  let content = currentBuild.files[pathname];

  if (tamperFileContent && pathname === tamperFileContent.file) {
    content = tamperFileContent.content;
  }

  if (content === undefined) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('404 Not Found');
    return;
  }

  let contentType = 'text/plain';
  if (pathname.endsWith('.html')) contentType = 'text/html';
  else if (pathname.endsWith('.js')) contentType = 'application/javascript';
  else if (pathname.endsWith('.json')) contentType = 'application/json';
  else if (pathname.endsWith('.wasm')) contentType = 'application/wasm';

  res.writeHead(200, { 'Content-Type': contentType });
  res.end(content);
});

// Ask the controlling service worker which build it IS running.
//
// web/sw.js replies to `event.source`, so the answer arrives as a plain
// `message` event on `navigator.serviceWorker` — NOT on a MessageChannel port.
// An earlier revision of this harness waited on port1, which never fires, so it
// timed out every time and fell back to guessing from caches.keys()[0]. That
// guess is wrong whenever two caches coexist (install created the new one,
// activate has not purged the old one yet), which is what broke tests 2/3/5/6.
async function activeBuildFromWorker(page) {
  return page.evaluate(async () => {
    const reg = await navigator.serviceWorker.getRegistration();
    const worker = navigator.serviceWorker.controller || (reg && reg.active);
    if (!worker) return null;
    return await new Promise((resolve) => {
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        navigator.serviceWorker.removeEventListener('message', onMessage);
        resolve(value);
      };
      function onMessage(event) {
        const d = event.data;
        if (d && d.type === 'BUILD') finish(d.build || null);
      }
      navigator.serviceWorker.addEventListener('message', onMessage);
      try {
        worker.postMessage({ type: 'GET_BUILD' });
      } catch (e) {
        finish(null);
        return;
      }
      setTimeout(() => finish(null), 2000);
    });
  });
}

// The active build hash. Prefers the worker's own answer; falls back to
// caches.keys() ONLY when exactly one build cache exists — with several caches
// and no worker answer the active build is genuinely unknown, and returning
// stardom[0] would report a wrong answer as a confident one.
// Drive an update to completion IN ONE page context: wait until the new worker
// is genuinely `installed`, verify it is the build we expect (by asking it),
// post SKIP_WAITING, then wait until IT is the activated worker (its BUILD
// answers on reg.active), which also means its activate handler has purged the
// old cache.
//
// The old sequence was a Node-side waitForFunction on reg.waiting followed by a
// SEPARATE evaluate that posted SKIP_WAITING. When that raced the install, the
// post ran while waiting was still null — 'skipWaiting post: no waiting' — so
// nobody received SKIP_WAITING, B never activated, and every later assertion
// saw build A with two caches present. Doing it in one evaluate removes the
// race instead of papering over it with longer timeouts.
async function applyUpdate(page, targetBuild) {
  return page.evaluate(async ({ target, timeoutMs }) => {
    const ask = (worker) => {
      if (!worker) return Promise.resolve(null);
      return new Promise((resolve) => {
        let settled = false;
        const finish = (value) => {
          if (settled) return;
          settled = true;
          navigator.serviceWorker.removeEventListener('message', onMessage);
          resolve(value);
        };
        function onMessage(event) {
          const d = event.data;
          if (d && d.type === 'BUILD') finish(d.build || null);
        }
        navigator.serviceWorker.addEventListener('message', onMessage);
        try {
          worker.postMessage({ type: 'GET_BUILD' });
        } catch (e) {
          finish(null);
          return;
        }
        setTimeout(() => finish(null), 1000);
      });
    };

    const reg = await navigator.serviceWorker.getRegistration();
    if (!reg) return { ok: false, reason: 'no registration' };

    const deadline = Date.now() + timeoutMs;
    let skipped = false;
    let lastActive = null;
    while (Date.now() < deadline) {
      const waiting = reg.waiting;
      if (waiting && waiting.state === 'installed') {
        const waitingBuild = await ask(waiting);
        if (waitingBuild && waitingBuild !== target) {
          return {
            ok: false,
            reason: `waiting worker is build ${waitingBuild}, expected ${target}`,
          };
        }
        if (!skipped) {
          waiting.postMessage({ type: 'SKIP_WAITING' });
          skipped = true;
        }
      }
      const active = reg.active;
      if (active && active.state === 'activated') {
        lastActive = await ask(active);
        if (lastActive === target) return { ok: true, build: lastActive };
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    return {
      ok: false,
      reason: `timed out (active=${lastActive || 'none'}, waiting=${reg.waiting ? reg.waiting.state : 'none'}, skipped=${skipped})`,
    };
  }, { target: targetBuild, timeoutMs: 10000 });
}

// Wait until the registration has no worker in flight. For a build whose
// install must FAIL (bad hash, 500 on a required file) this is the real signal:
// settled with no `waiting` worker means the browser rejected it, while
// `waiting` means it unexpectedly installed. A fixed sleep cannot tell those
// two apart.
async function waitForInstallSettled(page, timeoutMs = 5000) {
  return page.evaluate(async ({ timeoutMs }) => {
    const reg = await navigator.serviceWorker.getRegistration();
    if (!reg) return { settled: false, waiting: false, reason: 'no registration' };
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (!reg.installing && !reg.waiting) {
        return { settled: true, waiting: false };
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    return {
      settled: !reg.installing && !reg.waiting,
      waiting: !!reg.waiting,
      reason: 'timed out with a worker still in flight',
    };
  }, { timeoutMs });
}

async function activeBuild(page) {
  const fromWorker = await activeBuildFromWorker(page);
  if (fromWorker) return fromWorker;
  const keys = await page.evaluate(() => caches.keys());
  const builds = keys
    .filter(k => k.startsWith('stardom-pos:'))
    .map(k => k.slice('stardom-pos:'.length));
  if (builds.length === 1) return builds[0];
  return null;
}

// The stale-path list from the controlling worker (same event.source reply
// shape as GET_BUILD). Null means the worker did not answer, which is NOT the
// same as "no misses" and must not be treated as a pass.
async function missesFromWorker(page) {
  return page.evaluate(async () => {
    const reg = await navigator.serviceWorker.ready;
    const worker = navigator.serviceWorker.controller || reg.active;
    if (!worker) return null;
    return await new Promise((resolve) => {
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        navigator.serviceWorker.removeEventListener('message', onMessage);
        resolve(value);
      };
      function onMessage(event) {
        const d = event.data;
        if (d && d.type === 'MISSES') {
          finish(Array.isArray(d.misses) ? d.misses : []);
        }
      }
      navigator.serviceWorker.addEventListener('message', onMessage);
      try {
        worker.postMessage({ type: 'GET_MISSES' });
      } catch (e) {
        finish(null);
        return;
      }
      setTimeout(() => finish(null), 3000);
    });
  });
}

async function runTests() {
  await new Promise((resolve) => server.listen(8888, resolve));
  console.log('SW Test server running on http://localhost:8888');

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  let passed = 0;
  let total = 6;

  try {
    // ------------------------------------------------------------------------
    // Test 1: Build A online -> offline -> reload opens from cache
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 1: Build A online -> offline -> reload');
    await page.goto('http://localhost:8888/index.html');

    // Wait for SW active and controlling the page
    await page.waitForFunction(async () => {
      const reg = await navigator.serviceWorker.ready;
      const c = navigator.serviceWorker.controller;
      return reg.active && reg.active.state === 'activated' && c !== null;
    }, { timeout: 10000 });

    // Check cache name
    const cacheKeysA = await page.evaluate(() => caches.keys());
    const targetCacheA = `stardom-pos:${buildA.buildHash}`;
    console.log(`  Cache keys present: ${cacheKeysA.join(', ')}`);
    if (!cacheKeysA.includes(targetCacheA)) {
      throw new Error(`Expected cache ${targetCacheA} not found`);
    }

    // Check MISSES — a real answer from the worker, or "unknown". The old
    // port-based wait always timed out into [], which made this check pass
    // trivially without proving anything.
    let missesA = null;
    try {
      missesA = await missesFromWorker(page);
    } catch (e) {
      missesA = null;
    }
    console.log(
      `  MISSES: ${missesA === null ? 'unknown (worker did not answer)' : `[${missesA.join(', ')}]`}`,
    );

    // Go offline & reload
    networkDown = true;
    let netRequests = 0;
    page.on('request', () => netRequests++);

    await page.reload({ waitUntil: 'domcontentloaded', timeout: 10000 });
    await page.waitForSelector('#loading', { timeout: 10000 });
    console.log(`  Reloaded offline successfully. Network requests made: ${netRequests}`);
    if (missesA === null) {
      console.log('  SKIP Test 1: the worker never answered GET_MISSES, so "zero misses" was not proven.');
    } else if (missesA.length === 0 && cacheKeysA.includes(targetCacheA)) {
      console.log('✔ Test 1 PASSED: Build A precached, loaded offline with zero misses.');
      passed++;
    } else {
      console.log(`  SKIP Test 1: stale paths reported by the worker: [${missesA.join(', ')}].`);
    }

    // Release this listener so it does not accumulate across tests.
    page.removeAllListeners('request');

    // ------------------------------------------------------------------------
    // Test 2: Build B update, waiting state, skip waiting -> reload to B
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 2: Build B update & skip waiting');
    networkDown = false;
    currentBuild = buildB;

    // Cache A must still be the live build before we touch the registration.
    const buildBefore = await activeBuild(page);
    console.log(`  Active build before update: ${buildBefore} (expected ${buildA.buildHash})`);

    // Trigger the update, then wait-for-waiting + SKIP_WAITING + activation
    // inside ONE evaluate (applyUpdate) so the skip cannot race the install.
    await page.evaluate(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      await reg.update();
    });
    const applied2 = await applyUpdate(page, buildB.buildHash);

    if (!applied2.ok) {
      console.log(`  SKIP Test 2: update never activated build B — ${applied2.reason}.`);
    } else {
      await page.reload({ waitUntil: 'domcontentloaded', timeout: 10000 });
      await page.waitForSelector('#loading', { timeout: 10000 });

      // The reloaded document should already be controlled by B; poll briefly.
      let buildAfter = await activeBuild(page);
      let cacheKeysB = await page.evaluate(() => caches.keys());
      for (let _try = 0; _try < 10 && buildAfter !== buildB.buildHash; _try++) {
        await page.waitForTimeout(200);
        buildAfter = await activeBuild(page);
        cacheKeysB = await page.evaluate(() => caches.keys());
      }
      console.log(`  Active build after update: ${buildAfter} (expected ${buildB.buildHash})`);
      console.log(`  Caches after update: ${cacheKeysB.join(', ')}`);

      if (buildAfter !== buildB.buildHash) {
        console.log(`  SKIP Test 2: reloaded page not controlled by build B (active ${buildAfter || 'none'}).`);
      } else if (
        buildBefore === buildA.buildHash &&
        !cacheKeysB.includes(`stardom-pos:${buildA.buildHash}`) &&
        cacheKeysB.includes(`stardom-pos:${buildB.buildHash}`)
      ) {
        console.log('✔ Test 2 PASSED: Update to Build B succeeded, old cache deleted.');
        passed++;
      } else {
        console.log('  SKIP Test 2: reached build B, but cache assertion not satisfied.');
      }
    }

    // ------------------------------------------------------------------------
    // Test 3: Build C with 500 on required file -> install rejects, B stays
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 3: Build C with 500 error on required file');
    force500File = 'canvaskit.wasm';
    const buildC = createBuild({
      ...BASE_FILES_B,
      'canvaskit.wasm': 'CANVASKIT_BYTES_C_BROKEN',
    });
    currentBuild = buildC;

    await page.evaluate(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      try {
        await reg.update();
      } catch (e) {}
    });

    // Wait for the install attempt to FINISH instead of sleeping a guessed
    // 500ms: settled + no waiting worker = the browser rejected build C.
    const settle3 = await waitForInstallSettled(page, 5000);
    const buildCAttempt = await activeBuild(page);
    const cacheKeysCAttempt = await page.evaluate(() => caches.keys());
    console.log(`  Active build during/after failed update: ${buildCAttempt}`);
    console.log(`  Caches after failed update: ${cacheKeysCAttempt.join(', ')}`);
    console.log(`  Install settled: ${settle3.settled}, waiting worker: ${settle3.waiting}`);

    force500File = null;

    // Offline reload check: the surviving worker must still serve the shell.
    networkDown = true;
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 10000 });
    await page.waitForSelector('#loading', { timeout: 10000 });
    networkDown = false;

    if (!settle3.settled) {
      console.log(`  SKIP Test 3: install attempt never settled (${settle3.reason || 'unknown'}).`);
    } else if (settle3.waiting) {
      console.log('  SKIP Test 3: the broken build C unexpectedly reached the waiting state — install rejection was NOT proven.');
    } else if (buildCAttempt !== buildB.buildHash) {
      console.log(`  SKIP Test 3: did not confirm build B remained active (active ${buildCAttempt || 'none'}, expected ${buildB.buildHash}).`);
    } else if (
      !cacheKeysCAttempt.includes(`stardom-pos:${buildC.buildHash}`) &&
      cacheKeysCAttempt.includes(`stardom-pos:${buildB.buildHash}`)
    ) {
      console.log('✔ Test 3 PASSED: Failed install rejected, active build remains B.');
      passed++;
    } else {
      console.log('  SKIP Test 3: build B present, but cache assertion not satisfied.');
    }

    // ------------------------------------------------------------------------
    // Test 4: Start update with network off -> no crash, B keeps running
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 4: Update attempt while network is down');
    networkDown = true;
    await page.evaluate(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      try {
        await reg.update();
      } catch (e) {}
    });
    await page.waitForTimeout(300);

    // With the network down there is nothing to install: the attempt must
    // settle with no waiting worker, and B must still be the live build.
    const settle4 = await waitForInstallSettled(page, 2000);
    const buildNetOff = await activeBuild(page);
    networkDown = false;

    if (!settle4.settled) {
      console.log(`  SKIP Test 4: offline update attempt never settled (${settle4.reason || 'unknown'}).`);
    } else if (settle4.waiting) {
      console.log('  SKIP Test 4: a worker reached waiting with the network down — unexpected.');
    } else if (buildNetOff === buildB.buildHash) {
      console.log('✔ Test 4 PASSED: Offline update attempt safely ignored, B keeps running.');
      passed++;
    } else {
      console.log(`  SKIP Test 4: active build changed to ${buildNetOff || 'none'} during the offline attempt.`);
    }

    // ------------------------------------------------------------------------
    // Test 5: Rollback: redeploy A over B -> installs A, after update page is A
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 5: Rollback from B to A');
    currentBuild = buildA;

    // Same atomic update path as Test 2: wait-for-waiting + SKIP_WAITING +
    // confirmation that A is the activated worker, all in one page context.
    await page.evaluate(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      await reg.update();
    });
    const applied5 = await applyUpdate(page, buildA.buildHash);
    let buildRollback = null;
    let cacheKeysRollback = null;
    if (!applied5.ok) {
      console.log(`  SKIP Test 5: rollback never activated build A — ${applied5.reason}.`);
    } else {
      await page.reload({ waitUntil: 'domcontentloaded', timeout: 10000 });
      await page.waitForSelector('#loading', { timeout: 10000 });

      buildRollback = await activeBuild(page);
      cacheKeysRollback = await page.evaluate(() => caches.keys());
      for (let _try = 0; _try < 10 && buildRollback !== buildA.buildHash; _try++) {
        await page.waitForTimeout(200);
        buildRollback = await activeBuild(page);
        cacheKeysRollback = await page.evaluate(() => caches.keys());
      }
    }
    console.log(`  Active build after rollback: ${buildRollback}`);
    console.log(`  Caches after rollback: ${cacheKeysRollback ? cacheKeysRollback.join(', ') : '(not read — update failed)'}`);

    if (buildRollback === null) {
      // already reported above
    } else if (buildRollback !== buildA.buildHash) {
      console.log(`  SKIP Test 5: did not reach build A after rollback (active ${buildRollback || 'none'}, expected ${buildA.buildHash}).`);
    } else if (
      !cacheKeysRollback.includes(`stardom-pos:${buildB.buildHash}`) &&
      cacheKeysRollback.includes(`stardom-pos:${buildA.buildHash}`)
    ) {
      console.log('✔ Test 5 PASSED: Rollback to A succeeded, cache B purged.');
      passed++;
    } else {
      console.log('  SKIP Test 5: reached build A, but cache assertion not satisfied.');
    }

    // ------------------------------------------------------------------------
    // Test 6: Mixed deploy (new sw.js + manifest, old main.dart.js bytes)
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 6: Mixed deploy hash mismatch');
    const buildD = createBuild({
      ...BASE_FILES_A,
      'main.dart.js': '// NEW main.dart.js content for D',
    });
    currentBuild = buildD;
    // Tamper main.dart.js to return OLD content from build A
    tamperFileContent = {
      file: 'main.dart.js',
      content: '// main.dart.js build A content',
    };

    await page.evaluate(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      try {
        await reg.update();
      } catch (e) {}
    });

    // The tampered bytes must make the install REJECT — settled with no waiting
    // worker — not merely "still A after half a second".
    const settle6 = await waitForInstallSettled(page, 5000);

    let buildMixed = await activeBuild(page);
    let cacheKeysMixed = await page.evaluate(() => caches.keys());
    for (let _try = 0; _try < 6 && buildMixed !== buildA.buildHash; _try++) {
      await page.waitForTimeout(200);
      buildMixed = await activeBuild(page);
      cacheKeysMixed = await page.evaluate(() => caches.keys());
    }

    console.log(`  Active build after mixed deploy attempt: ${buildMixed}`);
    console.log(`  Caches after mixed deploy attempt: ${cacheKeysMixed.join(', ')}`);
    console.log(`  Install settled: ${settle6.settled}, waiting worker: ${settle6.waiting}`);

    if (!settle6.settled) {
      console.log(`  SKIP Test 6: install attempt never settled (${settle6.reason || 'unknown'}).`);
    } else if (settle6.waiting) {
      console.log('  SKIP Test 6: the hash-mismatched build D unexpectedly reached waiting — rejection was NOT proven.');
    } else if (buildMixed !== buildA.buildHash) {
      console.log(`  SKIP Test 6: did not stay on build A after mixed deploy (active ${buildMixed || 'none'}, expected ${buildA.buildHash}).`);
    } else if (
      !cacheKeysMixed.includes(`stardom-pos:${buildD.buildHash}`) &&
      cacheKeysMixed.includes(`stardom-pos:${buildA.buildHash}`)
    ) {
      console.log('✔ Test 6 PASSED: Mixed deploy rejected on sha256 mismatch, old worker stays.');
      passed++;
    } else {
      console.log('  SKIP Test 6: stayed on build A, but cache assertion not satisfied (may be a timing artifact on this run).');
    }

  } finally {
    await browser.close();
    server.close();
  }

  console.log(`\nSW Test Suite finished: ${passed}/${total} passed.`);
  process.exit(passed === total ? 0 : 1);
}

runTests().catch((e) => {
  console.error('SW Test Suite failed with error:', e);
  process.exit(1);
});