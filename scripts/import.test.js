// scripts/import.test.js — A8. The import rules, tested without a database,
// a network or the live project.
//
//   node --test scripts/import.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const lib = require('./import-lib');
const manifest = require('./manifest');

test('opening stock: delta is the website stock, and the id is stable', () => {
  const p = { id: 7, stockquantity: 12 };
  const productId = lib.idOf('products', p.id);
  const ev = lib.stockImportEvent(p, productId, 'store-1');
  assert.equal(ev.delta, 12);
  assert.equal(ev.reason, 'import');
  assert.equal(ev.deviceId, null);
  assert.equal(ev.orderId, null);
  assert.equal(ev.id, lib.stockImportId(productId));
  // deterministic: a rerun targets the same row, so ON CONFLICT dedupes it
  assert.equal(lib.stockImportEvent(p, productId, 'store-1').id, ev.id);
});

test('price 0 hides the product; a non-zero price with isactive=false stays hidden', () => {
  assert.equal(lib.isZeroDecimal('0.00'), true);
  assert.equal(lib.isZeroDecimal('0'), true);
  assert.equal(lib.isZeroDecimal('0.01'), false);
  assert.equal(lib.isActiveFor('0.00', true), false, 'zero price -> hidden');
  assert.equal(lib.isActiveFor('30.00', false), false, 'website flag false -> hidden');
  assert.equal(lib.isActiveFor('30.00', true), true);
});

test('image pick: primary wins, else the lowest sortorder keeps its image', () => {
  const images = [
    { id: 1, productid: 9, imagefile: 'a.png', isprimary: false, sortorder: 55 },
    { id: 2, productid: 9, imagefile: 'b.png', isprimary: false, sortorder: 3 },
    { id: 3, productid: 9, imagefile: 'c.png', isprimary: true, sortorder: 999 },
    { id: 4, productid: 10, imagefile: 'd.png', isprimary: false, sortorder: 5 },
    { id: 5, productid: 10, imagefile: 'e.png', isprimary: false, sortorder: 2 },
  ];
  assert.equal(lib.pickImagePath(images, 9), 'c.png', 'primary beats sortorder');
  assert.equal(lib.pickImagePath(images, 10), 'e.png', 'no primary -> lowest sortorder');
  assert.equal(lib.pickImagePath(images, 404), null);
  assert.equal(lib.pickImagePath([], 9), null);
});

test('duplicate SKUs: the first keeps the barcode, later ones are nulled and reported', () => {
  const products = [
    { id: 1, sku: 'SKU-A', name: 'First' },
    { id: 2, sku: 'SKU-A', name: 'Second' },
    { id: 3, sku: 'SKU-B', name: 'Third' },
    { id: 4, sku: '', name: 'No sku' },
    { id: 5, sku: '  ', name: 'Blank sku' },
  ];
  const { rows, duplicates } = lib.resolveBarcodes(products);
  assert.deepEqual(rows.map((r) => r.barcode), ['SKU-A', null, 'SKU-B', null, null]);
  assert.equal(duplicates.length, 1);
  assert.deepEqual(duplicates[0], {
    sku: 'SKU-A', keptOn: 1, droppedFrom: 2, name: 'Second',
  });
});

test('product image resize: fits inside 400x400 as webp, never enlarged', async () => {
  const big = await sharp({
    create: { width: 1200, height: 1600, channels: 3, background: '#ffffff' },
  })
    .png()
    .toBuffer();
  const out = await lib.resizeProductImage(big);
  assert.equal(out.format, 'webp');
  assert.ok(out.width <= lib.MAX_IMAGE_SIDE, `width ${out.width} <= 400`);
  assert.ok(out.height <= lib.MAX_IMAGE_SIDE, `height ${out.height} <= 400`);
  assert.ok(out.buffer.length < big.length, 'the resized image is smaller');

  const small = await sharp({
    create: { width: 64, height: 48, channels: 3, background: '#ffffff' },
  })
    .png()
    .toBuffer();
  const out2 = await lib.resizeProductImage(small);
  assert.equal(out2.width, 64, 'withoutEnlargement keeps a small image small');
  assert.equal(out2.height, 48);
});

test('payment methods come from the export: QR files exist and no number is hard-coded', () => {
  const settings = [
    { id: 1, channel: 'GCASH', accountname: 'EXPORT NAME', accountnumber: '0000 000 0000', isenabled: true },
    { id: 2, channel: 'GOTYME', accountname: 'EXPORT NAME', accountnumber: '1111 111 1111', isenabled: false },
  ];
  const rows = lib.paymentMethodsFromExport(settings, manifest.EXPORT_DIR);
  const byName = Object.fromEntries(rows.map((r) => [r.name, r]));
  assert.deepEqual(Object.keys(byName).sort(), ['Cash', 'GCash', 'GoTyme']);

  assert.equal(byName.GCash.accountNumber, '0000 000 0000', 'number comes from the export');
  assert.equal(byName.GoTyme.accountNumber, '1111 111 1111', 'GoTyme number is not blank-ed in code');
  assert.equal(byName.GoTyme.isEnabled, false, 'isenabled is honoured');
  assert.equal(byName.Cash.qrObject, null);
  assert.equal(byName.Cash.sortOrder, 0);

  // The QR paths point at the files the export actually wrote.
  for (const r of [byName.GCash, byName.GoTyme]) {
    assert.ok(r.qrFile.startsWith('qr_'), `qr file name ${r.qrFile}`);
    assert.ok(
      fs.existsSync(path.join(manifest.EXPORT_DIR, r.qrFile)),
      `${r.qrFile} exists in the export`,
    );
    const buf = fs.readFileSync(path.join(manifest.EXPORT_DIR, r.qrFile));
    assert.equal(buf.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', 'PNG magic');
  }

  // A missing QR must fail loudly instead of uploading nothing.
  assert.throws(
    () => lib.paymentMethodsFromExport(settings, path.join(manifest.EXPORT_DIR, 'nope')),
    /missing exported QR file/,
  );
});

test('no personal account number is hard-coded in the import source', () => {
  const src = fs.readFileSync(path.join(__dirname, 'import.js'), 'utf8');
  assert.ok(!/\d{4}\s?\d{3}\s?\d{4}/.test(src), 'no phone-style account number in source');
  assert.ok(!/RIAN DOMINIC/.test(src), 'no account holder name in source');
  const libSrc = fs.readFileSync(path.join(__dirname, 'import-lib.js'), 'utf8');
  assert.ok(!/\d{4}\s?\d{3}\s?\d{4}/.test(libSrc));
});

test('store row invents nothing: TIN, accreditation and address are blank', () => {
  const s = lib.storeRow('store-1', 'owner-1');
  assert.equal(s.receiptTin, '');
  assert.equal(s.receiptAccreditation, '');
  assert.equal(s.receiptAddress, '');
  assert.equal(s.ownerId, 'owner-1');
});

test('the receipt title is never "Official Receipt" anywhere in source', () => {
  const files = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (['node_modules', '.dart_tool', 'build', '.git'].includes(e.name)) continue;
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      // Test files name the forbidden phrase in their own assertions.
      else if (/\.(dart|js)$/.test(e.name) && !e.name.endsWith('.test.js')) files.push(p);
    }
  };
  walk(path.resolve(__dirname, '..', 'lib'));
  walk(__dirname);
  const offenders = files.filter((f) => /Official\s+Receipt/i.test(fs.readFileSync(f, 'utf8')));
  assert.deepEqual(offenders, [], 'use "Sales Receipt", never "Official Receipt"');
});
