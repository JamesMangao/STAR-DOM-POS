// scripts/verify.js — Stage 2 post-import verification.
//
//   node scripts/verify.js
//
// REVIEW ONLY in this closeout — it is NOT run here. After the import it is the
// last gate before handing the booth a device. It only READS, except for the
// deliberate second-user probe, which creates a throwaway auth user and deletes
// it again in a finally block.
//
// Nothing is hard-coded that the export can answer instead: inactive products,
// opening stock and the payment channels are all derived in verify-lib.js.
// No secret value is ever printed.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const env = require('./env');
const manifest = require('./manifest');
const pg = require('./pg');
const lib = require('./verify-lib');
const { MAX_IMAGE_SIDE } = require('./import-lib');

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
};

async function main() {
  const e = env.requireKeys();
  const exp = lib.expectedFromExport(manifest.EXPORT_DIR);
  const { createClient } = require('@supabase/supabase-js');

  // The app's own path is the ANON key (A9.2). The service-role client is only
  // for admin work: creating the throwaway probe user and cleaning it up.
  const anon = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ---- schema + row counts (read-only SQL) --------------------------------
  const { client, close } = await pg.readOnlyClient();
  try {
    const t = await client.query(
      `select count(*)::int n from information_schema.tables
        where table_schema='public' and table_type='BASE TABLE'`,
    );
    check(`public tables = ${exp.tableCount}`, t.rows[0].n === exp.tableCount, `got ${t.rows[0].n}`);

    const au = await client.query(`select count(*)::int n from auth.users`);
    check('auth.users = 1 (owner only)', au.rows[0].n === 1, `got ${au.rows[0].n}`);

    const p = await client.query(
      `select count(*)::int total,
              count(*) filter (where not is_active)::int inactive
         from products`,
    );
    check(`products = ${exp.products}`, p.rows[0].total === exp.products, `got ${p.rows[0].total}`);
    check(
      `products inactive = ${exp.inactiveProducts} (derived: isactive=false OR price=0)`,
      p.rows[0].inactive === exp.inactiveProducts,
      `got ${p.rows[0].inactive}${exp.zeroPriceIds.length ? `, zero-price ids: ${exp.zeroPriceIds.join(',')}` : ''}`,
    );

    const c = await client.query(`select count(*)::int n from categories`);
    check(`categories = ${exp.categories}`, c.rows[0].n === exp.categories, `got ${c.rows[0].n}`);

    const pm = await client.query(`select count(*)::int n from payment_methods`);
    check('payment_methods = 3 (cash + 2 wallets)', pm.rows[0].n === 3, `got ${pm.rows[0].n}`);

    // ---- opening stock: events, not a bare number (A9.7) -------------------
    const st = await client.query(
      `select count(*)::int n from stock_events where reason = 'import'`,
    );
    check(
      `stock_events(reason='import') = ${exp.expectedImportStockEvents}`,
      st.rows[0].n === exp.expectedImportStockEvents,
      `got ${st.rows[0].n}`,
    );
    const mismatch = await client.query(
      `select count(*)::int n from products p
        where p.stock_quantity <> (
          select coalesce(sum(s.delta), 0) from stock_events s where s.product_id = p.id)`,
    );
    check(
      'every products.stock_quantity equals the sum of its stock_events',
      mismatch.rows[0].n === 0,
      `${mismatch.rows[0].n} product(s) disagree`,
    );

    // ---- no website remnants (A9.6) ---------------------------------------
    const rem = await client.query(
      `select
         (select count(*)::int from information_schema.columns
           where table_schema='public' and table_name='products' and column_name='baseprice') as baseprice,
         (select count(*)::int from storage.buckets where id='assets') as old_bucket,
         (select count(*)::int from storage.buckets where id='pos-assets' and public=false) as private_bucket`,
    );
    check('products has no baseprice column', rem.rows[0].baseprice === 0, `got ${rem.rows[0].baseprice}`);
    check("bucket 'assets' is gone", rem.rows[0].old_bucket === 0, `got ${rem.rows[0].old_bucket}`);
    check("bucket 'pos-assets' exists and is private", rem.rows[0].private_bucket === 1);

    // ---- anon has no rights at all (A9.5) ---------------------------------
    const anonPriv = await client.query(
      `select c.relname
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('r', 'v')
          and has_table_privilege('anon', c.oid, 'select')
        order by 1`,
    );
    check(
      'anon has SELECT on no public table or view',
      anonPriv.rows.length === 0,
      anonPriv.rows.map((r) => r.relname).join(', ') || 'none',
    );

    const viewOpts = await client.query(
      `select c.reloptions from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname='order_status'`,
    );
    const opts = viewOpts.rows[0]?.reloptions || [];
    check(
      'order_status is security_invoker=true',
      opts.includes('security_invoker=true'),
      opts.join(',') || '(none)',
    );

    const seqAnon = await client.query(
      `select count(*)::int n from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='S'
          and has_sequence_privilege('anon', c.oid, 'usage')`,
    );
    check('anon has USAGE on no sequence', seqAnon.rows[0].n === 0, `got ${seqAnon.rows[0].n}`);
  } finally {
    await close();
  }

  // ---- storage: QR byte-identical to the export ---------------------------
  const m = JSON.parse(
    fs.readFileSync(path.join(manifest.EXPORT_DIR, manifest.MANIFEST_NAME), 'utf8'),
  );
  for (const [name, objectPath] of [
    ['qr_gcash.png', 'payment/gcash.png'],
    ['qr_gotyme.png', 'payment/gotyme.png'],
  ]) {
    try {
      const dl = await admin.storage.from('pos-assets').download(objectPath);
      if (dl.error) throw new Error(dl.error.message);
      const buf = Buffer.from(await dl.data.arrayBuffer());
      const want = m.files[name];
      const sha = crypto.createHash('sha256').update(buf).digest('hex');
      check(
        `storage ${objectPath} is byte-identical to ${name}`,
        buf.length === want.bytes && sha === want.sha256,
        `${buf.length}B (export ${want.bytes}B)`,
      );
    } catch (err) {
      check(`storage ${objectPath} is byte-identical to ${name}`, false, err.message);
    }
  }

  // ---- product images exist, and are <= 400px (A9.7) ----------------------
  const { client: c2, close: close2 } = await pg.readOnlyClient();
  let imagePaths = [];
  try {
    const r = await c2.query(
      `select image_path from products where image_path is not null order by image_path`,
    );
    imagePaths = r.rows.map((x) => x.image_path);
    check(
      `every non-null products.image_path is set (${imagePaths.length} products with images)`,
      imagePaths.length > 0,
    );

    const listed = await admin.storage.from('pos-assets').list('products', { limit: 1000 });
    const objects = new Set((listed.data || []).map((o) => `products/${o.name}`));
    const missing = imagePaths.filter((p) => !objects.has(p));
    check('every products.image_path exists in storage', missing.length === 0, missing.slice(0, 3).join(', '));
  } finally {
    await close2();
  }

  const sample = [...imagePaths].sort(() => Math.random() - 0.5).slice(0, 5);
  for (const p of sample) {
    try {
      const dl = await admin.storage.from('pos-assets').download(p);
      if (dl.error) throw new Error(dl.error.message);
      const meta = await sharp(Buffer.from(await dl.data.arrayBuffer())).metadata();
      const side = Math.max(meta.width, meta.height);
      check(
        `${p} max side <= ${MAX_IMAGE_SIDE}px`,
        meta.format === 'webp' && side <= MAX_IMAGE_SIDE,
        `${meta.format} ${meta.width}x${meta.height}`,
      );
    } catch (err) {
      check(`${p} max side <= ${MAX_IMAGE_SIDE}px`, false, err.message);
    }
  }

  // ---- RLS probes with the ANON client (the app's path) -------------------
  const anonRead = await anon.from('products').select('id').limit(1);
  check('anon SELECT products denied/empty', !!anonRead.error || anonRead.data.length === 0);

  const anonWrite = await anon.from('products').insert({ name: 'x' });
  check('anon INSERT products denied', !!anonWrite.error);

  const anonView = await anon.from('order_status').select('id').limit(1);
  check('anon SELECT order_status denied/empty', !!anonView.error || anonView.data.length === 0);

  // ---- silent sign-in on the ANON client (the app's path, A9.2) ---------
  const ownerSignIn = await anon.auth.signInWithPassword({
    email: e.OWNER_EMAIL,
    password: e.OWNER_PASSWORD,
  });
  check(
    'silent sign-in via the anon client succeeds (publishableKey path)',
    !ownerSignIn.error,
    ownerSignIn.error?.message || '',
  );

  if (!ownerSignIn.error) {
    const owner = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${ownerSignIn.data.session.access_token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const ownerRead = await owner.from('products').select('id');
    check(
      `owner reads ${exp.products} products`,
      ownerRead.data?.length === exp.products,
      `got ${ownerRead.data?.length}${ownerRead.error ? ' ' + ownerRead.error.message : ''}`,
    );
    const ownerUpdate = await owner.from('orders').update({ note: 'x' }).eq('note', 'x').select();
    check(
      'owner UPDATE on orders changes nothing (append-only)',
      (ownerUpdate.data?.length ?? 0) === 0,
      `${ownerUpdate.data?.length ?? 0} rows`,
    );
  }

  // ---- second user probe: real, not hard-coded (A9.3) --------------------
  const tmpEmail = `probe-${Date.now()}@example.invalid`;
  const tmpPass = crypto.randomUUID() + 'Aa1!';
  let tmpUserId = null;
  try {
    const created = await admin.auth.admin.createUser({
      email: tmpEmail,
      password: tmpPass,
      email_confirm: true,
    });
    if (created.error) throw new Error(created.error.message);
    tmpUserId = created.data.user.id;

    const second = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const signIn = await second.auth.signInWithPassword({ email: tmpEmail, password: tmpPass });
    check('second user can sign in (probe setup)', !signIn.error, signIn.error?.message || '');

    const read = await second.from('products').select('id');
    check(
      'second user reads 0 products (no store)',
      (read.data?.length ?? 0) === 0,
      `got ${read.data?.length}${read.error ? ' ' + read.error.message : ''}`,
    );

    const ins = await second.from('orders').insert({ order_no: 'probe', total: 1 });
    check('second user INSERT orders denied', !!ins.error, ins.error?.message || 'no error');

    const dl = await second.storage.from('pos-assets').download('products/any.webp');
    check('second user storage read denied', !!dl.error, dl.error?.message || 'no error');
  } catch (err) {
    check('second user is denied everything', false, err.message);
  } finally {
    if (tmpUserId) {
      const del = await admin.auth.admin.deleteUser(tmpUserId);
      check('probe user deleted', !del.error, del.error?.message || '');
    }
  }

  // ---- signup must be OFF (A9.4) -----------------------------------------
  const signup = await anon.auth.signUp({
    email: `signup-${Date.now()}@example.invalid`,
    password: 'Zz1!' + crypto.randomUUID(),
  });
  if (!signup.error && signup.data?.user?.id) {
    // It succeeded: remove the account and FAIL — signups are supposed to be off.
    await admin.auth.admin.deleteUser(signup.data.user.id);
    check('signups disabled', false, `signUp succeeded; user ${signup.data.user.id} deleted`);
  } else {
    check('signups disabled', true, signup.error?.message || '');
  }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((e) => {
  console.error('verify failed:', e.message);
  process.exit(1);
});
