// scripts/sw-test.js — PWA Service Worker E2E Tests using Playwright (Chromium)
//
//   node scripts/sw-test.js
//
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
  // Compute required sha256
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

    // Wait for SW active
    await page.waitForFunction(async () => {
      const reg = await navigator.serviceWorker.ready;
      return reg.active && reg.active.state === 'activated';
    });

    // Check cache name & missing count
    const cacheKeysA = await page.evaluate(async () => {
      return await caches.keys();
    });
    const targetCacheA = `stardom-pos:${buildA.buildHash}`;
    console.log(`  Cache keys present: ${cacheKeysA.join(', ')}`);
    if (!cacheKeysA.includes(targetCacheA)) {
      throw new Error(`Expected cache ${targetCacheA} not found`);
    }

    // Check MISSES
    const missesA = await page.evaluate(() => {
      return new Promise((resolve) => {
        const mc = new MessageChannel();
        mc.port1.onmessage = (e) => resolve(e.data.misses);
        navigator.serviceWorker.controller.postMessage({ type: 'GET_MISSES' }, [mc.port2]);
      });
    });
    console.log(`  MISSES: [${missesA.join(', ')}]`);

    // Go offline & reload
    networkDown = true;
    let netRequests = 0;
    page.on('request', () => netRequests++);

    await page.reload();
    await page.waitForSelector('#loading');
    console.log(`  Reloaded offline successfully. Network requests made: ${netRequests}`);
    if (missesA.length === 0 && cacheKeysA.includes(targetCacheA)) {
      console.log('✔ Test 1 PASSED: Build A precached, loaded offline with zero misses.');
      passed++;
    }

    // ------------------------------------------------------------------------
    // Test 2: Build B update, waiting state, stardomApplyUpdate -> reload to B
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 2: Build B update & stardomApplyUpdate');
    networkDown = false;
    currentBuild = buildB;

    // Trigger reg.update()
    await page.evaluate(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      await reg.update();
    });

    // Wait for state waiting
    await page.waitForFunction(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      return reg.waiting !== null;
    });

    // Verify page still reports build A
    const activeBuildBefore = await page.evaluate(() => {
      return new Promise((resolve) => {
        const mc = new MessageChannel();
        mc.port1.onmessage = (e) => resolve(e.data.build);
        navigator.serviceWorker.controller.postMessage({ type: 'GET_BUILD' }, [mc.port2]);
      });
    });
    console.log(`  Active build before update: ${activeBuildBefore} (expected ${buildA.buildHash})`);

    // Apply update via window.stardomApplyUpdate()
    await page.evaluate(() => window.stardomApplyUpdate());
    await page.waitForNavigation();

    // Verify now build B
    const activeBuildAfter = await page.evaluate(() => {
      return new Promise((resolve) => {
        const mc = new MessageChannel();
        mc.port1.onmessage = (e) => resolve(e.data.build);
        navigator.serviceWorker.controller.postMessage({ type: 'GET_BUILD' }, [mc.port2]);
      });
    });
    const cacheKeysB = await page.evaluate(() => caches.keys());
    console.log(`  Active build after update: ${activeBuildAfter} (expected ${buildB.buildHash})`);
    console.log(`  Caches after update: ${cacheKeysB.join(', ')}`);

    if (
      activeBuildBefore === buildA.buildHash &&
      activeBuildAfter === buildB.buildHash &&
      !cacheKeysB.includes(`stardom-pos:${buildA.buildHash}`) &&
      cacheKeysB.includes(`stardom-pos:${buildB.buildHash}`)
    ) {
      console.log('✔ Test 2 PASSED: Update to Build B succeeded, old cache deleted.');
      passed++;
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

    // Give time for SW install attempt
    await page.waitForTimeout(500);

    const activeBuildCAttempt = await page.evaluate(() => {
      return new Promise((resolve) => {
        const mc = new MessageChannel();
        mc.port1.onmessage = (e) => resolve(e.data.build);
        navigator.serviceWorker.controller.postMessage({ type: 'GET_BUILD' }, [mc.port2]);
      });
    });
    const cacheKeysCAttempt = await page.evaluate(() => caches.keys());
    console.log(`  Active build during/after failed update: ${activeBuildCAttempt}`);
    console.log(`  Caches after failed update: ${cacheKeysCAttempt.join(', ')}`);

    force500File = null;

    // Offline reload check
    networkDown = true;
    await page.reload();
    await page.waitForSelector('#loading');
    networkDown = false;

    if (
      activeBuildCAttempt === buildB.buildHash &&
      !cacheKeysCAttempt.includes(`stardom-pos:${buildC.buildHash}`) &&
      cacheKeysCAttempt.includes(`stardom-pos:${buildB.buildHash}`)
    ) {
      console.log('✔ Test 3 PASSED: Failed install rejected, active build remains B.');
      passed++;
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

    const activeBuildNetOff = await page.evaluate(() => {
      return new Promise((resolve) => {
        const mc = new MessageChannel();
        mc.port1.onmessage = (e) => resolve(e.data.build);
        navigator.serviceWorker.controller.postMessage({ type: 'GET_BUILD' }, [mc.port2]);
      });
    });
    networkDown = false;

    if (activeBuildNetOff === buildB.buildHash) {
      console.log('✔ Test 4 PASSED: Offline update attempt safely ignored, B keeps running.');
      passed++;
    }

    // ------------------------------------------------------------------------
    // Test 5: Rollback: redeploy A over B -> installs A, after update page is A
    // ------------------------------------------------------------------------
    console.log('\nRunning Test 5: Rollback from B to A');
    currentBuild = buildA;

    await page.evaluate(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      await reg.update();
    });

    await page.waitForFunction(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      return reg.waiting !== null;
    });

    await page.evaluate(() => window.stardomApplyUpdate());
    await page.waitForNavigation();

    const activeBuildRollback = await page.evaluate(() => {
      return new Promise((resolve) => {
        const mc = new MessageChannel();
        mc.port1.onmessage = (e) => resolve(e.data.build);
        navigator.serviceWorker.controller.postMessage({ type: 'GET_BUILD' }, [mc.port2]);
      });
    });
    const cacheKeysRollback = await page.evaluate(() => caches.keys());
    console.log(`  Active build after rollback: ${activeBuildRollback}`);
    console.log(`  Caches after rollback: ${cacheKeysRollback.join(', ')}`);

    if (
      activeBuildRollback === buildA.buildHash &&
      cacheKeysRollback.includes(`stardom-pos:${buildA.buildHash}`) &&
      !cacheKeysRollback.includes(`stardom-pos:${buildB.buildHash}`)
    ) {
      console.log('✔ Test 5 PASSED: Rollback to A succeeded, cache B purged.');
      passed++;
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

    await page.waitForTimeout(500);

    const activeBuildMixed = await page.evaluate(() => {
      return new Promise((resolve) => {
        const mc = new MessageChannel();
        mc.port1.onmessage = (e) => resolve(e.data.build);
        navigator.serviceWorker.controller.postMessage({ type: 'GET_BUILD' }, [mc.port2]);
      });
    });
    const cacheKeysMixed = await page.evaluate(() => caches.keys());
    console.log(`  Active build after mixed deploy attempt: ${activeBuildMixed}`);
    console.log(`  Caches after mixed deploy attempt: ${cacheKeysMixed.join(', ')}`);

    if (
      activeBuildMixed === buildA.buildHash &&
      !cacheKeysMixed.includes(`stardom-pos:${buildD.buildHash}`)
    ) {
      console.log('✔ Test 6 PASSED: Mixed deploy rejected on sha256 mismatch, old worker stays.');
      passed++;
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
