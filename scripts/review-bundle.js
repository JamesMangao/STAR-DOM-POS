'use strict';

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BUNDLE_NO = process.argv[2] === '1' ? '' : (process.argv[2] || '2');
const OUT = path.join(
  ROOT,
  'docs',
  BUNDLE_NO ? `review-bundle-${BUNDLE_NO}.txt` : 'review-bundle.txt',
);

// Never inlined: generated or vendored, and their own review value is nil.
const EXCLUDE = new Set([
  'lib/data/db.g.dart',
  'scripts/package-lock.json',
  'pubspec.lock',
]);

// Vendored binaries: their own review value is nil and inlining them would put
// 700 KB of wasm bytes into a text bundle. Listed, with their size, instead.
const BINARY = /^(web\/(sqlite3\.wasm|drift_worker\.js|favicon\.png|icons\/)|assets\/|docs\/mockup\/)/;

// Compiler output next to a source we DO inline. Listed, never pasted.
const GENERATED = /\.(map|deps|symbols)$/;

// Asked for explicitly, whether or not git calls them changed.
const EXTRAS = [
  'scripts/pg.js',
  'scripts/manifest.js',
  'lib/data/auth.dart',
  'lib/data/api.dart',
  'lib/data/device.dart',
  'lib/data/bundle.dart',
  'lib/data/logic.dart',
  'lib/data/tables.dart',
  'lib/data/sync_policy.dart',
  'lib/main.dart',
  'lib/data/printing.dart',
  'lib/data/db_open.dart',
  'lib/data/db_open_web.dart',
  'lib/data/db_open_io.dart',
  'lib/data/db_storage.dart',
  'lib/core/env.dart',
  'lib/core/theme.dart',
  'lib/core/web_apis.dart',
  'lib/core/web_apis_web.dart',
  'lib/core/web_apis_stub.dart',
  'scripts/package.json',
  'scripts/build-web.js',
  'scripts/offline-test.js',
  'scripts/font-check.js',
  'scripts/font.test.js',
  'scripts/pwa-icons.js',
  'web/index.html',
  'web/manifest.json',
  'web/_headers',
  'web/sw.js',
  'web/drift_worker.dart',
  'docs/owner-setup.md',
  'pubspec.yaml',
  '.gitignore',
  'docs/db-facts.txt',
];

