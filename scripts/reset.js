// scripts/reset.js — retire the STAR:DOM WEBSITE objects.
//
// DEFAULT IS A DRY RUN. Nothing is dropped unless BOTH are given:
//     --execute  AND  --ref pykhzrpgdszcwvpydebt
//
// Safety, in order:
//   1. supabase/export/manifest.json must exist and match disk exactly
//      (counts 100/11/58/2 + sha256 of every file including both QRs).
//   2. The SUPABASE_DB_URL host must contain the project ref.
//   3. Only tables on the WEBSITE allowlist are dropped; any public table
//      that is on neither the website nor the POS list aborts the run.
//   4. `DROP SCHEMA public` is never emitted.
'use strict';

const manifest = require('./manifest');
const env = require('./env');
const pg = require('./pg');

const PROJECT_REF = 'pykhzrpgdszcwvpydebt';

// The 32 retired website tables (exact names from the live project).
const WEBSITE_TABLES = [
  'apperrors', 'assetimages', 'bundleitems', 'bundles', 'cart', 'cartitems',
  'categories', 'commissionreferenceimages', 'commissions',
  'commissionstatushistory', 'eventinventory', 'eventsales', 'notifications',
  'ordercommissions', 'orderitems', 'orders', 'orderstatushistory',
  'payments', 'paymentsettings', 'popupevents', 'productimages', 'products',
  'productvariants', 'promotions', 'receipts', 'reviews', 'roles', 'shipping',
  'storelocations', 'useraddresses', 'users', 'wishlistitems',
];

// POS tables created by supabase/migrations. `categories`, `products`,
// `orders` and `payments` are shared names and already on the website list.
const POS_TABLES = [
  'stores', 'devices', 'payment_methods', 'settings', 'order_items',
  'order_voids', 'stock_events', 'day_closes', 'sync_outbox',
];

const RETIRED_BUCKETS = ['assets'];

function argValue(argv, flag) {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : null;
}

async function main() {
  const argv = process.argv.slice(2);
  const execute = argv.includes('--execute');
  const ref = argValue(argv, '--ref');

  console.log('=== reset.js — ' + (execute ? 'EXECUTE' : 'DRY RUN') + ' ===\n');

  // ---- 1. manifest preflight (local, no network) ------------------------
  const v = manifest.verify();
  console.log('manifest preflight:', v.ok ? 'OK' : 'REFUSED');
  if (!v.ok) {
    for (const p of v.problems) console.log('  - ' + p);
    console.log('\nRefusing: export manifest does not match disk. Nothing changed.');
    process.exit(1);
  }
  console.log('  counts:', JSON.stringify(manifest.EXPECTED_COUNTS));

  // ---- 2. local plan ----------------------------------------------------
  console.log('\nWEBSITE tables to drop (cascade):', WEBSITE_TABLES.length);
  console.log('  ' + WEBSITE_TABLES.join(', '));
  console.log('POS tables that must NOT be dropped by name-mismatch:');
  console.log('  ' + POS_TABLES.join(', '));
  console.log('storage buckets to drop:', RETIRED_BUCKETS.join(', '));
  console.log('safety: DROP SCHEMA public is never emitted.');

  // ---- 3. DB phase ------------------------------------------------------
  const missing = env.REQUIRED_KEYS.filter((k) => !env.load()[k]);
  if (missing.length) {
    console.log('\nDB phase needs ' + env.ENV_PATH + '. Missing key NAMES:');
    for (const k of missing) console.log('  - ' + k);
    console.log('\nStopping before touching the database.');
    process.exit(2);
  }

  if (execute) {
    if (ref !== PROJECT_REF) {
      console.log(`\nRefusing to execute: pass --ref ${PROJECT_REF}.`);
      process.exit(1);
    }
    const host = pg.assertProjectRef(PROJECT_REF);
    console.log(`\nproject ref present in host: OK`);
  }

  const { client, close } = execute
    ? await pg.writeClient()
    : await pg.readOnlyClient();
  try {
    const tables = await client.query(
      `select table_name from information_schema.tables
        where table_schema='public' and table_type='BASE TABLE'
        order by table_name`,
    );
    const present = tables.rows.map((r) => r.table_name);
    const unknown = present.filter(
      (t) => !WEBSITE_TABLES.includes(t) && !POS_TABLES.includes(t),
    );
    if (unknown.length) {
      console.log('\nREFUSED: unexpected public objects:', unknown.join(', '));
      process.exit(1);
    }
    const website = present.filter((t) => WEBSITE_TABLES.includes(t));

    console.log('\nrow counts:');
    for (const t of website) {
      const r = await client.query(`select count(*)::int n from "${t}"`);
      console.log(`  ${t.padEnd(28)} ${r.rows[0].n}`);
    }
    const objs = await client.query(
      `select bucket_id, count(*)::int n from storage.objects group by bucket_id order by bucket_id`,
    );
    console.log('\nstorage objects by bucket:');
    for (const r of objs.rows) console.log(`  ${r.bucket_id.padEnd(20)} ${r.n}`);

    if (!execute) {
      console.log('\nDRY RUN complete — nothing changed.');
      return;
    }

    console.log('\n--execute: dropping allowlisted website tables …');
    await client.query('BEGIN');
    for (const t of website) {
      await client.query(`drop table if exists public."${t}" cascade`);
    }
    for (const b of RETIRED_BUCKETS) {
      await client.query(`delete from storage.objects where bucket_id = $1`, [b]);
      await client.query(`delete from storage.buckets where id = $1`, [b]);
    }
    await client.query('COMMIT');
    console.log('done. public schema and grants untouched.');
  } finally {
    await close();
  }
}

main().catch((e) => {
  console.error('reset failed:', e.message);
  process.exit(1);
});
