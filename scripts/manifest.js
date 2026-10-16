// scripts/manifest.js — the export manifest (counts + sha256 of every export
// file). export.js writes it; reset.js and verify.js refuse to proceed if it
// is missing or does not match the files on disk.
//
// Every function takes an optional directory so an alternate export root
// (e.g. supabase/export-new) can be checked before it replaces the old one.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const EXPORT_DIR = path.resolve(__dirname, '..', 'supabase', 'export');
const MANIFEST_NAME = 'manifest.json';

const EXPECTED_COUNTS = {
  products: 100,
  categories: 11,
  productimages: 58,
  paymentsettings: 2,
};

const JSON_FILES = ['products', 'categories', 'productimages', 'paymentsettings'];
const QR_FILES = ['qr_gcash.png', 'qr_gotyme.png'];

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function build(dir = EXPORT_DIR, { source = null } = {}) {
  const counts = {};
  const files = {};
  for (const name of JSON_FILES) {
    const p = path.join(dir, `${name}.json`);
    const rows = JSON.parse(fs.readFileSync(p, 'utf8'));
    counts[name] = rows.length;
    files[`${name}.json`] = { bytes: fs.statSync(p).size, sha256: sha256(p) };
  }
  for (const name of QR_FILES) {
    const p = path.join(dir, name);
    if (!fs.existsSync(p)) throw new Error(`missing export file ${name}`);
    files[name] = { bytes: fs.statSync(p).size, sha256: sha256(p) };
  }
  // `source` is a host label only (never a user, password or DSN).
  return { generated_at: new Date().toISOString(), source, counts, files };
}

function write(dir = EXPORT_DIR, opts = {}) {
  const m = build(dir, opts);
  fs.writeFileSync(
    path.join(dir, MANIFEST_NAME),
    JSON.stringify(m, null, 2) + '\n',
    'utf8',
  );
  return m;
}

/** Returns { ok, problems[] } — never throws for a clean refusal. */
function verify(dir = EXPORT_DIR) {
  const problems = [];
  const manifestPath = path.join(dir, MANIFEST_NAME);
  if (!fs.existsSync(manifestPath)) {
    problems.push(`manifest.json missing at ${manifestPath}`);
    return { ok: false, problems };
  }
  const m = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  for (const [k, want] of Object.entries(EXPECTED_COUNTS)) {
    const got = m.counts?.[k];
    if (got !== want) problems.push(`manifest count ${k}: expected ${want}, got ${got}`);
  }
  for (const [name, meta] of Object.entries(m.files || {})) {
    const p = path.join(dir, name);
    if (!fs.existsSync(p)) {
      problems.push(`export file missing: ${name}`);
      continue;
    }
    const bytes = fs.statSync(p).size;
    if (bytes !== meta.bytes) problems.push(`${name}: size ${bytes} != manifest ${meta.bytes}`);
    const h = sha256(p);
    if (h !== meta.sha256) problems.push(`${name}: sha256 ${h} != manifest ${meta.sha256}`);
  }
  for (const name of [...JSON_FILES.map((n) => `${n}.json`), ...QR_FILES]) {
    if (!m.files?.[name]) problems.push(`manifest does not list ${name}`);
  }
  return { ok: problems.length === 0, problems };
}

module.exports = {
  EXPORT_DIR,
  MANIFEST_NAME,
  EXPECTED_COUNTS,
  JSON_FILES,
  QR_FILES,
  sha256,
  build,
  write,
  verify,
};
