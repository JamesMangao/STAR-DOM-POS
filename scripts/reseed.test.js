// scripts/reseed.test.js — the confirmation gate, the dry run and the stock plan.
//
//   node --test scripts/reseed.test.js
//
// The --execute test uses PIPED stdio on purpose: that is exactly the case an
// agent or a cron job would hit, and it must exit 1 BEFORE any DB connection.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const REF = 'pykhzrpgdszcwvpydebt';

test('--execute with piped stdio exits 1 before any DB work', () => {
  const r = spawnSync(
    process.execPath,
    ['scripts/reseed.js', '--execute', '--ref', REF],
    { cwd: ROOT, encoding: 'utf8' },
  );
  assert.equal(r.status, 1, `must exit 1 (got ${r.status})\n${r.stderr}`);
  assert.match(r.stderr, /requires a real terminal/);
  // The banner, the parsed reset list and the catalogue facts print before
  // the gate (they need no DB). Everything DB-side must be absent.
  assert.match(r.stdout, /reseed\.sql sha256: [0-9a-f]{64}/);
  assert.match(r.stdout, /catalogue sha256:\s+[0-9a-f]{64}/);
  assert.match(r.stdout, /reseed\.sql is the ONLY reset list/);
  assert.ok(!/stores: \d/.test(r.stdout), 'no store listing reached');
  assert.ok(!/reset plan/.test(r.stdout), 'no row counting reached');
  assert.ok(!/stock reset —/.test(r.stdout), 'no stock plan reached');
});

test('--execute with piped stdio prints no DSN material', () => {
  const r = spawnSync(
    process.execPath,
    ['scripts/reseed.js', '--execute', '--ref', REF],
    { cwd: ROOT, encoding: 'utf8' },
  );
  assert.ok(
    !/PGHOST|pooler|password/i.test(r.stdout + r.stderr),
    'no DSN material leaked',
  );
  assert.match(r.stdout, /DRY RUN|EXECUTE/);
});

test('dry run exits 0, prints the plan, the stock targets and the runbook', () => {
  const r = spawnSync(process.execPath, ['scripts/reseed.js'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  assert.equal(
    r.status,
    0,
    `dry run must exit 0 (got ${r.status})\n${r.stderr}`,
  );
  assert.match(r.stdout, /=== reseed\.js — DRY RUN ===/);
  assert.match(r.stdout, /reseed\.sql sha256: [0-9a-f]{64}/);
  assert.match(r.stdout, /reset plan — rows removed:/);
  assert.match(r.stdout, /stock reset — live products: \d+/);
  assert.match(r.stdout, /photo-less mirror: \d+/);
  assert.match(r.stdout, /BOOTH SIDE/);
  assert.match(r.stdout, /CONFIRM RESEED/);
  assert.match(r.stdout, /DRY RUN complete — nothing changed\./);
  assert.ok(
    !/reseed committed/.test(r.stdout),
    'a dry run must never claim a commit',
  );
});

// ---------------------------------------------------------------- helpers

const lib = require('./reseed');

test('normalizeName mirrors NameNorm: trim, collapse, lowercase', () => {
  assert.equal(lib.normalizeName('  PHM  '), 'phm');
  assert.equal(lib.normalizeName('Gay   af'), 'gay af');
  assert.equal(lib.normalizeName('Art Print'), 'art print');
});

test('looseName drops every space, rescuing space-only name drift', () => {
  assert.equal(lib.looseName('Trees (4x6")'), lib.looseName('Trees(4x6")'));
  assert.equal(lib.looseName('Art Print'), lib.looseName('artprint'));
});

test('stockTargets: id match wins, then normalized name, else 0', () => {
  const catalogue = {
    byId: new Map([['id-1', 21]]),
    byName: new Map([['tamaraw', 16]]),
    byLoose: new Map([['trees(4x6")', 5]]),
    raw: { products: [] },
  };
  const plan = lib.stockTargets(catalogue, [
    { id: 'id-1', store_id: 's', name: 'renamed later', stock_quantity: 3 },
    { id: 'other', store_id: 's', name: '  Tamaraw ', stock_quantity: 5 },
    // space-only name drift: `Trees(4x6")` vs the catalogue's `Trees (4x6")`.
    { id: 'z', store_id: 's', name: 'Trees(4x6")', stock_quantity: 5 },
    { id: 'x', store_id: 's', name: 'Owner Original', stock_quantity: 9 },
    { id: 'y', store_id: 's', name: 'Already Right', stock_quantity: 0 },
  ]);
  assert.deepEqual(
    plan.map((p) => [p.target, p.matched, p.changed]),
    [
      [21, true, true], // id match, stock moves 3 -> 21
      [16, true, true], // name match (normalized), 5 -> 16
      [5, true, false], // loose (space-insensitive) match, already there
      [0, false, true], // unknown product, 9 -> 0
      [0, false, false], // unknown product already 0 -> unchanged
    ],
  );
});

test('parseResetList reads exactly the tables reseed.sql deletes', () => {
  const fs = require('fs');
  const sql = fs.readFileSync(
    path.resolve(ROOT, 'supabase', 'reseed', 'reseed.sql'),
    'utf8',
  );
  const list = lib.parseResetList(sql);
  for (const t of [
    'orders',
    'order_items',
    'payments',
    'order_voids',
    'stock_events',
    'day_closes',
    'devices',
    'sync_outbox',
  ]) {
    assert.ok(list.includes(t), `${t} must be in the reset list`);
  }
  assert.ok(!list.includes('products'), 'products rows must never be deleted');
  assert.ok(!list.includes('settings'), 'settings must never be deleted');
  assert.ok(!list.includes('stores'), 'stores must never be deleted');
});
