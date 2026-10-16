'use strict';

// scripts/build-web.js — build the PWA and prove it carries no secret (W1/W6).
//
//   node scripts/build-web.js            # build + scan (never deploys)
//   node scripts/build-web.js --scan-only  # re-scan an existing build/web
//
// What it does, in order:
//   1. reads .env through scripts/env.js (the only credential source),
//   2. passes ONLY the two whitelisted --dart-define values to the build,
//   3. builds `flutter build web --release --no-web-resources-cdn`, so
//      CanvasKit, the fonts and every engine asset come from this origin
//      instead of gstatic.com (an offline booth cannot fetch a CDN),
//   4. scans every file in build/web for the two server secrets and for the
//      owner credentials, and requires the SUPABASE_URL host to be PRESENT as
//      a control (a scan that cannot see the defines proves nothing),
//   5. prints the Cloudflare Pages command — and stops there.
//
// It never deploys, never prints a value, and exits non-zero on any hit.

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const env = require('./env');

const ROOT = env.REPO_ROOT;
const OUT = path.join(ROOT, 'build', 'web');
const SCAN_ONLY = process.argv.includes('--scan-only');

/** Every file under [dir], relative to [dir]. */
function walk(dir, acc = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else acc.push(full);
  }
  return acc;
}

/**
 * Count how many of the scanned files contain [needle].
 * Returns { files, hits } — never the matched text.
 */
function countNeedle(files, needle) {
  if (!needle) return { files: 0, hits: 0 };
  let inFiles = 0;
  let hits = 0;
  for (const f of files) {
    let text;
    try {
      text = fs.readFileSync(f, 'utf8');
    } catch {
      continue;
    }
    const n = text.split(needle).length - 1;
    if (n > 0) {
      inFiles++;
      hits += n;
    }
  }
  return { files: inFiles, hits };
}

/**
 * Count REAL keys matching [re] — a prefix on its own is not a value.
 *
 * The SDK's own Dart code contains the literal `sb_secret_` while checking
 * which key style it was handed, so a bare substring search reports a leak in
 * every build. A real new-style key is the prefix PLUS a long payload, so the
 * check requires `{20,}` key characters after it; [maxPayload] is reported so
 * "prefix literal" is evidenced rather than assumed.
 */
function countPattern(files, re) {
  let inFiles = 0;
  let hits = 0;
  let maxPayload = 0;
  for (const f of files) {
    let text;
    try {
      text = fs.readFileSync(f, 'utf8');
    } catch {
      continue;
    }
    const found = text.match(re) || [];
    if (found.length === 0) continue;
    inFiles++;
    hits += found.length;
    for (const m of found) maxPayload = Math.max(maxPayload, m.length - 10);
  }
  return { files: inFiles, hits, maxPayload };
}

/**
 * Replace Flutter's service worker with ours (W4).
 *
 * Flutter 3.47 emits `flutter_service_worker.js` that UNREGISTERS itself on
 * activate and caches nothing, while `flutter_bootstrap.js` still registers it
 * through `serviceWorkerSettings`. Left alone, a booth iPad that reloads while
 * offline gets the browser's offline page, not the POS.
 *
 * So: point `serviceWorkerSettings` at null (the loader then returns without
 * registering anything) and delete the stub. `web/sw.js` is registered by
 * index.html instead, and it is the only worker in the deploy.
 */
function replaceFlutterServiceWorker(buildDir) {
  const bootstrapPath = path.join(buildDir, 'flutter_bootstrap.js');
  const stubPath = path.join(buildDir, 'flutter_service_worker.js');
  const before = fs.readFileSync(bootstrapPath, 'utf8');
  const after = before.replace(
    /serviceWorkerSettings:\s*\{[^}]*\}/g,
    'serviceWorkerSettings: null',
  );
  if (after === before) {
    console.log('build-web: WARNING — serviceWorkerSettings not found in flutter_bootstrap.js');
    return false;
  }
  fs.writeFileSync(bootstrapPath, after);
  fs.rmSync(stubPath, { force: true });
  console.log('build-web: disabled Flutter\'s stub service worker; web/sw.js is the only one.');
  return true;
}

