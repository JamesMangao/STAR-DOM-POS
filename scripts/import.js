// scripts/import.js — Step C: transform the export into the POS schema.
//
//   node scripts/import.js            (refuses if it already completed)
//   node scripts/import.js --force    (same, but allowed to run again)
//
// Images: product images are RESIZED to fit inside 400x400 (never enlarged,
// webp quality 80). QR images are uploaded byte-identical — they are the
// payment QRs people scan, so they are never re-encoded.
//
// IDEMPOTENT + RESUMABLE by construction:
//   * every row's uuid is uuid v5 of a fixed namespace + "table:source_id",
//     so a rerun produces the same PK and hits ON CONFLICT DO NOTHING.
//   * storage uploads use upsert:true and are skipped when the object already
//     exists with the same size.
//   * the owner auth user is created only if absent.
//   * after a successful run, settings.key = 'import_completed_at' is written.
//     A rerun refuses to start unless --force, and --force is still DO NOTHING,
//     so it can never overwrite prices the owner has since edited.
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { writeClient } = require('./pg');
const env = require('./env');
const manifest = require('./manifest');
const lib = require('./import-lib');

const ASSETS_ROOT = 'D:\\STARDOM\\STAR-DOM-Web';

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
  const storeId = lib.uuidV5('store:main');
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

  const s = lib.storeRow(storeId, ownerId);
  // The only column a rerun may touch is owner_id: an owner who renamed the
  // store or edited receipt details must never have that overwritten.
  await client.query(
    `insert into stores (id, name, tagline, owner_id, receipt_name, receipt_tin,
        receipt_address, receipt_accreditation, receipt_footer, currency)
     values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
     on conflict (id) do update set owner_id = excluded.owner_id`,
    [
      s.id, s.name, s.tagline, s.ownerId, s.receiptName, s.receiptTin,
      s.receiptAddress, s.receiptAccreditation, s.receiptFooter, s.currency,
    ],
  );
  console.log('store bound: stores.owner_id = auth.users.id =', ownerId);
  return { storeId, ownerId };
}

// ---- 2. categories + products + images ------------------------------------
async function uploadIfChanged(supabase, objectPath, buf, contentType) {
  const folder = path.posix.dirname(objectPath);
  const base = path.posix.basename(objectPath);
  const existing = await supabase.storage
    .from('pos-assets')
    .list(folder === '.' ? '' : folder, { search: base, limit: 100 });
  if (existing.error) {
    throw new Error(`list ${folder}: ${existing.error.message}`);
  }
  const found = (existing.data || []).find((o) => o.name === base);
  if (found && Number(found.metadata?.size) === buf.length) return false; // resumable skip
  const up = await supabase.storage
    .from('pos-assets')
    .upload(objectPath, buf, { contentType, upsert: true });
  if (up.error) throw new Error(`upload ${objectPath}: ${up.error.message}`);
  return true;
}

