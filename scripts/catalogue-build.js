// scripts/catalogue-build.js — turn the ART Shop inventory spec into the
// canonical catalogue the app and the import script both read.
//
//   node scripts/catalogue-build.js           (build)
//   node scripts/catalogue-build.js --check   (verify the build is current)
//
// INPUTS
//   docs/inventory/ARTSHOP_DATABASE_2.md  the spec (rows, prices, stock, status)
//   assets/catalogue/image-map.json        which artwork belongs to which row
//   assets/Assets/                         the artwork itself
//
// OUTPUTS
//   assets/catalogue/catalogue.json        the catalogue (one source of truth)
//   assets/catalogue/images/<uuid>.webp    artwork, resized for the app
//
// DETERMINISTIC: every id is uuid v5 of a fixed namespace + a stable name, so
// a rebuild produces byte-identical output and the ids never change under a
// running app (the local seed and the server import agree by construction).
//
// The spec is the source of truth for the DATA. The image map is the source of
// truth for the MEDIA, because the artwork files are named after the designs
// ("Philippine Deer") and not after the rows ("Deer").
'use strict';

const fs = require('fs');
const path = require('path');

const { idOf, resizeProductImage, MAX_IMAGE_SIDE, WEBP_QUALITY } = require('./import-lib');

const ROOT = path.resolve(__dirname, '..');
const SPEC_PATH = path.join(ROOT, 'docs', 'inventory', 'ARTSHOP_DATABASE_2.md');
const MAP_PATH = path.join(ROOT, 'assets', 'catalogue', 'image-map.json');
const EXPORT_PATH = path.join(ROOT, 'supabase', 'export', 'products.json');
const OUT_DIR = path.join(ROOT, 'assets', 'catalogue');
const OUT_JSON = path.join(OUT_DIR, 'catalogue.json');
const OUT_IMAGES = path.join(OUT_DIR, 'images');
const ASSETS_ROOT = path.join(ROOT, 'assets', 'Assets');

/**
 * The POS categories, in booth order. `type` is the spec's own type name and
 * `typeSlug` the suffix the shop's website already uses for it ("sticker",
 * not "stickers"), so a product's slug is the same string the website uses.
 */
const CATEGORIES = [
  { slug: 'art-print', name: 'Art Print', sortOrder: 2, type: 'ART PRINT', typeSlug: 'art-print' },
  { slug: 'stickers', name: 'Stickers', sortOrder: 3, type: 'STICKER', typeSlug: 'sticker' },
  { slug: 'sticker-sheets', name: 'Sticker Sheets', sortOrder: 4, type: 'STICKER SHEETS', typeSlug: 'sticker-sheets' },
  { slug: 'keychains', name: 'Keychains', sortOrder: 5, type: 'KEYCHAINS', typeSlug: 'keychains' },
  { slug: 'button-pins', name: 'Button Pins', sortOrder: 6, type: 'BUTTON PINS', typeSlug: 'button-pins' },
  { slug: 'temp-tattoos', name: 'Temp Tattoos', sortOrder: 7, type: 'TEMP TATTOOS', typeSlug: 'temp-tattoos' },
  { slug: 'clay-deskbuddies', name: 'Clay Deskbuddies', sortOrder: 8, type: 'CLAY DESKBUDDIES', typeSlug: 'clay-deskbuddies' },
  { slug: 'clay-pins', name: 'Clay Pins', sortOrder: 9, type: 'CLAY PINS', typeSlug: 'clay-pins' },
];

const CAT_BY_TYPE = new Map(CATEGORIES.map((c) => [c.type, c]));

// ---------------------------------------------------------------- spec parse

/** Split a markdown table row into trimmed cells (| a | b | -> ['a','b']). */
function cells(line) {
  return line
    .replace(/^\s*\|/, '')
    .replace(/\|\s*$/, '')
    .split('|')
    .map((c) => c.trim());
}

/** A cell the source left empty (the placeholder was "Notes" / "Item ID"). */
function isEmpty(v) {
  return v === '' || v === '—' || v === '-';
}

