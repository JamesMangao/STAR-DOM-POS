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
  migrationFiles,
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
  assert.ok(
    migrationFiles().some((f) => f.endsWith('007_missing_columns.sql')),
    'migration 007 must be included in fresh database builds',
  );
  const columns = await db.query(
    `select table_name, column_name, data_type, is_nullable, column_default
       from information_schema.columns
      where table_schema = 'public'
        and ((table_name = 'devices' and column_name = 'persistent_storage')
          or (table_name = 'stores' and column_name = 'synced_at'))
      order by table_name, column_name`,
  );
  assert.deepEqual(rows(columns).map((r) => [r.table_name, r.column_name]), [
    ['devices', 'persistent_storage'],
    ['stores', 'synced_at'],
  ]);
  assert.equal(rows(columns)[0].data_type, 'boolean');
  assert.equal(rows(columns)[0].is_nullable, 'NO');
  assert.equal(rows(columns)[0].column_default, 'false');
  assert.equal(rows(columns)[1].data_type, 'timestamp with time zone');
  assert.equal(rows(columns)[1].is_nullable, 'YES');
  // These two columns are deployed LIVE already, so migration 007 must also
  // remain a no-op when it is applied on top of a DB with those columns.
  await db.exec(`
    alter table public.devices add column if not exists persistent_storage boolean not null default false;
    alter table public.stores add column if not exists synced_at timestamptz;
  `);
  const afterRetry = await db.query(
    `select table_name, column_name from information_schema.columns
      where table_schema = 'public'
        and ((table_name = 'devices' and column_name = 'persistent_storage')
          or (table_name = 'stores' and column_name = 'synced_at'))
      order by table_name, column_name`,
  );
  assert.deepEqual(rows(afterRetry).map((r) => [r.table_name, r.column_name]), [
    ['devices', 'persistent_storage'],
    ['stores', 'synced_at'],
  ]);
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

  // Anchor to the row's REAL updated_at (it defaults to now(), so a fixed
  // calendar date would age into the past as the suite runs and turn every
  // "ahead" write into a stale one the lww_guard then rejects). +1h is a fast
  // clock, -1h is a stale one, +2h is a newer one.
  const seed = await db.query(`select updated_at from products where id = $1`, [id]);
  const base = rows(seed)[0].updated_at.getTime();
  const ahead = new Date(base + 60 * 60 * 1000).toISOString();
  const stale = new Date(base - 60 * 60 * 1000).toISOString();
  const newer = new Date(base + 2 * 60 * 60 * 1000).toISOString();

  // Local clock far ahead of the stored row (a device with a fast clock).
  await db.query(`update products set name = 'local fresh', updated_at = '${ahead}' where id = $1`, [id]);
  const first = await db.query(
    `select name, updated_at, server_updated_at from products where id = $1`,
    [id],
  );
  assert.equal(rows(first)[0].name, 'local fresh');

  // A stale write (older updated_at) must change NOTHING.
  await db.query(
    `update products set name = 'stale', updated_at = '${stale}' where id = $1`,
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
    `update products set name = 'newer', updated_at = '${newer}' where id = $1`,
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

// ---------------------------------------------------------------- 006 dedupe
// The live database carried six "Cash" methods, three "Tamaraw" products and
// nine "Booth iPad" devices from re-seeds and re-registrations. Migration 006
// merges what exists AND refuses what comes next — both halves are exercised
// here against real Postgres (PGlite), never the live project.
test('006: existing duplicates merge, references survive, FORCE RLS is back', async () => {
  const db = await createDb();
  // Everything EXCEPT 006, so the fixture can carry duplicates first.
  for (const file of migrationFiles()) {
    if (require('path').basename(file).startsWith('006')) continue;
    await db.exec(require('fs').readFileSync(file, 'utf8'));
  }
  await posFixture(db, IDS);

  const now = '2026-10-01T00:00:00Z';
  await db.exec(`
    -- case/spacing variants of the same shelf item
    insert into products (id, store_id, name, price, created_at, updated_at) values
      ('55555555-0000-4000-8000-000000000001', '${IDS.storeId}', 'phm', 30, '${now}', '${now}'),
      ('55555555-0000-4000-8000-000000000002', '${IDS.storeId}', 'PHM ', 30, '${now}', '${now}');
    -- the twin carries the only sale: it must be the survivor
    insert into orders (id, store_id, device_id, order_no, total, created_at, updated_at) values
      ('77777777-0000-4000-8000-000000000001', '${IDS.storeId}',
       '88888888-0000-4000-8000-000000000001', 'A0-261001-001', 30, '${now}', '${now}');
    insert into order_items (id, order_id, product_id, product_name, unit_price, quantity, line_total) values
      ('99999999-0000-4000-8000-000000000001', '77777777-0000-4000-8000-000000000001',
       '55555555-0000-4000-8000-000000000002', 'PHM', 30, 1, 30);
    -- three Cash methods, one GCash
    insert into payment_methods (id, store_id, name, type, created_at, updated_at) values
      ('5a5a5a5a-0000-4000-8000-000000000001', '${IDS.storeId}', 'Cash', 'cash', '${now}', '${now}'),
      ('5a5a5a5a-0000-4000-8000-000000000002', '${IDS.storeId}', 'cash', 'cash', '${now}', '${now}'),
      ('5a5a5a5a-0000-4000-8000-000000000003', '${IDS.storeId}', 'CASH', 'cash', '${now}', '${now}'),
      ('5a5a5a5a-0000-4000-8000-000000000004', '${IDS.storeId}', 'GCash', 'ewallet', '${now}', '${now}');
    update orders set payment_method_id = '5a5a5a5a-0000-4000-8000-000000000002'
      where id = '77777777-0000-4000-8000-000000000001';
    -- two same-name devices; the order below records sales ON ...0002
    insert into devices (id, store_id, device_name, device_code, created_at, updated_at) values
      ('dddddddd-0000-4000-8000-000000000001', '${IDS.storeId}', 'Booth iPad', 'B0', '${now}', '${now}'),
      ('dddddddd-0000-4000-8000-000000000002', '${IDS.storeId}', 'booth  ipad', 'B1', '${now}', '${now}');
    update orders set device_id = 'dddddddd-0000-4000-8000-000000000002'
      where id = '77777777-0000-4000-8000-000000000001';
    -- stock history: the loser carries +5 -1, the survivor -1
    insert into stock_events (id, store_id, product_id, delta, reason, device_id, created_at) values
      ('5e5e5e5e-0000-4000-8000-000000000001', '${IDS.storeId}', '55555555-0000-4000-8000-000000000002', 5, 'import', 'dddddddd-0000-4000-8000-000000000002', '${now}'),
      ('5e5e5e5e-0000-4000-8000-000000000002', '${IDS.storeId}', '55555555-0000-4000-8000-000000000002', -1, 'sale', 'dddddddd-0000-4000-8000-000000000002', '${now}'),
      ('5e5e5e5e-0000-4000-8000-000000000003', '${IDS.storeId}', '55555555-0000-4000-8000-000000000001', -1, 'sale', 'dddddddd-0000-4000-8000-000000000001', '${now}');
  `);

  await db.exec(
    require('fs').readFileSync(
      require('path').resolve(__dirname, '..', 'supabase', 'migrations', '006_dedupe_uniqueness.sql'),
      'utf8',
    ),
  );

  const prods = await db.query(
    `select id from products where store_id = $1 and deleted_at is null
       and norm_name(name) = 'phm'`,
    [IDS.storeId],
  );
  assert.equal(rows(prods).length, 1, 'two PHM variants must collapse to one row');
  assert.equal(
    rows(prods)[0].id,
    '55555555-0000-4000-8000-000000000002',
    'the row WITH sales history must survive',
  );
  const item = await db.query(`select product_id from order_items where id = $1`, [
    '99999999-0000-4000-8000-000000000001',
  ]);
  assert.equal(rows(item)[0].product_id, '55555555-0000-4000-8000-000000000002',
    'sale history must point at the survivor');
  const mirror = await db.query(
    `select stock_quantity from products where id = $1`,
    ['55555555-0000-4000-8000-000000000002'],
  );
  assert.equal(
    rows(mirror)[0].stock_quantity,
    3,
    'the survivor\u2019s stock mirror is recomputed from the events that moved',
  );

  const methods = await db.query(
    `select id from payment_methods where store_id = $1 and deleted_at is null
       and norm_name(name) = 'cash'`,
    [IDS.storeId],
  );
  assert.equal(rows(methods).length, 1, 'three Cash variants must collapse to one');
  assert.equal(rows(methods)[0].id, '5a5a5a5a-0000-4000-8000-000000000002',
    'the Cash an order settled with must survive');
  const o = await db.query(`select payment_method_id from orders where id = $1`, [
    '77777777-0000-4000-8000-000000000001',
  ]);
  assert.equal(rows(o)[0].payment_method_id, '5a5a5a5a-0000-4000-8000-000000000002');

  // Devices are identities: BOTH rows survive, only one is active, and the
  // sale still belongs to the device whose code its order number carries.
  const devs = await db.query(
    `select id, is_active from devices where store_id = $1
       and norm_name(device_name) = 'booth ipad' order by id`,
    [IDS.storeId],
  );
  assert.deepEqual(
    rows(devs).map((r) => [r.id, r.is_active]),
    [
      ['dddddddd-0000-4000-8000-000000000001', false],
      ['dddddddd-0000-4000-8000-000000000002', true],
    ],
    'one active booth (the newest registration), the older row kept as history',
  );
  const oDev = await db.query(`select device_id from orders where id = $1`, [
    '77777777-0000-4000-8000-000000000001',
  ]);
  assert.equal(
    rows(oDev)[0].device_id,
    'dddddddd-0000-4000-8000-000000000002',
    'the sale must not be repointed to another registration',
  );

  // RLS was lifted for the merge and must be back where 003 left it.
  for (const t of ['products', 'order_items', 'devices']) {
    const r = await db.query(
      `select c.relrowsecurity, c.relforcerowsecurity
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = $1`,
      [t],
    );
    assert.equal(rows(r)[0].relforcerowsecurity, true, `${t} must be FORCEd again`);
  }

  // And the migration is idempotent: a second run changes nothing.
  const before = await db.query(`select count(*)::int n from products`);
  await db.exec(
    require('fs').readFileSync(
      require('path').resolve(__dirname, '..', 'supabase', 'migrations', '006_dedupe_uniqueness.sql'),
      'utf8',
    ),
  );
  const after = await db.query(`select count(*)::int n from products`);
  assert.equal(rows(after)[0].n, rows(before)[0].n, 'a re-run must be a no-op');
  await db.close();
});

test('006: the server REFUSES a duplicate name — old client builds included', async () => {
  const db = await migrated();

  // Case + spacing variant of the existing 'Owner product'.
  await assert.rejects(
    () =>
      db.query(
        `insert into products (id, store_id, name, price, created_at, updated_at)
         values ('55555555-0000-4000-8000-0000000000ff', $1, ' owner   PRODUCT ', 30, now(), now())`,
        [IDS.storeId],
      ),
    /duplicate key|unique constraint/i,
    'a normalised duplicate product insert must be refused by the database',
  );

  await db.query(
    `insert into payment_methods (id, store_id, name, type, created_at, updated_at)
     values ('5a5a5a5a-0000-4000-8000-00000000000a', $1, 'GCash', 'ewallet', now(), now())`,
    [IDS.storeId],
  );
  await assert.rejects(
    () =>
      db.query(
        `insert into payment_methods (id, store_id, name, type, created_at, updated_at)
         values ('5a5a5a5a-0000-4000-8000-0000000000ff', $1, ' GCASH ', 'ewallet', now(), now())`,
        [IDS.storeId],
      ),
    /duplicate key|unique constraint/i,
    'a normalised duplicate payment method must be refused',
  );

  // A TOMBSTONE does not hold the name: the app soft-deletes, and the next
  // live row with that name must be accepted.
  await db.query(`update products set deleted_at = now() where id = $1`, [IDS.productId]);
  await db.query(
    `insert into products (id, store_id, name, price, created_at, updated_at)
     values ('55555555-0000-4000-8000-0000000000fe', $1, 'owner product', 30, now(), now())`,
    [IDS.storeId],
  );
  const n = await db.query(
    `select count(*)::int n from products
      where store_id = $1 and deleted_at is null`,
    [IDS.storeId],
  );
  assert.equal(rows(n)[0].n, 1, 'the re-created live row must be the only live one');
  await db.close();
});