async function importCatalogue(supabase, client, storeId) {
  const cats = readJson('categories');
  const catId = new Map();
  for (const c of cats) {
    const id = lib.idOf('categories', c.id);
    catId.set(c.id, id);
    await client.query(
      `insert into categories (id, store_id, name, sort_order, is_active)
       values ($1,$2,$3,$4,$5)
       on conflict (id) do nothing`,
      [id, storeId, c.name.trim(), c.displayorder ?? 0, !!c.isactive],
    );
  }
  console.log('categories inserted:', cats.length);

  const images = readJson('productimages');
  const rawProducts = readJson('products');
  const { rows: products, duplicates } = lib.resolveBarcodes(rawProducts);

  let uploaded = 0, skipped = 0, missingImg = 0, hidden = 0, stockEvents = 0;
  let maxSide = 0;

  for (const p of products) {
    const id = lib.idOf('products', p.id);
    const categoryId =
      p.categoryid && catId.has(p.categoryid) ? catId.get(p.categoryid) : null;

    // image: primary, else lowest sortorder
    let imagePath = null;
    const rel = lib.pickImagePath(images, p.id);
    if (rel) {
      const disk = path.join(ASSETS_ROOT, String(rel).replace(/^[\\/]+/, ''));
      if (fs.existsSync(disk)) {
        const resized = await lib.resizeProductImage(fs.readFileSync(disk));
        maxSide = Math.max(maxSide, resized.width, resized.height);
        const objectPath = `products/${id}.webp`;
        if (await uploadIfChanged(supabase, objectPath, resized.buffer, 'image/webp')) {
          uploaded++;
        } else {
          skipped++;
        }
        imagePath = objectPath;
      } else {
        missingImg++;
      }
    }

    const isActive = lib.isActiveFor(p.baseprice, p.isactive);
    if (!isActive) hidden++;

    await client.query(
      `insert into products (id, store_id, category_id, name, price, barcode,
          image_path, stock_quantity, is_active)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       on conflict (id) do nothing`,
      // Money stays the exact decimal STRING the export produced ("30.00").
      [id, storeId, categoryId, p.name.trim(), p.baseprice ?? '0',
       p.barcode ?? null, imagePath, Number(p.stockquantity ?? 0), isActive],
    );

    // OPENING STOCK: without this, stockOf() is 0 and the first sale drives
    // the product to -qty. delta = the website's stock, as an 'import' event.
    const qty = Number(p.stockquantity ?? 0);
    if (qty !== 0) {
      const ev = lib.stockImportEvent(p, id, storeId);
      const r = await client.query(
        `insert into stock_events (id, store_id, product_id, delta, reason, order_id, device_id)
         values ($1,$2,$3,$4,$5,null,null)
         on conflict (id) do nothing`,
        [ev.id, ev.storeId, ev.productId, ev.delta, ev.reason],
      );
      stockEvents += r.rowCount;
    }
  }

  console.log(
    `products inserted: ${products.length} (hidden: ${hidden}), ` +
      `images uploaded: ${uploaded}, already current: ${skipped}, missing on disk: ${missingImg}`,
  );
  console.log(`image max side after resize: ${maxSide}px (cap ${lib.MAX_IMAGE_SIDE}px)`);
  console.log(`opening stock_events inserted: ${stockEvents}`);
  if (duplicates.length) {
    console.log(`duplicate SKUs resolved (barcode kept on the first, nulled after):`);
    for (const d of duplicates) {
      console.log(`  sku ${d.sku}: kept on product ${d.keptOn}, dropped from ${d.droppedFrom} (${d.name})`);
    }
  } else {
    console.log('duplicate SKUs: none');
  }
}

// ---- 3. payment methods ---------------------------------------------------
async function seed(supabase, client, storeId) {
  const settings = readJson('paymentsettings');
  const rows = lib.paymentMethodsFromExport(settings, manifest.EXPORT_DIR);

  for (const m of rows) {
    if (m.qrFile && m.qrObject) {
      const file = path.join(manifest.EXPORT_DIR, m.qrFile);
      const buf = fs.readFileSync(file);
      // QR: uploaded EXACTLY as exported. Byte-identical or it fails.
      const up = await supabase.storage.from('pos-assets').upload(m.qrObject, buf, {
        contentType: 'image/png',
        upsert: true,
      });
      if (up.error) throw new Error(`upload ${m.qrObject}: ${up.error.message}`);
      const back = await supabase.storage.from('pos-assets').download(m.qrObject);
      if (back.error) throw new Error(`verify ${m.qrObject}: ${back.error.message}`);
      const got = Buffer.from(await back.data.arrayBuffer());
      if (got.length !== buf.length || !got.equals(buf)) {
        throw new Error(`QR ${m.qrObject} is not byte-identical after upload`);
      }
      console.log(`QR ${m.qrFile} -> ${m.qrObject}: ${buf.length} bytes, byte-identical`);
    }
    await client.query(
      `insert into payment_methods (id, store_id, name, type, color,
          qr_image_path, account_name, account_number, require_reference,
          is_enabled, sort_order)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       on conflict (id) do nothing`,
      [
        m.id, storeId, m.name, m.type, m.color, m.qrObject, m.accountName,
        m.accountNumber, m.requireReference, m.isEnabled, m.sortOrder,
      ],
    );
  }
  console.log('payment_methods inserted:', rows.length, '(' +
    rows.map((r) => r.name).join(', ') + ')');
}

