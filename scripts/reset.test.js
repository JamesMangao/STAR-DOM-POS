// scripts/reset.test.js — A7. The confirmation gate and the dry run.
//
//   node --test scripts/reset.test.js
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
    ['scripts/reset.js', '--execute', '--ref', REF],
    { cwd: ROOT, encoding: 'utf8' },
  );
  assert.equal(r.status, 1, 'must exit 1');
  assert.match(r.stderr, /requires a real terminal/);
  // The banner and the parsed plan are printed before the gate (they need no
  // DB). Everything that WOULD touch the database must be absent.
  assert.match(r.stdout, /reset\.sql sha256: [0-9a-f]{64}/);
  assert.ok(!/export manifest preflight/.test(r.stdout), 'no preflight reached');
  assert.ok(!/website signature/.test(r.stdout), 'no DB query reached');
  assert.ok(!/row counts/.test(r.stdout), 'no row counting reached');
  assert.ok(!/will delete/.test(r.stdout), 'no storage phase reached');
});

test('--execute with piped stdio prints no DB connection attempt', () => {
  const r = spawnSync(
    process.execPath,
    ['scripts/reset.js', '--execute', '--ref', REF],
    { cwd: ROOT, encoding: 'utf8' },
  );
  assert.ok(!/PGHOST|pooler|password/i.test(r.stdout + r.stderr), 'no DSN material leaked');
  assert.match(r.stdout, /DRY RUN|EXECUTE/);
});

test('dry run is unaffected: prints reset.sql sha256 and the website signature', () => {
  const r = spawnSync(process.execPath, ['scripts/reset.js'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, `dry run must exit 0 (got ${r.status})\n${r.stderr}`);
  assert.match(r.stdout, /reset\.sql sha256: [0-9a-f]{64}/);
  assert.match(r.stdout, /reset\.sql is the ONLY drop list/);
  assert.match(r.stdout, /export manifest preflight: OK/);
  assert.match(r.stdout, /website signature: OK/);
  assert.match(r.stdout, /will delete \d+ objects, \d+ bytes from bucket 'assets'/);
  assert.match(r.stdout, /DRY RUN complete — nothing changed\./);
});
