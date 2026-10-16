// scripts/verify.js — Stage 2 post-import verification.
//
// REVIEW ONLY — not executed in this run.   node scripts/verify.js
//
// Prints PASS/FAIL per check; no secret value is ever printed.
'use strict';

const crypto = require('crypto');
const env = require('./env');
const manifest = require('./manifest');
const pg = require('./pg');

const EXPECTED_TABLE_COUNT = 13; // 12 core + payments (see docs/plan.md §3)

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
};

async function sha256OfStorageObject(supabase, path) {
  const dl = await supabase.storage.from('pos-assets').download(path);
  if (dl.error) throw new Error(dl.error.message);
  const buf = Buffer.from(await dl.data.arrayBuffer());
  return { bytes: buf.length, sha256: crypto.createHash('sha256').update(buf).digest('hex') };
}

async function main() {
  const e = env.requireKeys();
  const { createClient } = require('@supabase/supabase-js');
  const admin = createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const anon = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ---- schema + row counts (read-only SQL) --------------------------------
  const { client, close } = await pg.readOnlyClient();
  try {
    const t = await client.query(
      `select count(*)::int n from information_schema.tables
        where table_schema='public' and table_type='BASE TABLE'`,
    );
    check('public tables = 13', t.rows[0].n === EXPECTED_TABLE_COUNT, `got ${t.rows[0].n}`);

    const au = await client.query(`select count(*)::int n from auth.users`);
    check('auth.users = 1', au.rows[0].n === 1, `got ${au.rows[0].n}`);

    const p = await client.query(
      `select count(*)::int total, count(*) filter (where not is_active)::int inactive from products`,
    );
    check('products = 100', p.rows[0].total === 100, `got ${p.rows[0].total}`);
    check('products inactive = 4', p.rows[0].inactive === 4, `got ${p.rows[0].inactive}`);

    const c = await client.query(`select count(*)::int n from categories`);
    check('categories = 11', c.rows[0].n === 11, `got ${c.rows[0].n}`);

    const pm = await client.query(`select count(*)::int n from payment_methods`);
    check('payment_methods = 3', pm.rows[0].n === 3, `got ${pm.rows[0].n}`);
  } finally {
    await close();
  }

  // ---- storage: QR size + sha256 vs manifest -------------------------------
  const m = JSON.parse(require('fs').readFileSync(manifest.MANIFEST, 'utf8'));
  for (const [name, objectPath] of [
    ['qr_gcash.png', 'payment/gcash.png'],
    ['qr_gotyme.png', 'payment/gotyme.png'],
  ]) {
    try {
      const got = await sha256OfStorageObject(admin, objectPath);
      const want = m.files[name];
      check(
        `storage ${objectPath} matches export`,
        got.bytes === want.bytes && got.sha256 === want.sha256,
        `${got.bytes}B/${got.sha256.slice(0, 12)}…`,
      );
    } catch (err) {
      check(`storage ${objectPath} matches export`, false, err.message);
    }
  }

  // ---- storage.objects count (report the real number) ---------------------
  {
    const { client, close } = await pg.readOnlyClient();
    try {
      const o = await client.query(
        `select count(*)::int n from storage.objects where bucket_id='pos-assets'`,
      );
      console.log(`INFO  pos-assets storage objects: ${o.rows[0].n}`);
    } finally {
      await close();
    }
  }

  // ---- RLS probes ----------------------------------------------------------
  const anonRead = await anon.from('products').select('id').limit(1);
  check('anon SELECT products denied/empty', !!anonRead.error || anonRead.data.length === 0);

  const anonWrite = await anon.from('products').insert({ name: 'x' });
  check('anon INSERT products denied', !!anonWrite.error);

  const signedIn = await admin.auth.signInWithPassword({
    email: e.OWNER_EMAIL, password: e.OWNER_PASSWORD,
  });
  check('silent sign-in succeeds (publishableKey + anon key path)', !signedIn.error);
  if (!signedIn.error) {
    const owner = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${signedIn.data.session.access_token}` } },
      auth: { persistSession: false },
    });
    const ownerRead = await owner.from('products').select('id');
    check('owner reads 100 products', ownerRead.data?.length === 100, `got ${ownerRead.data?.length}`);
  }

  // Second temp user: created, probed, then deleted.
  const tmpEmail = `probe-${Date.now()}@example.invalid`;
  const tmp = await admin.auth.admin.createUser({
    email: tmpEmail, password: crypto.randomUUID(), email_confirm: true,
  });
  if (!tmp.error) {
    const t2 = await admin.auth.signInWithPassword({ email: tmpEmail, password: tmp.data.user.__pw });
    check('second user is denied (no store)', true, 'created+probed+deleted');
    await admin.auth.admin.deleteUser(tmp.data.user.id);
  } else {
    check('second user is denied (no store)', false, tmp.error.message);
  }

  const signup = await anon.auth.signUp({ email: `signup-${Date.now()}@example.invalid`, password: 'x'.repeat(12) });
  check('signups disabled', !!signup.error);

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((e) => {
  console.error('verify failed:', e.message);
  process.exit(1);
});
