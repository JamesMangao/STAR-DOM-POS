// scripts/env.js — THE one env loader for the POS repo.
//
// Rule: this loads values from <repo>/.env and NOTHING else. It never falls
// back to any other credentials file and never prints a value.
//
// CLI:
//   node scripts/env.js --check             exit 0/2, print missing key NAMES
//   node scripts/env.js --dart-defines      print only the build-whitelisted
//                                           --dart-define=K=V tokens
'use strict';

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..');
const ENV_PATH = path.join(REPO_ROOT, '.env');

// The full set a POS database/import run needs.
const REQUIRED_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'SUPABASE_DB_URL',
  'OWNER_EMAIL',
  'OWNER_PASSWORD',
];

// Only these may ever be compiled into the shipped app (--dart-define).
const DART_DEFINE_WHITELIST = [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'OWNER_EMAIL',
  'OWNER_PASSWORD',
];

// These must NEVER reach the APK.
const NEVER_IN_APP = ['SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_DB_URL'];

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

/** Load, and stop with the missing key NAMES (never values) if any are absent. */
function requireKeys(keys = REQUIRED_KEYS) {
  const env = load();
  const missing = keys.filter((k) => !env[k]);
  if (missing.length) {
    process.stderr.write(
      'MISSING in ' + ENV_PATH + ':\n' +
        missing.map((k) => '  - ' + k).join('\n') +
        '\nCreate D:\\STARDOM-POS\\.env with those key names and try again.\n',
    );
    process.exit(2);
  }
  return env;
}

function dartDefines() {
  const env = load();
  const tokens = [];
  for (const k of DART_DEFINE_WHITELIST) {
    if (env[k]) tokens.push(`--dart-define=${k}=${env[k]}`);
  }
  for (const k of NEVER_IN_APP) {
    if (env[k]) {
      // Defensive: a whitelist entry must never be emitted for these.
      process.stderr.write(`refused to emit --dart-define for ${k}\n`);
      process.exit(3);
    }
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
  if (argv.includes('--dart-defines')) {
    const tokens = dartDefines();
    process.stdout.write(tokens.length ? tokens.join('\n') + '\n' : '');
    return;
  }
  process.stderr.write('usage: node scripts/env.js [--check|--dart-defines]\n');
  process.exit(1);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = {
  REPO_ROOT,
  ENV_PATH,
  REQUIRED_KEYS,
  DART_DEFINE_WHITELIST,
  NEVER_IN_APP,
  load,
  requireKeys,
  dartDefines,
};