/**
 * Inject the real app-shell file list into build/web/sw.js (W4).
 *
 * The worker has to NAMED-cache everything the engine asks for, and the engine's
 * file set is a build detail (CanvasKit lives under `canvaskit/chromium/` in a
 * Chromium-renderer build, `canvaskit/` otherwise; `skwasm*` and `wimp.wasm`
 * appear only for some compiles). A hand-written list was wrong once already,
 * which offline-revealed as a 504 on the engine's wasm. So the list is derived
 * from the build output: everything except source maps, symbol files and the
 * worker itself.
 *
 * Returns the number of entries injected, or -1 if the markers are missing.
 */
function injectShellList(buildDir) {
  const swPath = path.join(buildDir, 'sw.js');
  const sw = fs.readFileSync(swPath, 'utf8');
  const start = sw.indexOf('// BUILD_SHELL_START');
  const end = sw.indexOf('// BUILD_SHELL_END');
  if (start < 0 || end < 0 || end < start) return -1;

  const skip = /(\.map|\.symbols|\.deps)$/;
  const entries = walk(buildDir)
    .map((f) => path.relative(buildDir, f).split(path.sep).join('/'))
    .filter((rel) => !skip.test(rel) && rel !== 'sw.js' && rel !== 'index.html')
    .sort();

  const list = ['./', 'index.html', ...entries]
    .map((rel) => `  '${rel}',`)
    .join('\n');
  const replacement =
    '// BUILD_SHELL_START\n' +
    '// Generated by scripts/build-web.js from the build output — do not edit.\n' +
    `const SHELL = [\n${list}\n];\n` +
    '// BUILD_SHELL_END';
  fs.writeFileSync(
    swPath,
    sw.slice(0, start) + replacement + sw.slice(end + '// BUILD_SHELL_END'.length),
  );
  return entries.length + 2;
}

function dbPassword(dsn) {
  try {
    return decodeURIComponent(new URL(dsn).password);
  } catch {
    return '';
  }
}

