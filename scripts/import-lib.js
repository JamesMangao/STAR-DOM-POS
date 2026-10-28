// scripts/import-lib.js — pure helpers for scripts/import.js.
//
// Nothing here talks to a database, the network or the filesystem outside the
// arguments it is given, so every rule below is unit-tested in
// scripts/import.test.js without touching the live project.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const NS = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'; // namespace URL

/** Deterministic uuid v5 — the same source id always yields the same PK. */
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

/** The opening-stock event for a product: stable id, so reruns dedupe. */
const stockImportId = (productId) => uuidV5(`stock_import:${productId}`);

/**
 * Is this money value exactly zero? Decimal-STRING test — money never goes
 * through a JS number, so `Number(v) === 0` is not used anywhere.
 */
function isZeroDecimal(v) {
  if (v === null || v === undefined) return true;
  const s = String(v).trim();
  if (s === '') return true;
  return /^[+-]?0*(?:\.0*)?$/.test(s);
}

/** is_active = the website flag AND a non-zero price (decision: zero -> hidden). */
function isActiveFor(price, isActive) {
  return Boolean(isActive) && !isZeroDecimal(price);
}

/**
 * The product's display image: the row flagged is_primary, else the lowest
 * sortorder (then id) so a product with no primary flag keeps its image.
 */
function pickImagePath(images, productId) {
  const mine = images.filter((i) => i.productid === productId);
  if (mine.length === 0) return null;
  const primary = mine.filter((i) => i.isprimary);
  const pool = primary.length ? primary : mine;
  const sorted = [...pool].sort(
    (a, b) =>
      (a.sortorder ?? 0) - (b.sortorder ?? 0) || (a.id ?? 0) - (b.id ?? 0),
  );
  return sorted[0].imagefile ?? null;
}

/**
 * Products may share a non-empty SKU, and `products` has a unique index on
 * (store_id, barcode). Keep the barcode on the FIRST product (by id) and null
 * it on the later duplicates so the import cannot abort halfway.
 */
function resolveBarcodes(products) {
  const seen = new Map();
  const duplicates = [];
  const rows = products.map((p) => {
    const sku = (p.sku ?? '').trim();
    if (!sku) return { ...p, barcode: null };
    if (!seen.has(sku)) {
      seen.set(sku, p.id);
      return { ...p, barcode: sku };
    }
    duplicates.push({ sku, keptOn: seen.get(sku), droppedFrom: p.id, name: p.name });
    return { ...p, barcode: null };
  });
  return { rows, duplicates };
}

const MAX_IMAGE_SIDE = 400;
const WEBP_QUALITY = 80;

/** Product images: fit inside 400x400, never enlarged, webp q80. */
async function resizeProductImage(buf) {
  const out = await sharp(buf)
    .resize({
      width: MAX_IMAGE_SIDE,
      height: MAX_IMAGE_SIDE,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .webp({ quality: WEBP_QUALITY })
    .toBuffer();
  const meta = await sharp(out).metadata();
  return { buffer: out, width: meta.width, height: meta.height, format: meta.format };
}

/**
 * Payment methods. Cash is POS-only; GCash and GoTyme come from the website's
 * paymentsettings export (account name + number are read from there — never
 * hard-coded in source), and the QR files are the exported PNGs, untouched.
 */
const CHANNEL_SLUG = { GCASH: 'gcash', GOTYME: 'gotyme' };

function paymentMethodsFromExport(settings, exportDir) {
  const rows = [
    {
      id: idOf('pm', 'cash'),
      name: 'Cash',
      type: 'cash',
      color: '#15803D',
      qrFile: null,
      qrObject: null,
      accountName: '',
      accountNumber: '',
      requireReference: false,
      isEnabled: true,
      sortOrder: 0,
    },
  ];
  let order = 1;
  for (const s of settings) {
    const channel = String(s.channel || '').toUpperCase();
    const slug = CHANNEL_SLUG[channel];
    if (!slug) continue;
    const qrFile = `qr_${slug}.png`;
    const qrPath = path.join(exportDir, qrFile);
    if (!fs.existsSync(qrPath)) {
      throw new Error(`missing exported QR file ${qrFile} (expected at ${qrPath})`);
    }
    rows.push({
      id: idOf('pm', slug),
      name: slug === 'gcash' ? 'GCash' : 'GoTyme',
      type: 'ewallet',
      color: slug === 'gcash' ? '#0070E0' : '#00A3A1',
      qrFile,
      qrObject: `payment/${slug}.png`,
      accountName: s.accountname ?? '',
      accountNumber: s.accountnumber ?? '',
      requireReference: true,
      isEnabled: s.isenabled !== false,
      sortOrder: order++,
    });
  }
  return rows;
}

/** The store row. Nothing invented: TIN, accreditation and address stay blank. */
function storeRow(storeId, ownerId) {
  return {
    id: storeId,
    name: 'ST⭐️R:Dom x ka1ofakind',
    tagline: 'Fast. Simple. Offline. Built for Filipino Small Businesses.',
    ownerId,
    receiptName: 'ST⭐️R:Dom x ka1ofakind Artisan Marketplace & Pop-up Tour',
    receiptTin: '',
    receiptAddress: '',
    receiptAccreditation: '',
    receiptFooter: 'Salamat sa pagtangkilik!',
    currency: 'PHP',
  };
}

/** The opening stock event for a product (delta = the website's stock). */
function stockImportEvent(product, productId, storeId) {
  return {
    id: stockImportId(productId),
    storeId,
    productId,
    delta: Number(product.stockquantity ?? 0),
    reason: 'import',
    orderId: null,
    deviceId: null,
  };
}

module.exports = {
  NS,
  MAX_IMAGE_SIDE,
  WEBP_QUALITY,
  uuidV5,
  idOf,
  stockImportId,
  isZeroDecimal,
  isActiveFor,
  pickImagePath,
  resolveBarcodes,
  resizeProductImage,
  paymentMethodsFromExport,
  storeRow,
  stockImportEvent,
};