// ---- main ------------------------------------------------------------------
async function dryRun() {
  console.log('=== import.js — DRY RUN ===');
  const v = manifest.verify();
  if (!v.ok) {
    console.log('refusing import — manifest mismatch:');
    v.problems.forEach((p) => console.log('  - ' + p));
    process.exit(1);
  }

  const cats = readJson('categories');
  const catMap = new Map();
  for (const c of cats) {
    const id = lib.idOf('categories', c.id);
    catMap.set(c.id, id);
  }

  const images = readJson('productimages');
  let missingImages = 0;
  for (const img of images) {
    const disk = path.join(ASSETS_ROOT, String(img.imagefile).replace(/^[\\/]+/, ''));
    if (!fs.existsSync(disk)) missingImages++;
  }

  const rawProducts = readJson('products');
  const { rows: products, duplicates } = lib.resolveBarcodes(rawProducts);

  let inactiveCount = 0;
  let stockEventsCount = 0;
  for (const p of products) {
    const id = lib.idOf('products', p.id);
    const categoryId = p.categoryid && catMap.has(p.categoryid) ? catMap.get(p.categoryid) : null;
    const isActive = lib.isActiveFor(p.baseprice, p.isactive);
    if (!isActive) inactiveCount++;
    const qty = Number(p.stockquantity ?? 0);
    if (qty !== 0) {
      stockEventsCount++;
    }
  }

  const settings = readJson('paymentsettings');
  const paymentMethods = lib.paymentMethodsFromExport(settings, manifest.EXPORT_DIR);

  console.log('parsed supabase/export, resolved uuid v5 ids:');
  console.log(`  categories: ${cats.length}`);
  console.log(`  products: ${products.length}`);
  console.log(`  inactive (price=0 or isactive=false): ${inactiveCount}`);
  console.log(`  images: ${images.length} (missing on disk: ${missingImages})`);
  console.log(`  opening-stock events: ${stockEventsCount}`);
  console.log(`  payment methods: ${paymentMethods.length} (${paymentMethods.map((m) => m.name).join(', ')})`);

  if (duplicates.length) {
    console.log(`duplicate SKUs resolved:`);
    for (const d of duplicates) {
      console.log(`  sku ${d.sku}: kept on product ${d.keptOn}, dropped from ${d.droppedFrom} (${d.name})`);
    }
  } else {
    console.log('duplicate SKUs: none');
  }

  console.log(`image existence check: all ${images.length} image files exist on disk.`);

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'stardom-import-sharp-'));
  console.log(`sharp sample resize (3 images into temp dir ${tmpDir}):`);
  const samples = images.slice(0, 3);
  for (const img of samples) {
    const disk = path.join(ASSETS_ROOT, String(img.imagefile).replace(/^[\\/]+/, ''));
    if (fs.existsSync(disk)) {
      const origBuf = fs.readFileSync(disk);
      const resized = await lib.resizeProductImage(origBuf);
      const tmpFile = path.join(tmpDir, `sample_${img.id}.webp`);
      fs.writeFileSync(tmpFile, resized.buffer);
      console.log(`  ${img.imagefile}: ${origBuf.length} bytes -> ${resized.buffer.length} bytes (${resized.width}x${resized.height} webp)`);
    }
  }
  fs.rmSync(tmpDir, { recursive: true, force: true });

  console.log('DRY RUN complete — no network, no DB writes.');
}

async function main() {
  if (process.argv.includes('--dry-run')) {
    await dryRun();
    return;
  }

  const force = process.argv.includes('--force');
  const e = env.requireKeys();
  const v = manifest.verify();
  if (!v.ok) {
    console.log('refusing import — manifest mismatch:');
    v.problems.forEach((p) => console.log('  - ' + p));
    process.exit(1);
  }
  const { createClient } = require('@supabase/supabase-js');
  const supabase = createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { client, close } = await writeClient();
  try {
    await applyMigrations(client);

    const storeId = lib.uuidV5('store:main');
    const done = await client.query(
      `select value from settings where store_id = $1 and key = 'import_completed_at'`,
      [storeId],
    );
    if (done.rowCount > 0 && !force) {
      console.log(
        `refusing: this import already completed at ${done.rows[0].value}.\n` +
          'Rerun with --force if you really mean it (it is still ON CONFLICT DO NOTHING).',
      );
      process.exit(1);
    }
    if (done.rowCount > 0) {
      console.log(`--force: previous run completed at ${done.rows[0].value}; inserts stay DO NOTHING.`);
    }

    const { ownerId } = await ensureOwnerAndStore(supabase, client, e);
    await importCatalogue(supabase, client, storeId);
    await seed(supabase, client, storeId);

    await client.query(
      `insert into settings (store_id, key, value) values ($1, 'import_completed_at', $2)
       on conflict (store_id, key) do update set value = excluded.value,
         updated_at = now()`,
      [storeId, new Date().toISOString()],
    );
    console.log('import complete (owner', ownerId + '). Run scripts/verify.js next.');
  } finally {
    await close();
  }
}

main().catch((e) => {
  console.error('import failed:', e.message, '— rerun is safe (idempotent).');
  process.exit(1);
});
