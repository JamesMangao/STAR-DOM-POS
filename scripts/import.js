// scripts/import.js — Step C: transform the export into the POS schema.
//
// REVIEW ONLY — not executed in this run. Deps: pg, @supabase/supabase-js.
//   node scripts/import.js
//
// Images are uploaded as-is (the source files are already .webp); no resizing
// step is performed.
//
// IDEMPOTENT + RESUMABLE by construction:
//   * every row's uuid is uuid v5 of a fixed namespace + "table:source_id",
//     so a rerun produces the same PK and hits ON CONFLICT instead of
//     duplicating. A crash mid-run is fixed by simply running it again.
//   * storage uploads use upsert:true and are skipped when the object already
//     exists with the same size.
//   * the owner auth user is created only if absent.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { writeClient } = require('./pg');
const env = require('./env');
const manifest = require('./manifest');

const ASSETS_ROOT = 'D:\\STARDOM\\STAR-DOM-Web';
const NS = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'; // namespace URL

// ---- deterministic uuid v5 -------------------------------------------------
function uuidV5(name) {
  const nsBytes = Buffer.from(NS.replace(/-/g, ''), 'hex');
  const h = crypto.createHash('sha1').update(nsBytes).update(name, 'utf8').digest();
  const b = Buffer.from(h.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex = b.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const idOf = (table, srcId) => uuidV5(`${table}:${srcId}`);

// ---- helpers ---------------------------------------------------------------
const readJson = (n) =>
  JSON.parse(fs.readFileSync(path.join(manifest.EXPORT_DIR, `${n}.json`), 'utf8'));

async function applyMigrations(client) {
  const dir = path.resolve(__dirname, '..', 'supabase', 'migrations');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  for (const f of files) {
    const sql = fs.readFileSync(path.join(dir, f), 'utf8');
    await client.query('BEGIN');
    try {
      await client.query(sql);
      await client.query('COMMIT');
      console.log('migration applied:', f);
    } catch (e) {
      await client.query('ROLLBACK');
      throw new Error(`migration ${f} failed: ${e.message}`);
    }
  }
}

// ---- 1. owner auth user + store -------------------------------------------
async function ensureOwnerAndStore(supabaseAdmin, client, e) {
  const storeId = uuidV5('store:main');
  let ownerId;

  const list = await supabaseAdmin.auth.admin.listUsers();
  const existing = list.data?.users?.find((u) => u.email === e.OWNER_EMAIL);
  if (existing) {
    ownerId = existing.id;
    console.log('owner auth user: reused', ownerId);
  } else {
    const created = await supabaseAdmin.auth.admin.createUser({
      email: e.OWNER_EMAIL,
      password: e.OWNER_PASSWORD,
      email_confirm: true,
    });
    if (created.error) throw new Error(created.error.message);
    ownerId = created.data.user.id;
    console.log('owner auth user: created', ownerId);
  }

  await client.query(
    `insert into stores (id, name, tagline, owner_id, receipt_name, receipt_tin,
        receipt_address, receipt_accreditation, receipt_footer, currency)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,'PHP')
     on conflict (id) do update set owner_id = excluded.owner_id,
       name = excluded.name, tagline = excluded.tagline`,
    [
      storeId,
      'STAR:DOM Artisan & Pop-up Hub',
      'Fast. Simple. Offline. Built for Filipino Small Businesses.',
      ownerId,
      'STAR:DOM Artisan Marketplace & Pop-up Tour',
      '000-000-000-000',
      'Unit 12, South Luzon Atelier, Santa Rosa, Laguna',
      'PTU-2026-00015',
      'Salamat sa pagtangkilik!',
    ],
  );
  console.log('store bound: stores.owner_id = auth.users.id =', ownerId);
  return { storeId, ownerId };
}

// ---- 2. categories + products + images ------------------------------------
async function importCatalogue(supabase, client, storeId) {
  const cats = readJson('categories');
  const catId = new Map();
  for (const c of cats) {
    const id = idOf('categories', c.id);
    catId.set(c.id, id);
    await client.query(
      `insert into categories (id, store_id, name, sort_order, is_active)
       values ($1,$2,$3,$4,$5)
       on conflict (id) do update set name=excluded.name,
         sort_order=excluded.sort_order, is_active=excluded.is_active`,
      [id, storeId, c.name.trim(), c.displayorder ?? 0, !!c.isactive],
    );
  }
  console.log('categories upserted:', cats.length);

  const images = readJson('productimages');
  const primary = new Map();
  for (const i of images) if (i.isprimary && !primary.has(i.productid)) primary.set(i.productid, i.imagefile);

  const products = readJson('products');
  let uploaded = 0, missingImg = 0;
  for (const p of products) {
    const id = idOf('products', p.id);
    const categoryId = p.categoryid ? catId.get(p.categoryid) ?? null : null;
    let imagePath = null;
    const rel = primary.get(p.id);
    if (rel) {
      const disk = path.join(ASSETS_ROOT, rel.replace(/^[\\/]+/, ''));
      if (fs.existsSync(disk)) {
        const objectPath = `products/${id}.webp`;
        await uploadIfChanged(supabase, disk, objectPath);
        imagePath = objectPath;
        uploaded++;
      } else {
        missingImg++;
      }
    }
    await client.query(
      `insert into products (id, store_id, category_id, name, price, barcode,
          image_path, stock_quantity, is_active)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       on conflict (id) do update set category_id=excluded.category_id,
         name=excluded.name, price=excluded.price, barcode=excluded.barcode,
         image_path=excluded.image_path, is_active=excluded.is_active`,
      [id, storeId, categoryId, p.name.trim(), Number(p.baseprice ?? 0),
       p.sku || null, imagePath, Number(p.stockquantity ?? 0), !!p.isactive],
    );
  }
  console.log(`products upserted: ${products.length}, images uploaded: ${uploaded}, missing on disk: ${missingImg}`);
}

async function uploadIfChanged(supabase, disk, objectPath) {
  const buf = fs.readFileSync(disk);
  const existing = await supabase.storage.from('pos-assets').list('products', {
    search: path.basename(objectPath),
  });
  const found = existing.data?.find((o) => o.name === path.basename(objectPath));
  if (found && found.metadata?.size === buf.length) return; // resumable skip
  const up = await supabase.storage
    .from('pos-assets')
    .upload(objectPath, buf, { contentType: 'image/webp', upsert: true });
  if (up.error) throw new Error(`upload ${objectPath}: ${up.error.message}`);
}

// ---- 3. seed: payment methods --------------------------------------------
// seedOutline:
//   store (above) -> payment_methods: Cash (cash), GCash (ewallet, QR
//   qr_gcash.png, require_reference), GoTyme (ewallet, QR qr_gotyme.png,
//   require_reference); QR files are uploaded to pos-assets/payment/.
async function seed(supabase, client, storeId) {
  const rows = [
    [idOf('pm', 'cash'), 'Cash', 'cash', '#15803D', null, '', '', false, 0],
    [idOf('pm', 'gcash'), 'GCash', 'ewallet', '#0070E0', 'payment/gcash.png',
      'RIAN DOMINIC CABREROS', '0970 137 5033', true, 1],
    [idOf('pm', 'gotyme'), 'GoTyme', 'ewallet', '#00A3A1', 'payment/gotyme.png',
      'RIAN DOMINIC CABREROS', '', true, 2],
  ];
  for (const [id, name, type, color, qr, acct, num, reqRef, sort] of rows) {
    if (qr) {
      const file = path.join(manifest.EXPORT_DIR, qr.split('/').pop());
      const buf = fs.readFileSync(file);
      await supabase.storage.from('pos-assets').upload(qr, buf, {
        contentType: 'image/png', upsert: true,
      });
    }
    await client.query(
      `insert into payment_methods (id, store_id, name, type, color,
          qr_image_path, account_name, account_number, require_reference,
          is_enabled, sort_order)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,true,$10)
       on conflict (id) do update set name=excluded.name, type=excluded.type,
         color=excluded.color, qr_image_path=excluded.qr_image_path,
         account_name=excluded.account_name,
         account_number=excluded.account_number,
         require_reference=excluded.require_reference,
         sort_order=excluded.sort_order`,
      [id, storeId, name, type, color, qr, acct, num, reqRef, sort],
    );
  }
  console.log('payment_methods upserted:', rows.length);
}

// ---- main ------------------------------------------------------------------
async function main() {
  const e = env.requireKeys();
  const v = manifest.verify();
  if (!v.ok) {
    console.log('refusing import — manifest mismatch:');
    v.problems.forEach((p) => console.log('  - ' + p));
    process.exit(1);
  }
  const { createClient } = require('@supabase/supabase-js');
  const supabase = createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const { client, close } = await writeClient();
  try {
    await applyMigrations(client);
    const { storeId } = await ensureOwnerAndStore(supabase, client, e);
    await importCatalogue(supabase, client, storeId);
    await seed(supabase, client, storeId);
    console.log('import complete. Run scripts/verify.js next.');
  } finally {
    await close();
  }
}

main().catch((e) => {
  console.error('import failed:', e.message, '— rerun is safe (idempotent).');
  process.exit(1);
});
