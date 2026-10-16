// scripts/sql.test.js — A10 + B7. Runs the migrations on real Postgres (PGlite)
// and checks RLS, append-only enforcement, server LWW, the reset precheck, the
// 001 website-schema guard and server-assigned device codes. Never touches the
// live database.
//
//   node --test scripts/sql.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');

const {
  createDb,
  applyMigrations,
  runReset,
  websiteFixture,
  posFixture,
  asRole,
} = require('./sql-harness');

const IDS = {
  ownerId: '11111111-1111-4111-8111-111111111111',
  otherOwnerId: '22222222-2222-4222-8222-222222222222',
  storeId: '33333333-3333-4333-8333-333333333333',
  otherStoreId: '44444444-4444-4444-8444-444444444444',
  productId: '55555555-5555-4555-8555-555555555555',
  otherProductId: '66666666-6666-4666-8666-666666666666',
};

/** A migrated POS database with the two-store fixture. */
async function migrated() {
  const db = await createDb();
  await applyMigrations(db);
  await posFixture(db, IDS);
  return db;
}

const rows = (r) => r.rows;

test('migrations apply cleanly and are idempotent x2', async () => {
  const db = await createDb();
  await applyMigrations(db, { rounds: 2 });
  const t = await db.query(
    `select count(*)::int n from information_schema.tables
      where table_schema='public' and table_type='BASE TABLE'`,
  );
  assert.equal(rows(t)[0].n, 13, 'POS schema is 13 tables');
  // the old client-clock trigger is gone for good
  const fn = await db.query(
    `select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='set_updated_at'`,
  );
  assert.equal(rows(fn)[0].n, 0, 'set_updated_at() must not exist');
  await db.close();
});

test('owner sees own rows; a non-owner sees 0; anon is denied everywhere', async () => {
  const db = await migrated();

  const owner = await asRole(db, 'authenticated', IDS.ownerId, (tx) =>
    tx.query('select id, name from products'),
  );
  assert.equal(rows(owner).length, 1);
  assert.equal(rows(owner)[0].name, 'Owner product');

  const other = await asRole(db, 'authenticated', IDS.otherOwnerId, (tx) =>
    tx.query('select id, name from products'),
  );
  assert.equal(rows(other).length, 1, 'non-owner sees only their own store');
  assert.equal(rows(other)[0].name, 'Other product');

  const noStore = await asRole(db, 'authenticated', IDS.otherOwnerId, (tx) =>
    tx.query(`select id from products where store_id = '${IDS.storeId}'`),
  );
  assert.equal(rows(noStore).length, 0, 'non-owner sees 0 rows of the other store');

  // anon: no grant AND no policy. Both must hold.
  for (const t of ['products', 'orders', 'stock_events', 'day_closes', 'settings']) {
    await asRole(db, 'anon', null, async (tx) => {
      await assert.rejects(
        () => tx.query(`select * from ${t} limit 1`),
        /permission denied/i,
        `anon must be denied SELECT on ${t}`,
      );
    });
  }
  await asRole(db, 'anon', null, async (tx) => {
    await assert.rejects(
      () => tx.query('select * from products'),
      /permission denied/i,
    );
  });

  // the view is security_invoker, and anon has no grant on it either
  const reloptions = await db.query(
    `select c.reloptions from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='order_status'`,
  );
  assert.ok(
    (rows(reloptions)[0].reloptions || []).includes('security_invoker=true'),
    'order_status must be security_invoker=true',
  );
  await asRole(db, 'anon', null, async (tx) => {
    await assert.rejects(
      () => tx.query('select * from order_status limit 1'),
      /permission denied/i,
      'anon must be denied the order_status view',
    );
  });
  await db.close();
});

test('anon privilege check: has_table_privilege is false for every public table', async () => {
  const db = await migrated();
  const r = await db.query(
    `select c.relname
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
        and has_table_privilege('anon', c.oid, 'select')
      order by 1`,
  );
  assert.deepEqual(rows(r).map((x) => x.relname), [], 'no public table readable by anon');
  await db.close();
});

