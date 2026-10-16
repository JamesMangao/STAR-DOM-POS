// scripts/apk-secret-scan.js — prove server-only secrets are NOT in the APK.
//
//   node scripts/apk-secret-scan.js [apk] [--require-dart-defines]
//
// Unzips the APK to a temp dir, scans every file's bytes for the
// SUPABASE_SERVICE_ROLE_KEY and the DB password from .env, then deletes the
// temp dir. Prints only a per-secret NAME + hit count — never a value.
//
// Controls, because a "found=0" is worthless if the scanner cannot see inside
// the APK:
//   TIER 1 (always enforced) 'STAR:DOM POS' — a Dart string literal compiled
//          into the APK. It must be found.
//   TIER 2 (--require-dart-defines) the SUPABASE_URL host and OWNER_EMAIL,
//          which arrive via --dart-define. They are only in the APK if app code
//          actually READS Env.* — Dart tree-shakes unused constants, so today's
//          placeholder build has neither. Use this flag for the release build,
//          where those two must be found=1 and the server secrets found=0.
//   SELF-TEST the needle values are planted into a file inside the unzipped
//          tree after the real count; each must then be detected.
//
// Exit 1 if a real secret is found; 2 if a required control or the self-test
// failed (the scan result would be meaningless).
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const env = require('./env');

const args = process.argv.slice(2);
const REQUIRE_DART_DEFINES = args.includes('--require-dart-defines');
const APK =
  args.find((a) => !a.startsWith('--')) ||
  path.resolve(__dirname, '..', 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk');

const TIER1_CONTROL = 'STAR:DOM POS';

function dbPassword(dsn) {
  try {
    return decodeURIComponent(new URL(dsn).password);
  } catch {
    return '';
  }
}

function urlHost(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.isFile()) out.push(p);
  }
  return out;
}

/** Count files whose bytes contain the needle. Values are never printed. */
function countHits(files, needle) {
  const buf = Buffer.from(needle, 'utf8');
  let hits = 0;
  for (const f of files) {
    const data = fs.readFileSync(f);
    if (data.includes(buf)) hits++;
  }
  return hits;
}

async function main() {
  if (!fs.existsSync(APK)) {
    console.error('APK not found:', APK);
    process.exitCode = 2;
    return;
  }
  const e = env.load();
  const needles = [
    ['SUPABASE_SERVICE_ROLE_KEY', e.SUPABASE_SERVICE_ROLE_KEY || ''],
    ['SUPABASE_DB_PASSWORD', dbPassword(e.SUPABASE_DB_URL || '')],
  ].filter(([, v]) => v && v.length >= 8);
  const tier2 = [
    ['SUPABASE_URL host', urlHost(e.SUPABASE_URL || '')],
    ['OWNER_EMAIL', e.OWNER_EMAIL || ''],
  ].filter(([, v]) => v && v.length >= 4);

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'apk-scan-'));
  try {
    execFileSync('unzip', ['-qq', APK, '-d', tmp], { stdio: 'ignore' });
    const files = walk(tmp);

    // ---- real measurement on the untouched APK ----
    let totalHits = 0;
    for (const [name, needle] of needles) {
      const hits = countHits(files, needle);
      totalHits += hits;
      console.log(`${name}: found=${hits}`);
    }
    const tier1 = countHits(files, TIER1_CONTROL);
    console.log(`CONTROL TIER1 (${TIER1_CONTROL}, compiled Dart literal): found=${tier1}`);
    let tier2Ok = true;
    for (const [name, needle] of tier2) {
      const hits = countHits(files, needle);
      if (hits < 1) tier2Ok = false;
      console.log(`CONTROL TIER2 (${name}, dart-define): found=${hits}`);
    }
    if (!tier2Ok && !REQUIRE_DART_DEFINES) {
      console.log(
        'TIER2 note: a 0 here means the app never reads Env.*, so Dart tree-shook those\n' +
          'defines out — a clean secret scan proves NOTHING until the app uses them.\n' +
          'Re-run the RELEASE apk with --require-dart-defines once it does.',
      );
    }
    console.log(`scanned ${files.length} files; real secret hits=${totalHits}`);

    // ---- self-test: plant the needles, the scanner must then see them ----
    const planted = path.join(tmp, 'zz-planted-selftest.bin');
    fs.writeFileSync(planted, Buffer.concat(needles.map(([, v]) => Buffer.from(`x${v}x`))));
    const scannedFiles = [...files, planted];
    let selftestOk = true;
    for (const [name, needle] of needles) {
      const n = countHits(scannedFiles, needle);
      if (n < 1) selftestOk = false;
      console.log(`SELF-TEST ${name} (planted): detected=${n >= 1}`);
    }
    console.log(`SELF-TEST overall: ${selftestOk ? 'OK' : 'FAILED'}`);

    if (tier1 < 1) {
      console.error('TIER1 CONTROL FAILED — the scanner cannot see inside the APK; result is meaningless.');
      process.exitCode = 2;
    } else if (!selftestOk) {
      console.error('SELF-TEST FAILED — a planted secret was not detected; result is meaningless.');
      process.exitCode = 2;
    } else if (REQUIRE_DART_DEFINES && !tier2Ok) {
      console.error('TIER2 CONTROL FAILED — dart-define values are not in the APK; scan cannot prove anything about them.');
      process.exitCode = 2;
    } else if (totalHits > 0) {
      process.exitCode = 1;
    }
  } finally {
    // Runs before exit because we set process.exitCode instead of exiting here.
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error('scan failed:', err.message);
  process.exitCode = 2;
});