function main() {
  const e = env.load();
  const missing = ['SUPABASE_URL', 'SUPABASE_ANON_KEY'].filter((k) => !e[k]);
  if (missing.length) {
    console.error(`build-web: missing in .env: ${missing.join(', ')}`);
    process.exit(2);
  }

  const tokens = env.dartDefineTokens(e);
  if (!SCAN_ONLY) {
    console.log(
      `build-web: injecting ${tokens.length} whitelisted dart-define(s) (values not shown).`,
    );
    if (tokens.some((t) => /OWNER_(EMAIL|PASSWORD)/.test(t))) {
      console.error('build-web: refusing to build with an owner credential.');
      process.exit(3);
    }
    const args = ['build', 'web', '--release', '--no-web-resources-cdn', ...tokens];
    console.log(`build-web: flutter ${args.filter((a) => !a.startsWith('--dart-define')).join(' ')}`);
    execFileSync('flutter', args, { cwd: ROOT, stdio: 'inherit', shell: true });
  } else if (!fs.existsSync(OUT)) {
    console.error(`build-web: nothing to scan at ${OUT}`);
    process.exit(2);
  }

  if (!fs.existsSync(path.join(OUT, 'index.html'))) {
    console.error(`build-web: ${OUT}/index.html is missing — the build did not produce a web app.`);
    process.exit(2);
  }

  if (!SCAN_ONLY) {
    replaceFlutterServiceWorker(OUT);
    const injected = injectShellList(OUT);
    if (injected < 0) {
      console.log('build-web: WARNING — BUILD_SHELL markers not found in sw.js');
      failed++;
    } else {
      console.log(`build-web: sw.js precache list generated (${injected} entries).`);
    }
  }

  const files = walk(OUT);
  const host = (() => {
    try {
      return new URL(e.SUPABASE_URL).host;
    } catch {
      return '';
    }
  })();

  const checks = [
    // Must be ABSENT: server-only and owner-only values.
    ['SUPABASE_SERVICE_ROLE_KEY', e.SUPABASE_SERVICE_ROLE_KEY || '', false],
    ['DB password', dbPassword(e.SUPABASE_DB_URL || ''), false],
    ['OWNER_EMAIL value', e.OWNER_EMAIL || '', false],
    ['OWNER_PASSWORD value', e.OWNER_PASSWORD || '', false],
    ['postgres:// DSN', 'postgres://', false],
    ['postgresql:// DSN', 'postgresql://', false],
    // Must be PRESENT: proof the scan can actually see the dart-define values.
    ['CONTROL: SUPABASE_URL host', host, true],
  ];

  let failed = 0;
  console.log(`\nbuild-web: scanning ${files.length} files in build/web`);
  for (const [label, needle, required] of checks) {
    if (!needle) {
      console.log(`  ${label.padEnd(28)} (no value in .env — skipped)`);
      continue;
    }
    const { files: n, hits } = countNeedle(files, needle);
    const found = hits > 0;
    const ok = required ? found : !found;
    if (!ok) failed++;
    console.log(
      `  ${label.padEnd(28)} found=${found ? 1 : 0} (files=${n}, hits=${hits}) ` +
        `${ok ? 'OK' : required ? 'MISSING' : 'LEAK'}`,
    );
  }

  // A real new-style secret key, not the SDK's key-style check.
  const secretKey = countPattern(files, /sb_secret_[A-Za-z0-9_-]{20,}/g);
  if (secretKey.hits > 0) failed++;
  console.log(
    `  ${'sb_secret_ key'.padEnd(28)} found=${secretKey.hits > 0 ? 1 : 0} ` +
      `(files=${secretKey.files}, hits=${secretKey.hits}) ` +
      `${secretKey.hits > 0 ? 'LEAK' : 'OK'}`,
  );
  const prefix = countPattern(files, /sb_secret_[A-Za-z0-9_-]*/g);
  console.log(
    `  ${'(info) sb_secret_ literal'.padEnd(28)} hits=${prefix.hits} ` +
      `max payload chars=${prefix.maxPayload} (a prefix literal, not a value)`,
  );

  // ---- offline requirements (W2/W4) --------------------------------------
  const need = [
    'canvaskit/chromium/canvaskit.wasm',
    'canvaskit/canvaskit.wasm',
    'sqlite3.wasm',
    'drift_worker.js',
    'sw.js',
    'manifest.json',
    'assets/assets/fonts/Sora.ttf',
    'assets/assets/fonts/PlusJakartaSans.ttf',
    'assets/assets/images/stardom-logo.webp',
    'icons/Icon-192.png',
    'icons/Icon-512.png',
  ];
  for (const f of need) {
    const there = fs.existsSync(path.join(OUT, f));
    console.log(`  ${f.padEnd(28)} ${there ? 'OK' : 'MISSING'}`);
    if (!there) failed++;
  }

  // Flutter's self-unregistering stub must not be in the deploy...
  const stub = fs.existsSync(path.join(OUT, 'flutter_service_worker.js'));
  console.log(`  ${'flutter SW stub removed'.padEnd(28)} ${stub ? 'STILL PRESENT' : 'OK'}`);
  if (stub) failed++;
  // ...and its registration must be off, or the loader would 404 on it.
  const bootstrapText = fs.readFileSync(path.join(OUT, 'flutter_bootstrap.js'), 'utf8');
  const swOff = /serviceWorkerSettings:\s*null/.test(bootstrapText);
  console.log(`  ${'flutter SW registration off'.padEnd(28)} ${swOff ? 'OK' : 'STILL ON'}`);
  if (!swOff) failed++;
  // CanvasKit must come from this origin: the loader's CDN branch is dead code
  // only when useLocalCanvasKit is true.
  const localCanvasKit = /"useLocalCanvasKit":\s*true/.test(bootstrapText);
  console.log(`  ${'useLocalCanvasKit=true'.padEnd(28)} ${localCanvasKit ? 'OK' : 'NOT SET'}`);
  if (!localCanvasKit) failed++;

  console.log(
    failed === 0
      ? '\nbuild-web: scan OK — no secret, control present.'
      : `\nbuild-web: FAILED with ${failed} problem(s).`,
  );
  console.log('\nDeploy (the USER runs this; this script never does):');
  console.log('  npx wrangler pages deploy build/web --project-name stardom-pos');
  process.exit(failed === 0 ? 0 : 1);
}

main();