/**
 * Parse the spec into { types: [...], rows: [...], bundles: [...] }.
 *
 * Sections are `## <TYPE>` (optionally with a " (₱30.00 each)" hint) and
 * hold a 7-column table. The bundle table has 4 columns and its own header.
 */
function parseSpec(md) {
  const lines = md.split(/\r?\n/);
  const types = [];
  const rows = [];
  const bundles = [];

  // 'bundles' or a spec type name; null = prose section (no table of ours).
  let section = null;
  let expectHeader = false;

  for (const line of lines) {
    const h = /^##\s+(.+?)\s*$/.exec(line);
    if (h) {
      const heading = h[1];
      if (heading === 'Bundle deals') {
        section = 'bundles';
        expectHeader = true;
        continue;
      }
      if (heading === 'Schema' || heading === 'Data caveats') {
        section = null;
        continue;
      }
      const type = heading.replace(/\s*\(.*\)\s*$/, '').trim();
      section = type;
      types.push(type);
      expectHeader = true;
      continue;
    }

    if (!line.trim().startsWith('|')) continue;

    const c = cells(line);
    const isSeparator = c.every((x) => /^:?-{2,}:?$/.test(x) || x === '');
    if (isSeparator) continue;

    // The first row of every table is its header — never data.
    if (expectHeader) {
      expectHeader = false;
      continue;
    }

    if (section === 'bundles') {
      // | Name | any N | ₱P | TYPES |
      const name = c[0];
      const qty = Number((/any\s+(\d+)/i.exec(c[1]) || [])[1]);
      const price = Number(c[2].replace(/[^\d.]/g, ''));
      const types = c[3]
        .replace(/\(.*?\)/g, '') // "(assumed from bundle name)"
        .split(',')
        .map((t) => t.trim())
        .filter(Boolean);
      bundles.push({ name, quantity: qty, price, types });
      continue;
    }

    if (!section) continue;
    if (c.length < 7) continue;

    const [id, name, price, stock, status, notes, col1] = c;
    rows.push({
      type: section,
      ref: isEmpty(id) ? null : id,
      name,
      price: price === 'unknown' ? null : Number(price),
      stock: stock === 'unknown' ? null : Number(stock),
      status,
      notes: isEmpty(notes) ? null : notes,
      col1: isEmpty(col1) ? null : Number(col1),
    });
  }

  return { types, rows, bundles };
}

// ------------------------------------------------------------------ helpers

/**
 * The slug of a product: its name plus the shelf it lives on.
 *
 * "Bleeding heart" on the sticker shelf is "bleeding-heart-stickers". The slug
 * is the product's IDENTITY in this catalogue: the product's primary key is
 * uuid v5 of the slug, so re-ordering the sheet never changes an id, and a
 * row that is added in the middle does not shift the ids of the rows below
 * it. (The old scheme used the row number, which shifted everything.)
 */