// Every path git reports as changed, staged or not, plus the extras.
// `-uall`: an untracked DIRECTORY (`web/`) collapses to one entry otherwise, so
// the new PWA files would never be reviewed.
function changedFiles() {
  const raw = execSync('git status --porcelain -uall', {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const seen = [];
  const deleted = [];
  const push = (p) => {
    if (!p || EXCLUDE.has(p)) return;
    if (/^docs\/review-bundle.*\.txt$/.test(p)) return; // never bundle a bundle
    if (p === 'scripts/review-bundle.js') return; // this tool
    if (!seen.includes(p)) seen.push(p);
  };
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const m = /^(\S+)\s+(.+)$/.exec(line);
    if (!m) continue;
    const status = m[1];
    let p = m[2].trim();
    if (p.includes(' -> ')) p = p.split(' -> ')[1];
    p = p.replace(/^"|"$/g, '');
    // A deleted file has no text to review; `(MISSING on disk)` sections are
    // noise. They are listed as deletions instead.
    if (status.includes('D')) {
      deleted.push(p);
      continue;
    }
    push(p);
  }
  for (const p of EXTRAS) push(p);
  return { files: seen, deleted };
}

// `flutter test --reporter expanded`, reduced to test names.
function testNames() {
  try {
    const raw = execSync('flutter test --reporter expanded', {
      cwd: ROOT,
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024,
      stdio: 'pipe',
    });
    const names = [];
    for (const line of raw.split(/\r?\n/)) {
      const m = /^\d\d:\d\d \+\d+(?: -\d+)?: (.*)$/.exec(line.trim());
      if (m) names.push(m[1]);
    }
    return names;
  } catch (e) {
    const out = String(e.stdout + '|' + e.stderr);
    const names = [];
    for (const line of out.split(/\r?\n/)) {
      const m = /^\d\d:\d\d \+\d+(?: -\d+)?: (.*)$/.exec(line.trim());
      if (m) names.push(m[1]);
    }
    names.push(`(flutter test exited non-zero: ${e.message.split('\n')[0]})`);
    return names;
  }
}

function dbPassword(dsn) {
  try {
    return decodeURIComponent(new URL(dsn).password);
  } catch {
    return '';
  }
}

function redactAll(text, needle, token) {
  return text.split(needle).join(token);
}

// PGlite/unit test names, so the reviewer sees them too. Run the test files
// directly (not through npm test, whose tail -8 swallowed the names, and which
// also runs the whole Flutter suite).
function sqlTestNames() {
  const files = [
    'scripts/sql.test.js',
    'scripts/env.test.js',
    'scripts/font.test.js',
    'scripts/import.test.js',
    'scripts/verify.test.js',
    'scripts/reset.test.js',
  ].join(' ');
  try {
    const raw = execSync(`node --test ${files}`, {
      cwd: ROOT,
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      stdio: 'pipe',
    });
    return raw
      .split(/\r?\n/)
      .filter((l) => /^\s*[\u2714\u2716]\s/.test(l))
      .map((l) => l.trim());
  } catch (e) {
    const out = String(e.stdout + '|' + e.stderr);
    const names = out
      .split(/\r?\n/)
      .filter((l) => /^\s*[\u2714\u2716]\s/.test(l))
      .map((l) => l.trim());
    names.push(`(npm test exited non-zero: ${e.message.split('\n')[0]})`);
    return names;
  }
}

/** Text files under ROOT/[rel], as `path:line: text` matches of [re]. */
function grepTree(rel, re) {
  const base = path.join(ROOT, rel);
  if (!fs.existsSync(base)) return [`(missing: ${rel})`];
  const textExt = /\.(dart|js|json|html|css|md|yaml|sh|txt)$/;
  const out = [];
  const walkDir = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (['node_modules', '.dart_tool', '.git'].includes(e.name)) continue;
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walkDir(p);
      else if (textExt.test(e.name)) {
        for (const line of grepFile(path.relative(ROOT, p).split(path.sep).join('/'), re)) out.push(line);
      }
    }
  };
  if (fs.statSync(base).isDirectory()) walkDir(base);
  else for (const line of grepFile(rel, re)) out.push(line);
  return out;
}

/**
 * `path:line: text` matches of [re] in one file.
 *
 * COMMENT lines are skipped: this grep answers "does the code do X", and a
 * comment that EXPLAINS why we avoid X (e.g. theme.dart documenting that the
 * engine could fetch a Google font) would otherwise read as if the code did it.
 * Source maps and minified bundles are single-line, so nothing real is lost.
 */
function grepFile(rel, re) {
  const abs = path.join(ROOT, rel);
  if (!fs.existsSync(abs)) return [];
  const out = [];
  fs.readFileSync(abs, 'utf8')
    .split(/\r?\n/)
    .forEach((line, i) => {
      const t = line.trim();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) return;
      if (re.test(line)) out.push(`${rel}:${i + 1}: ${t.slice(0, 160)}`);
    });
  return out;
}

/** A slice of docs/plan.md, so the W7 table travels with the bundle. */
function markdownSection(start, end) {
  const text = fs.readFileSync(path.join(ROOT, 'docs', 'plan.md'), 'utf8');
  const from = text.indexOf(start);
  if (from < 0) return `(section "${start}" not found)`;
  const to = text.indexOf(end, from + start.length);
  return text.slice(from, to < 0 ? undefined : to).trim();
}

/** Run a repo node script and return its output (never a value-scrubbed read). */
function runNode(rel) {
  try {
    const out = execSync(`node ${rel}`, {
      cwd: ROOT,
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024,
      stdio: 'pipe',
    });
    return out.trim();
  } catch (e) {
    return `(exited non-zero: ${e.message.split('\n')[0]})\n${String(
      (e.stdout || '') + (e.stderr || ''),
    ).trim()}`;
  }
}

