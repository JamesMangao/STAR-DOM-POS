// scripts/env.js — THE one env loader for the POS repo.
//
// Rule: this loads values from <repo>/.env and NOTHING else. It never falls
// back to any other credentials file and never prints a VALUE — only key
// names and expected shapes.
//
// CLI:
//   node scripts/env.js --check        exit 0/2, print missing key NAMES
//   node scripts/env.js --validate     exit 0/4, print KEY: expected shape
//   node scripts/env.js --dart-defines print the 4 whitelisted --dart-define tokens
'use strict';

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..');
const ENV_PATH = path.join(REPO_ROOT, '.env');
const PROJECT_REF = 'pykhzrpgdszcwvpydebt';

const REQUIRED_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'SUPABASE_DB_URL',
  'OWNER_EMAIL',
  'OWNER_PASSWORD',
];

const DART_DEFINE_WHITELIST = [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'OWNER_EMAIL',
  'OWNER_PASSWORD',
];
const NEVER_IN_APP = ['SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_DB_URL'];

const DB_EXAMPLE =
  `postgresql://postgres.${PROJECT_REF}:<password>@<host>.pooler.supabase.com:5432/postgres`;

const SHAPE = {
  SUPABASE_URL: `https://${PROJECT_REF}.supabase.co`,
  SUPABASE_ANON_KEY: 'a non-empty anon/publishable key',
  SUPABASE_SERVICE_ROLE_KEY: 'a non-empty service-role key (different from the anon key)',
  SUPABASE_DB_URL: DB_EXAMPLE,
  OWNER_EMAIL: 'a valid email address',
  OWNER_PASSWORD: 'at least 16 characters',
};

function parse(text) {
  const out = {};
  for (let line of text.split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (key) out[key] = value;
  }
  return out;
}

/** Load the POS .env. Returns {} when the file is absent. */
function load() {
  if (!fs.existsSync(ENV_PATH)) return {};
  return parse(fs.readFileSync(ENV_PATH, 'utf8'));
}