function slugify(name) {
  return String(name)
    .toLowerCase()
    .replace(/['"‘’`]/g, '') // Trees (4x6") -> trees (4x6)
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

/** A name as a key: case, spacing and punctuation-insensitive. */
function nameKey(name) {
  return String(name || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

/** The website's own product ids, by (type, name) — used ONLY for barcodes. */
function exportSkus() {
  if (!fs.existsSync(EXPORT_PATH)) return new Map();
  const rows = JSON.parse(fs.readFileSync(EXPORT_PATH, 'utf8'));
  const out = new Map();
  for (const p of rows) {
    const type = typeFromSlug(p.slug);
    if (!type) continue;
    const key = `${type}|${nameKey(p.name)}`;
    if (!out.has(key)) out.set(key, p);
  }
  return out;
}

/**
 * The inventory type of a website product, from its slug ("goby-keychains").
 *
 * The website's own suffixes are the authority here — they are the shop's
 * existing taxonomy ("goby-sticker", "pigeon-temp-tattoos"), and the longest
 * suffix wins so "love-sticker-sheets" is a SHEET, not a sticker.
 */
const WEBSITE_TYPE_SUFFIX = {
  'art-print': 'ART PRINT',
  'sticker-sheets': 'STICKER SHEETS',
  'sticker': 'STICKER',
  keychains: 'KEYCHAINS',
  'button-pins': 'BUTTON PINS',
  'temp-tattoos': 'TEMP TATTOOS',
  'clay-deskbuddies': 'CLAY DESKBUDDIES',
  'clay-pins': 'CLAY PINS',
};

function typeFromSlug(slug) {
  const s = String(slug || '');
  let best = null;
  for (const suffix of Object.keys(WEBSITE_TYPE_SUFFIX)) {
    const full = '-' + suffix;
    if (s.endsWith(full) && (!best || full.length > best.length)) best = full;
  }
  if (!best) return null;
  return WEBSITE_TYPE_SUFFIX[best.slice(1)];
}

/** The website's own slug for a product, by (type, name) — for the report. */
function exportSlugs() {
  if (!fs.existsSync(EXPORT_PATH)) return new Map();
  const rows = JSON.parse(fs.readFileSync(EXPORT_PATH, 'utf8'));
  const out = new Map();
  for (const p of rows) {
    const type = typeFromSlug(p.slug);
    if (!type) continue;
    const key = `${type}|${nameKey(p.name)}`;
    if (!out.has(key)) out.set(key, p.slug);
  }
  return out;
}

/** Every file under assets/Assets, as POSIX paths relative to that root. */
function listAssetFiles(dir, base = '') {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...listAssetFiles(path.join(dir, entry.name), rel));
    else out.push(rel);
  }
  return out;
}

// -------------------------------------------------------------------- build

async function build() {
  const md = fs.readFileSync(SPEC_PATH, 'utf8');
  const imageMap = JSON.parse(fs.readFileSync(MAP_PATH, 'utf8'));
  const { types, rows, bundles } = parseSpec(md);

  // Every spec type needs a category, and every category needs products.
  for (const t of types) {
    if (!CAT_BY_TYPE.has(t)) throw new Error(`spec type "${t}" has no category`);
  }
  for (const c of CATEGORIES) {
    if (!types.includes(c.type)) throw new Error(`category "${c.slug}" has no rows`);
  }

  // Categories: uuid v5 of the slug, so the id survives a rebuild.
  const categories = CATEGORIES.map((c) => ({
    id: idOf('categories', c.slug),
    slug: c.slug,
    name: c.name,
    sortOrder: c.sortOrder,
    type: c.type,
  }));

  const products = [];
  const usedImages = new Set();
  const skus = exportSkus();
  const slugs = exportSlugs();
  const usedBarcodes = new Set();
  let ordinal = 0;
  let slugMatches = 0;
  let skuMatches = 0;

  for (const r of rows) {
    ordinal += 1;
    const cat = CAT_BY_TYPE.get(r.type);
    const key = `${r.type}|${r.name}`;
    if (!(key in imageMap)) {
      throw new Error(`image map has no entry for "${key}"`);
    }
    const imageSource = imageMap[key];
    if (imageSource) {
      const disk = path.join(ASSETS_ROOT, imageSource);
      if (!fs.existsSync(disk)) {
        throw new Error(`image file missing on disk: ${imageSource} (for ${key})`);
      }
      usedImages.add(imageSource);
    }

    // The identity of the row: its name on its shelf. The id follows from
    // it, so the row keeps its primary key when the sheet is re-ordered.
    const slug = `${slugify(r.name)}-${cat.typeSlug}`;
    const id = idOf('products', slug);

    // The barcode is the shop's own SKU when the website knows this product
    // (matched by type + name), so an old label still scans. It NEVER
    // influences the id.
    const webKey = `${r.type}|${nameKey(r.name)}`;
    const webSku = skus.get(webKey);
    let barcode = webSku ? String(webSku.sku || '').trim() : '';
    if (!barcode) barcode = `SKU-AS-${slug.toUpperCase()}`;
    if (usedBarcodes.has(barcode)) {
      throw new Error(`duplicate barcode "${barcode}" (row "${r.type} | ${r.name}")`);
    }
    usedBarcodes.add(barcode);
    if (webSku) skuMatches += 1;
    if (slugs.get(webKey) === slug) slugMatches += 1;

    products.push({
      id,
      slug,
      sourceId: ordinal,
      ref: r.ref,
      type: r.type,
      category: cat.slug,
      name: r.name,
      price: r.price,
      stock: r.stock,
      status: r.status,
      notes: r.notes,
      col1: r.col1,
      barcode,
      imageSource,
      imageAsset: imageSource ? `assets/catalogue/images/${id}.webp` : null,
    });
  }

  const catalogue = {
    version: 2,
    source: 'ARTSHOP_DATABASE_2_pdf.pdf',
    spec: 'docs/inventory/ARTSHOP_DATABASE_2.md',
    currency: 'PHP',
    imageMaxSide: MAX_IMAGE_SIDE,
    imageQuality: WEBP_QUALITY,
    // The shop itself. The same row the server import writes, so the app's
    // local copy and the server's copy are the SAME row (same id) and merge
    // instead of duplicating.
    store: {
      id: idOf('store', 'main'),
      name: 'ST⭐️R:Dom x ka1ofakind',
      tagline: 'Fast. Simple. Offline. Built for Filipino Small Businesses.',
      receiptName: 'ST⭐️R:Dom x ka1ofakind Artisan Marketplace & Pop-up Tour',
      receiptTin: '',
      receiptAddress: '',
      receiptAccreditation: '',
      receiptFooter: 'Salamat sa pagtangkilik!',
      currency: 'PHP',
    },
    categories,
    products,
    bundles: bundles.map((b) => ({
      name: b.name,
      quantity: b.quantity,
      price: b.price,
      types: b.types,
    })),
  };

  // --- images
  fs.mkdirSync(OUT_IMAGES, { recursive: true });
  let written = 0;
  let bytes = 0;
  for (const p of products) {
    if (!p.imageSource) continue;
    const src = path.join(ASSETS_ROOT, p.imageSource);
    const dst = path.join(OUT_IMAGES, `${p.id}.webp`);
    const resized = await resizeProductImage(fs.readFileSync(src));
    fs.writeFileSync(dst, resized.buffer);
    written += 1;
    bytes += resized.buffer.length;
  }

  // Files in the assets folder that no row uses: reported, never deleted.
  const unused = listAssetFiles(ASSETS_ROOT).filter(
    (f) => !usedImages.has(f) && !f.startsWith('Payment/'),
  );

  // Artwork of a product that no longer exists (the id scheme changed, or a
  // row was dropped) is removed: the folder must hold exactly the current
  // catalogue, or the app bundle ships dead weight.
  const keep = new Set(products.filter((p) => p.imageAsset).map((p) => path.basename(p.imageAsset)));
  let removed = 0;
  for (const f of fs.readdirSync(OUT_IMAGES)) {
    if (keep.has(f)) continue;
    fs.unlinkSync(path.join(OUT_IMAGES, f));
    removed += 1;
  }
  if (removed) console.log(`  stale artwork removed: ${removed}`);

  const json = `${JSON.stringify(catalogue, null, 2)}\n`;
  const current = fs.existsSync(OUT_JSON) ? fs.readFileSync(OUT_JSON, 'utf8') : null;
  const changed = current !== json;

  if (process.argv.includes('--check')) {
    if (changed) {
      console.error('catalogue.json is OUT OF DATE — run: node scripts/catalogue-build.js');
      process.exit(1);
    }
    console.log('catalogue.json is up to date');
    return;
  }

  fs.writeFileSync(OUT_JSON, json);

  console.log('catalogue built from docs/inventory/ARTSHOP_DATABASE_2.md');
  console.log(`  categories : ${categories.length}`);
  console.log(`  products   : ${products.length}`);
  console.log(`  bundles    : ${catalogue.bundles.length}`);
  console.log(`  images     : ${written} written (${(bytes / 1024).toFixed(0)} KiB total)`);
  console.log(`  no image   : ${products.length - written}`);
  console.log(`  barcodes   : ${skuMatches} from the website's SKU, ${products.length - skuMatches} derived`);
  console.log(`  slugs      : ${slugMatches}/${products.length} identical to the website's own slug`);
  if (unused.length) {
    console.log(`  unused artwork (not deleted): ${unused.join(', ')}`);
  }
  console.log(`  wrote      : ${path.relative(ROOT, OUT_JSON)}`);
}

build().catch((e) => {
  console.error('catalogue build failed:', e.message);
  process.exit(1);
});