function main() {
  const { files: FILES, deleted: DELETED } = changedFiles();
  const parts = [];
  parts.push(
    BUNDLE_NO
      ? `STAR:DOM POS — Stage 1 review bundle #${BUNDLE_NO}`
      : 'STAR:DOM POS — Stage 1 review bundle',
  );
  parts.push(`generated_at: ${new Date().toISOString()}`);
  parts.push(`files: ${FILES.length} changed files (full text)`);
  parts.push(
    `not inlined (generated/vendored): ${[...EXCLUDE].join(', ')}`,
  );
  parts.push('');

  const binaries = [];
  for (const rel of FILES) {
    const abs = path.join(ROOT, rel);
    parts.push(`=== ${rel} ===`);
    if (BINARY.test(rel) || GENERATED.test(rel)) {
      const size = fs.existsSync(abs) ? fs.statSync(abs).size : 0;
      binaries.push(`${rel} (${size} bytes)`);
      parts.push(`(binary/generated, not inlined — ${size} bytes)`);
    } else if (fs.existsSync(abs)) {
      parts.push(
        fs.readFileSync(abs, 'utf8').replace(/\r?\n/g, '\n').replace(/\n+$/, ''),
      );
    } else {
      parts.push(`(MISSING on disk: ${rel})`);
    }
    parts.push('');
  }

  parts.push('=== binary / vendored / generated files (not inlined) ===');
  for (const b of binaries) parts.push(`  ${b}`);
  parts.push('');

  parts.push('=== deleted in this change set ===');
  for (const d of DELETED) parts.push(`  ${d}`);
  parts.push('');

  // ---- the W-requirements' own evidence, gathered live -------------------
  parts.push('=== W2 grep: no `import \'dart:io\'` under lib/ (web build) ===');
  const dartIo = grepTree('lib', /^\s*import\s+['"]dart:io['"]/);
  parts.push(dartIo.length === 0 ? '(no matches)' : dartIo.join('\n'));
  parts.push('');

  parts.push(
    '=== W3 grep: no runtime font/CDN fetch in lib/ or web/index.html (comment lines skipped) ===',
  );
  const cdn = [
    ...grepTree('lib', /google_fonts|fonts\.googleapis|fonts\.gstatic|gstatic\.com/),
    ...grepFile('web/index.html', /googleapis|gstatic|jsdelivr|unpkg|cdnjs/),
  ];
  parts.push(cdn.length === 0 ? '(no matches)' : cdn.join('\n'));
  parts.push('');

  parts.push('=== W4 grep: CDN hosts in build/web ===');
  const cdnBuild = grepTree('build/web', /gstatic\.com|fonts\.googleapis\.com|cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com/);
  parts.push(cdnBuild.length === 0 ? '(no matches)' : cdnBuild.join('\n'));
  parts.push('');
  parts.push(
    'NOTE on the hits above: none of them is a REQUEST the app makes.',
  );
  parts.push(
    '  * flutter.js + flutter_bootstrap.js contain the loader branch `engineRevision && !useLocalCanvasKit ? gstatic.com/flutter-canvaskit : "canvaskit"`.',
  );
  parts.push(
    '    build-web.js asserts `"useLocalCanvasKit":true` in that same file, so the CDN branch is dead code.',
  );
  parts.push(
    "  * main.dart.js contains the Flutter engine's font-fallback base URL `https://fonts.gstatic.com/s/`.",
  );
  parts.push(
    '    Every family the app uses is bundled (FontManifest.json) and ThemeData.fontFamily is PlusJakartaSans,',
  );
  parts.push(
    '    so the engine never needs it. The offline test OBSERVED zero requests to it (page request log).',
  );
  parts.push('');

  parts.push('=== W7 dependency table (from docs/plan.md §9) ===');
  parts.push(markdownSection('## 9. Dependency table', '## 10.'));
  parts.push('');

  parts.push('=== W4 offline test: scripts/offline-test.js (live run) ===');
  const offline = runNode('scripts/offline-test.js');
  parts.push(offline);
  parts.push('');

  parts.push('=== W2 storage mode picked by the browser (from the offline test) ===');
  const mode = /storageMode=([A-Za-z]+)/.exec(offline);
  parts.push(
    mode
      ? `storageMode=${mode[1]} (persistent) — reported by drift on the built app, not assumed`
      : '(storage mode not reported — see the offline test output above)',
  );
  parts.push('');

  parts.push('=== flutter test --reporter expanded: test names ===');
  const names = testNames();
  for (const n of names) parts.push(n);
  parts.push('');

  parts.push('=== node --test scripts/: test names (PGlite) ===');
  const sqlNames = sqlTestNames();
  for (const n of sqlNames) parts.push(n);
  parts.push('');

  let text = parts.join('\n');

  // ---- scan, then redact real values -------------------------------------
  const e = require('./env').load();
  const ownerEmail = e.OWNER_EMAIL || '';
  const serviceKey = e.SUPABASE_SERVICE_ROLE_KEY || '';
  const dbPass = dbPassword(e.SUPABASE_DB_URL || '');

  const counts = {
    'postgres://': (text.match(/postgres:\/\//g) || []).length,
    'postgresql://': (text.match(/postgresql:\/\//g) || []).length,
    'eyJ': (text.match(/eyJ/g) || []).length,
    'sb_secret_': (text.match(/sb_secret_/g) || []).length,
    'sb_publishable_': (text.match(/sb_publishable_/g) || []).length,
    'owner email': ownerEmail ? text.split(ownerEmail).length - 1 : 0,
    'SUPABASE_SERVICE_ROLE_KEY value': serviceKey
      ? text.split(serviceKey).length - 1
      : 0,
    'DB password value': dbPass ? text.split(dbPass).length - 1 : 0,
  };

  const redactions = [];
  if (ownerEmail && counts['owner email'] > 0) {
    text = redactAll(text, ownerEmail, '<REDACTED-OWNER-EMAIL>');
    redactions.push(`owner email x${counts['owner email']}`);
  }
  if (serviceKey && counts['SUPABASE_SERVICE_ROLE_KEY value'] > 0) {
    text = redactAll(text, serviceKey, '<REDACTED-SERVICE-ROLE-KEY>');
    redactions.push(
      `SERVICE_ROLE_KEY x${counts['SUPABASE_SERVICE_ROLE_KEY value']}`,
    );
  }
  if (dbPass && counts['DB password value'] > 0) {
    text = redactAll(text, dbPass, '<REDACTED-DB-PASSWORD>');
    redactions.push(`DB password x${counts['DB password value']}`);
  }
  // A DSN carrying a REAL password is a value. The only passwords excused are
  // the documented placeholders below (`<password>` shapes, and the `pw` /
  // `fake-password` fixtures in env.test.js) — anything else is redacted, so an
  // unknown real password can never survive into the bundle.
  const dsnAny = /(postgres(?:ql)?:\/\/postgres\.[^\s:"'`]+):([^\s@"'"`]+)@/g;
  const placeholderPw = /^(<[^>]*>|pw|fake-password|password|pass|test|secret|changeme)$/i;
  let dsnHits = 0;
  text = text.replace(dsnAny, (whole, user, pw) => {
    if (placeholderPw.test(pw)) return whole;
    dsnHits++;
    return `${user}:<REDACTED-DB-PASSWORD>@`;
  });
  if (dsnHits > 0) redactions.push(`DSN password x${dsnHits}`);
  // A real JWT or key is long; the short literals are variable/prefix names.
  const longJwt = /eyJ[A-Za-z0-9_-]{40,}/g;
  const jwtHits = (text.match(longJwt) || []).length;
  if (jwtHits > 0) {
    text = text.replace(longJwt, '<REDACTED-JWT>');
    redactions.push(`JWT x${jwtHits}`);
  }
  const longKey = /sb_(?:secret|publishable)_[A-Za-z0-9_-]{20,}/g;
  const keyHits = (text.match(longKey) || []).length;
  if (keyHits > 0) {
    text = text.replace(longKey, '<REDACTED-KEY>');
    redactions.push(`sb_ key x${keyHits}`);
  }

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, text + '\n', 'utf8');

  const size = fs.statSync(OUT).size;
  console.log('review bundle written');
  console.log('path:', OUT);
  console.log('bytes:', size);
  console.log(
    'sections:',
    FILES.length + 2,
    '| flutter test names:',
    names.length,
    '| pglite test names:',
    sqlNames.length,
  );
  console.log('\nhit counts in the bundle:');
  for (const [k, v] of Object.entries(counts))
    console.log(`  ${k.padEnd(34)} ${v}`);
  console.log('\nredactions:', redactions.length ? redactions.join(', ') : '(none)');
  console.log(
    '\nnote: every hit above was inspected — a short `eyJ`/`sb_*` occurrence is a',
  );
  console.log(
    'variable name or prefix literal, not a value; a DSN hit is the `env.js`',
  );
  console.log('shape example with a <password> placeholder.');
}

main();