/** Returns an error string (key-name + expected shape only) or null. */
function dbUrlProblem(v) {
  if (!v) return `required — expected ${DB_EXAMPLE}`;
  const scheme = String(v).split('://')[0].toLowerCase();
  if (scheme !== 'postgres' && scheme !== 'postgresql') {
    return `expected ${DB_EXAMPLE} (scheme "${scheme}" is not a Postgres DSN)`;
  }
  let u;
  try {
    u = new URL(v);
  } catch {
    return `not parseable — expected ${DB_EXAMPLE}`;
  }
  if (decodeURIComponent(u.username) !== `postgres.${PROJECT_REF}`) {
    return `expected user postgres.${PROJECT_REF} — expected ${DB_EXAMPLE}`;
  }
  if (!u.hostname.endsWith('.pooler.supabase.com')) {
    return `expected host *.pooler.supabase.com — expected ${DB_EXAMPLE}`;
  }
  const port = u.port || '';
  if (port === '6543') return `port 6543 (transaction pooler) is not supported — use 5432`;
  if (port !== '5432') return `expected port 5432 — expected ${DB_EXAMPLE}`;
  if (u.pathname.replace(/^\//, '') !== 'postgres') {
    return `expected db "postgres" — expected ${DB_EXAMPLE}`;
  }
  return null;
}

/** Validate all six keys. Returns [[key, message], ...]; empty = OK. */
function validate(env) {
  const problems = [];
  for (const k of REQUIRED_KEYS) {
    if (!env[k]) problems.push([k, `required — expected ${SHAPE[k]}`]);
  }

  if (env.SUPABASE_URL && env.SUPABASE_URL !== `https://${PROJECT_REF}.supabase.co`) {
    problems.push(['SUPABASE_URL', `expected ${SHAPE.SUPABASE_URL}`]);
  }
  if (env.SUPABASE_DB_URL) {
    const p = dbUrlProblem(env.SUPABASE_DB_URL);
    if (p) problems.push(['SUPABASE_DB_URL', p]);
  }
  for (const k of ['SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY']) {
    const v = env[k];
    if (v && /\s/.test(v)) problems.push([k, 'must not contain whitespace']);
  }
  if (
    env.SUPABASE_ANON_KEY &&
    env.SUPABASE_SERVICE_ROLE_KEY &&
    env.SUPABASE_ANON_KEY === env.SUPABASE_SERVICE_ROLE_KEY
  ) {
    problems.push([
      'SUPABASE_ANON_KEY/SUPABASE_SERVICE_ROLE_KEY',
      'must not be identical',
    ]);
  }
  if (env.OWNER_EMAIL && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(env.OWNER_EMAIL)) {
    problems.push(['OWNER_EMAIL', `expected ${SHAPE.OWNER_EMAIL}`]);
  }
  if (env.OWNER_PASSWORD && env.OWNER_PASSWORD.length < 16) {
    problems.push(['OWNER_PASSWORD', `expected ${SHAPE.OWNER_PASSWORD}`]);
  }
  return problems;
}

/** Load, and stop with the missing key NAMES (never values) if any are absent. */
function requireKeys(keys = REQUIRED_KEYS) {
  const env = load();
  const missing = keys.filter((k) => !env[k]);
  if (missing.length) {
    process.stderr.write(
      'MISSING in ' + ENV_PATH + ':\n' +
        missing.map((k) => '  - ' + k).join('\n') + '\n',
    );
    process.exit(2);
  }
  return env;
}

/** Load and shape-validate; print KEY: expected shape and STOP on failure. */
function requireValid(keys = REQUIRED_KEYS) {
  const env = load();
  const problems = validate(env).filter(([k]) => keys.includes(k));
  if (problems.length) {
    process.stderr.write('Invalid .env (' + ENV_PATH + '):\n');
    for (const [k, m] of problems) process.stderr.write(`${k}: ${m}\n`);
    process.exit(4);
  }
  return env;
}

function dartDefines() {
  // Defensive: the whitelist must never contain a server-only key. This
  // checks the CONSTANT, not the .env contents — a complete .env legitimately
  // holds SERVICE_ROLE_KEY and DB_URL, and that must not break the build.
  for (const k of DART_DEFINE_WHITELIST) {
    if (NEVER_IN_APP.includes(k)) {
      process.stderr.write(`refused to emit --dart-define for ${k}\n`);
      process.exit(3);
    }
  }
  const env = load();
  const tokens = [];
  for (const k of DART_DEFINE_WHITELIST) {
    if (env[k]) tokens.push(`--dart-define=${k}=${env[k]}`);
  }
  return tokens;
}

function main(argv) {
  if (argv.includes('--check')) {
    const env = load();
    const missing = REQUIRED_KEYS.filter((k) => !env[k]);
    if (missing.length) {
      process.stdout.write('MISSING_NEW_KEYS\n');
      for (const k of missing) process.stdout.write(k + '\n');
      process.exit(2);
    }
    process.stdout.write('ALL_KEYS_PRESENT\n');
    return;
  }
  if (argv.includes('--validate')) {
    const problems = validate(load());
    if (problems.length) {
      process.stderr.write('INVALID .env (' + ENV_PATH + '):\n');
      for (const [k, m] of problems) process.stderr.write(`${k}: ${m}\n`);
      process.exit(4);
    }
    process.stdout.write('ALL_KEYS_VALID\n');
    return;
  }
  if (argv.includes('--dart-defines')) {
    const tokens = dartDefines();
    process.stdout.write(tokens.length ? tokens.join('\n') + '\n' : '');
    return;
  }
  process.stderr.write('usage: node scripts/env.js [--check|--validate|--dart-defines]\n');
  process.exit(1);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = {
  REPO_ROOT,
  ENV_PATH,
  PROJECT_REF,
  REQUIRED_KEYS,
  DART_DEFINE_WHITELIST,
  NEVER_IN_APP,
  SHAPE,
  DB_EXAMPLE,
  load,
  validate,
  dbUrlProblem,
  requireKeys,
  requireValid,
  dartDefines,
};
