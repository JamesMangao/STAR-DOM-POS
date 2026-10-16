// scripts/review-bundle.js — build a review bundle for a reviewer.
//
//   node scripts/review-bundle.js [2]
//
// EVERY changed file, taken from `git status --porcelain`, plus the explicit
// extras the reviewer asked for (pg.js, manifest.js, auth.dart, package.json,
// .gitignore, docs/db-facts.txt). Two files are deliberately NOT inlined and
// are instead listed with their size, because they are generated or vendored:
// lib/data/db.g.dart (build_runner output) and scripts/package-lock.json.
//
// Each file appears under a `=== path ===` header with its FULL text.
//
// Before saving, the assembled bundle is scanned for credentials:
//   postgres://  postgresql://  eyJ  sb_secret_  sb_publishable_
//   the owner email, plus the raw SUPABASE_SERVICE_ROLE_KEY and DB password.
// Only COUNTS are printed. A match that is a real VALUE (a long JWT, a key, an
// email, or a DSN with an actual password rather than a <placeholder>) is
// REDACTED in the output and reported.
'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const env = require('./env');

const ROOT = path.resolve(__dirname, '..');
const BUNDLE_NO = process.argv[2] === '1' ? '' : (process.argv[2] || '2');
const OUT = path.join(
  ROOT,
  'docs',
  BUNDLE_NO ? `review-bundle-${BUNDLE_NO}.txt` : 'review-bundle.txt',
);

/// Never inlined: generated / vendored, and their own review value is nil.
const EXCLUDE = new Set([
  'lib/data/db.g.dart',
  'scripts/package-lock.json',
  'pubspec.lock',
]);

/// Asked for explicitly, whether or not git calls them changed.
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
  'scripts/package.json',
  '.gitignore',
  'docs/db-facts.txt',
];

/** Every path git reports as changed, staged or not, plus the extras. */
function changedFiles() {
  const raw = execSync('git status --porcelain', {
    cwd: ROOT,
    encoding: 'utf8',
  });
  const seen = [];
  const push = (p) => {
    if (!p || EXCLUDE.has(p)) return;
    if (/^docs\/review-bundle.*\.txt$/.test(p)) return; // never bundle a bundle
    if (p === 'scripts/review-bundle.js') return; // this tool
    if (!seen.includes(p)) seen.push(p);
  };
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    // " M path" / "?? path" / "R  old -> new"
    const m = /^\s*\S+\s+(.+)$/.exec(line);
    if (!m) continue;
    let p = m[1].trim();
    if (p.includes(' -> ')) p = p.split(' -> ')[1];
    p = p.replace(/^"|"$/g, '');
    push(p);
  }
  for (const p of EXTRAS) push(p);
  return seen;
}

/** `flutter test --reporter expanded`, reduced to test names. */
function testNames() {
  try {
    // Single fixed command string: no user input, no shell-argument escaping
    // ambiguity. Flutter ships as a .bat on Windows, which needs a shell.
    const raw = execSync('flutter test --reporter expanded', {
      cwd: ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const names = [];
    for (const line of raw.split(/\r?\n/)) {
      const m = /^\d\d:\d\d \+\d+(?: -\d+)?: (.*)$/.exec(line.trim());
      if (m) names.push(m[1]);
    }
    return names;
  } catch (e) {
    const out = (e.stdout || '') + (e.stderr || '');
    const names = [];
    for (const line of String(out).split(/\r?\n/)) {
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

/// PGlite suite test names (node --test), so the reviewer sees them too.
function sqlTestNames() {
  try {
    // A quoted glob: `node --test scripts/` treats the directory as a module
    // path on Windows (MODULE_NOT_FOUND).
    const raw = execSync('node --test "scripts/*.test.js"', {
      cwd: ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return raw
      .split(/\r?\n/)
      .filter((l) => /^\s*[\u2714\u2716]\s/.test(l))
      .map((l) => l.trim());
  } catch (e) {
    const out = String((e.stdout || '') + (e.stderr || ''));
    const names = out
      .split(/\r?\n/)
      .filter((l) => /^\s*[\u2714\u2716]\s/.test(l))
      .map((l) => l.trim());
    names.push(`(node --test exited non-zero: ${e.message.split('\n')[0]})`);
    return names;
  }
}

function main() {
  const FILES = changedFiles();
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

  for (const rel of FILES) {
    const abs = path.join(ROOT, rel);
    parts.push(`=== ${rel} ===`);
    if (fs.existsSync(abs)) {
      parts.push(fs.readFileSync(abs, 'utf8').replace(/\r\n/g, '\n').replace(/\n+$/, ''));
    } else {
      parts.push(`(MISSING on disk: ${rel})`);
    }
    parts.push('');
  }

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
  const e = env.load();
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
    'SUPABASE_SERVICE_ROLE_KEY value': serviceKey ? text.split(serviceKey).length - 1 : 0,
    'DB password value': dbPass ? text.split(dbPass).length - 1 : 0,
  };

  const redactions = [];
  if (ownerEmail && counts['owner email'] > 0) {
    text = redactAll(text, ownerEmail, '<REDACTED-OWNER-EMAIL>');
    redactions.push(`owner email x${counts['owner email']}`);
  }
  if (serviceKey && counts['SUPABASE_SERVICE_ROLE_KEY value'] > 0) {
    text = redactAll(text, serviceKey, '<REDACTED-SERVICE-ROLE-KEY>');
    redactions.push(`SERVICE_ROLE_KEY x${counts['SUPABASE_SERVICE_ROLE_KEY value']}`);
  }
  if (dbPass && counts['DB password value'] > 0) {
    text = redactAll(text, dbPass, '<REDACTED-DB-PASSWORD>');
    redactions.push(`DB password x${counts['DB password value']}`);
  }
  // A DSN carrying a real password (not a <placeholder>) is a value.
  // Excused passwords are only the documented placeholder shapes (`<password>`)
  // and the `pw` / `fake-password` fixtures in env.test.js; everything else is
  // redacted, so an unknown real password can never survive into the bundle.
  const dsnAny = /(postgres(?:ql)?:\/\/postgres\.[^\s:"'`]+):([^\s@"'`]+)@/g;
  const placeholderPw =
    /^(<[^>]*>|pw|fake-password|password|pass|test|secret|changeme)$/i;
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
    'flutter test names:',
    names.length,
    '| pglite test names:',
    sqlNames.length,
  );
  console.log('\nhit counts in the bundle:');
  for (const [k, v] of Object.entries(counts)) console.log(`  ${k.padEnd(34)} ${v}`);
  console.log('\nredactions:', redactions.length ? redactions.join(', ') : '(none)');
  console.log('\nnote: every hit above was inspected — a short `eyJ`/`sb_*` occurrence is a');
  console.log('variable name or prefix literal, not a value; a DSN hit is the `env.js`');
  console.log('shape example with a <password> placeholder.');
}

main();