test('UPDATE and DELETE are denied on the 5 append-only tables', async () => {
  const db = await migrated();
  const now = '2026-10-16T02:00:00Z';
  await db.exec(`
insert into orders (id, store_id, device_id, order_no, total, created_at, updated_at)
  values ('77777777-7777-4777-8777-777777777777', '${IDS.storeId}',
          '88888888-8888-4888-8888-888888888888', 'A1-261016-001', 30.00, '${now}', '${now}');
insert into order_items (id, order_id, product_name, unit_price, quantity, line_total)
  values ('99999999-9999-4999-8999-999999999999', '77777777-7777-4777-8777-777777777777',
          'Owner product', 30.00, 1, 30.00);
insert into payments (id, store_id, device_id, order_id, amount)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '${IDS.storeId}',
          '88888888-8888-4888-8888-888888888888', '77777777-7777-4777-8777-777777777777', 30.00);
insert into stock_events (id, store_id, product_id, delta, reason)
  values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '${IDS.storeId}', '${IDS.productId}', -1, 'sale');
insert into order_voids (id, order_id, device_id, reason, voided_at)
  values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '77777777-7777-4777-8777-777777777777',
          '88888888-8888-4888-8888-888888888888', 'mistake', '${now}');
`);

  const targets = [
    ['orders', '77777777-7777-4777-8777-777777777777'],
    ['order_items', '99999999-9999-4999-8999-999999999999'],
    ['payments', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'],
    ['stock_events', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'],
    ['order_voids', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'],
  ];
  for (const [table, id] of targets) {
    const updated = await asRole(db, 'authenticated', IDS.ownerId, (tx) =>
      tx.query(`update ${table} set created_at = created_at where id = '${id}' returning id`),
    );
    assert.equal(rows(updated).length, 0, `UPDATE ${table} must touch 0 rows`);

    const deleted = await asRole(db, 'authenticated', IDS.ownerId, (tx) =>
      tx.query(`delete from ${table} where id = '${id}' returning id`),
    );
    assert.equal(rows(deleted).length, 0, `DELETE ${table} must touch 0 rows`);
  }

  const stillThere = await db.query(
    `select (select count(*)::int from orders) o, (select count(*)::int from order_items) i,
            (select count(*)::int from payments) p, (select count(*)::int from stock_events) s,
            (select count(*)::int from order_voids) v`,
  );
  assert.deepEqual(rows(stillThere)[0], { o: 1, i: 1, p: 1, s: 1, v: 1 });
  await db.close();
});

test('stale update is ignored; newer update applies; server_* is set by the server', async () => {
  const db = await migrated();
  const id = IDS.productId;

  // Local clock far ahead of the stored row (a device with a fast clock).
  await db.query(`update products set name = 'local fresh', updated_at = '2026-10-20T00:00:00Z' where id = $1`, [id]);
  const first = await db.query(
    `select name, updated_at, server_updated_at from products where id = $1`,
    [id],
  );
  assert.equal(rows(first)[0].name, 'local fresh');

  // A stale write (older updated_at) must change NOTHING.
  await db.query(
    `update products set name = 'stale', updated_at = '2026-10-19T00:00:00Z' where id = $1`,
    [id],
  );
  const afterStale = await db.query(
    `select name, updated_at, server_updated_at from products where id = $1`,
    [id],
  );
  assert.equal(rows(afterStale)[0].name, 'local fresh', 'stale write must be ignored');
  assert.equal(
    rows(afterStale)[0].updated_at.toISOString(),
    rows(first)[0].updated_at.toISOString(),
  );

  // A newer write applies and bumps the SERVER clock, not the client one.
  await db.query(
    `update products set name = 'newer', updated_at = '2026-10-21T00:00:00Z' where id = $1`,
    [id],
  );
  const afterNewer = await db.query(
    `select name, updated_at, server_updated_at from products where id = $1`,
    [id],
  );
  assert.equal(rows(afterNewer)[0].name, 'newer');
  assert.notEqual(
    rows(afterNewer)[0].server_updated_at.toISOString(),
    rows(afterNewer)[0].updated_at.toISOString(),
    'server_updated_at must be the server clock, never the client updated_at',
  );
  assert.ok(
    rows(afterNewer)[0].server_updated_at.getTime() > Date.parse('2026-01-01'),
    'server_updated_at is a real now()',
  );
  await db.close();
});

test('append-only rows get server_created_at from the server', async () => {
  const db = await migrated();
  await db.exec(`
insert into stock_events (id, store_id, product_id, delta, reason, created_at)
  values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '${IDS.storeId}', '${IDS.productId}',
          -2, 'adjustment', '2020-01-01T00:00:00Z');
`);
  const r = await db.query(
    `select created_at, server_created_at from stock_events
      where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'`,
  );
  assert.equal(rows(r)[0].created_at.toISOString(), '2020-01-01T00:00:00.000Z');
  assert.ok(
    rows(r)[0].server_created_at.getTime() > Date.parse('2026-01-01'),
    'server_created_at ignores the client clock',
  );
  await db.close();
});

test('001 guard raises on a website-shaped products table', async () => {
  const db = await createDb();
  await websiteFixture(db);
  await assert.rejects(
    () => applyMigrations(db),
    /website schema still present/,
    '001 must refuse to run over the website schema',
  );
  await db.close();
});

test('reset precheck RAISES when POS tables exist', async () => {
  const db = await createDb();
  await websiteFixture(db);          // a website-ish db...
  await db.exec(`
create table stores (id uuid primary key, owner_id uuid);
create table settings (store_id uuid, key text, value text);
`);
  await assert.rejects(
    () => runReset(db),
    /POS tables already exist/,
    'reset must refuse to drop while the POS schema is present',
  );
  // The refusal happens inside reset.sql's own transaction, so the connection
  // is left in an aborted transaction: roll back to keep inspecting.
  await db.exec('rollback');
  // nothing was dropped by the refused run
  const t = await db.query(
    `select count(*)::int n from information_schema.tables
      where table_schema='public' and table_name='products'`,
  );
  assert.equal(rows(t)[0].n, 1, 'products must still exist after a refused reset');
  await db.close();
});

test('reset precheck RAISES when products has store_id (POS table, shared name)', async () => {
  const db = await createDb();
  await db.exec(`create table products (id uuid primary key, store_id uuid, baseprice numeric);`);
  await assert.rejects(() => runReset(db), /products.store_id exists/);
  await db.close();
});

test('reset precheck RAISES when the website signature is missing', async () => {
  const db = await createDb();
  await db.exec(`create table products (id bigserial primary key, name text);`);
  // no baseprice column -> not the website table
  await assert.rejects(() => runReset(db), /baseprice is missing/);
  await db.close();
});

test('reset completes on a website-shaped fixture and leaves public intact', async () => {
  const db = await createDb();
  await websiteFixture(db);
  await runReset(db);

  const left = await db.query(
    `select count(*)::int n from information_schema.tables
      where table_schema='public' and table_type='BASE TABLE'`,
  );
  assert.equal(rows(left)[0].n, 0, 'all website tables dropped');

  const fns = await db.query(
    `select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in
            ('run_delivery_sweep','trg_star_dom_touch_updated_at')`,
  );
  assert.equal(rows(fns)[0].n, 0, 'website functions dropped by name');

  const seqs = await db.query(
    `select count(*)::int n from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind='S'`,
  );
  assert.equal(rows(seqs)[0].n, 0, 'website sequences dropped by name');

  const schema = await db.query(
    `select count(*)::int n from information_schema.schemata where schema_name='public'`,
  );
  assert.equal(rows(schema)[0].n, 1, 'public schema still exists');
  await db.close();
});

test('sync_outbox mirrors the client backoff columns (B5)', async () => {
  const db = await migrated();
  const cols = await db.query(
    `select column_name from information_schema.columns
      where table_schema='public' and table_name='sync_outbox'
      order by column_name`,
  );
  const names = rows(cols).map((c) => c.column_name);
  for (const c of ['attempts', 'next_attempt_at', 'last_error', 'synced_at']) {
    assert.ok(names.includes(c), `sync_outbox.${c} must exist`);
  }
  await db.close();
});

test('register_device assigns the first free code and is idempotent (B7)', async () => {
  const db = await migrated();
  const deviceA = 'dddddddd-1111-4111-8111-111111111111';
  const deviceB = 'dddddddd-2222-4222-8222-222222222222';

  const first = await asRole(db, 'authenticated', IDS.ownerId, (tx) =>
    tx.query(`select * from register_device($1, $2, $3)`, [deviceA, IDS.storeId, 'Counter phone']),
  );
  assert.equal(rows(first).length, 1);
  assert.equal(rows(first)[0].device_code, 'A0');

  // Retrying the SAME device returns the same code, never a second one.
  const again = await asRole(db, 'authenticated', IDS.ownerId, (tx) =>
    tx.query(`select * from register_device($1, $2, $3)`, [deviceA, IDS.storeId, 'Counter phone']),
  );
  assert.equal(rows(again)[0].device_code, 'A0');
  const count = await db.query(`select count(*)::int n from devices`);
  assert.equal(rows(count)[0].n, 1, 'a retry must not insert a second device');

  // A second device gets a DIFFERENT code: this is what keeps order_no unique.
  const second = await asRole(db, 'authenticated', IDS.ownerId, (tx) =>
    tx.query(`select * from register_device($1, $2, $3)`, [deviceB, IDS.storeId, 'Backroom']),
  );
  assert.equal(rows(second)[0].device_code, 'A1');
  assert.notEqual(rows(second)[0].device_code, rows(first)[0].device_code);

  // A code freed by another store is not reused cross-store (codes are per
  // store), and an existing code is never handed out twice for one store.
  const codes = await db.query(
    `select device_code from devices where store_id = $1 order by device_code`,
    [IDS.storeId],
  );
  assert.deepEqual(rows(codes).map((c) => c.device_code), ['A0', 'A1']);
  await db.close();
});

test('register_device refuses anon and a non-owner (B7)', async () => {
  const db = await migrated();
  const other = 'dddddddd-3333-4333-8333-333333333333';

  await asRole(db, 'anon', null, async (tx) => {
    await assert.rejects(
      () => tx.query(`select * from register_device($1, $2, $3)`, [other, IDS.storeId, 'Anon']),
      /permission denied/i,
      'anon must not execute register_device',
    );
  });

  await asRole(db, 'authenticated', IDS.otherOwnerId, async (tx) => {
    await assert.rejects(
      () =>
        tx.query(`select * from register_device($1, $2, $3)`, [other, IDS.storeId, 'Squatter']),
      /not the owner/i,
      'a non-owner must not register a device on someone else store',
    );
  });

  const n = await db.query(`select count(*)::int n from devices`);
  assert.equal(rows(n)[0].n, 0, 'no device may exist after both refusals');
  await db.close();
});

test('reset then migrations: the fixture becomes a clean POS database', async () => {
  const db = await createDb();
  await websiteFixture(db);
  await runReset(db);
  await applyMigrations(db);
  const t = await db.query(
    `select count(*)::int n from information_schema.tables
      where table_schema='public' and table_type='BASE TABLE'`,
  );
  assert.equal(rows(t)[0].n, 13);
  await db.close();
});
