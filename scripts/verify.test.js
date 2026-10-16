// scripts/verify.test.js — A9. The verification EXPECTATIONS, tested against
// the real export plus a synthetic fixture. verify.js itself is not run here
// (it needs the post-import database).
//
//   node --test scripts/verify.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const lib = require('./verify-lib');
const manifest = require('./manifest');

function fixtureDir(products, categories = [], images = [], payments = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'verify-lib-'));
  const write = (name, rows) =>
    fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(rows), 'utf8');
  write('products', products);
  write('categories', categories);
  write('productimages', images);
  write('paymentsettings', payments);
  return dir;
}

test('the real export gives the expected totals', () => {
  const exp = lib.expectedFromExport(manifest.EXPORT_DIR);
  assert.equal(exp.products, 100);
  assert.equal(exp.categories, 11);
  assert.equal(exp.productImages, 58);
  assert.equal(exp.paymentSettings, 2);
  assert.equal(exp.tableCount, 13, '13 POS tables, not 12');
  assert.deepEqual(exp.ewalletChannels.sort(), ['GCASH', 'GOTYME']);
  assert.deepEqual(exp.qrFiles.sort(), ['qr_gcash.png', 'qr_gotyme.png']);
});

test('inactive products are DERIVED from the export, not hard-coded', () => {
  const dir = fixtureDir([
    { id: 1, baseprice: '30.00', isactive: true, stockquantity: 5 },
    { id: 2, baseprice: '30.00', isactive: false, stockquantity: 0 },
    { id: 3, baseprice: '0.00', isactive: true, stockquantity: 3 },
    { id: 4, baseprice: '0', isactive: false, stockquantity: 0 },
    { id: 5, baseprice: '12.50', isactive: true, stockquantity: 0 },
  ]);
  const exp = lib.expectedFromExport(dir);
  assert.equal(exp.products, 5);
  assert.equal(exp.zeroPriceProducts, 2);
  assert.deepEqual(exp.zeroPriceIds, [3, 4]);
  assert.equal(exp.inactiveProducts, 3, 'ids 2, 3, 4');
  assert.deepEqual(exp.inactiveIds, [2, 3, 4]);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('opening stock events = products whose stock is not zero', () => {
  const dir = fixtureDir([
    { id: 1, baseprice: '1.00', isactive: true, stockquantity: 7 },
    { id: 2, baseprice: '1.00', isactive: true, stockquantity: 0 },
    { id: 3, baseprice: '1.00', isactive: true, stockquantity: -2 },
    { id: 4, baseprice: '1.00', isactive: true, stockquantity: null },
  ]);
  const exp = lib.expectedFromExport(dir);
  assert.equal(exp.productsWithStock, 2, 'ids 1 and 3 (a negative count still gets an event)');
  assert.equal(exp.expectedImportStockEvents, 2);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('products with any image are counted from productimages', () => {
  const dir = fixtureDir(
    [{ id: 1, baseprice: '1', isactive: true, stockquantity: 0 }],
    [],
    [
      { id: 1, productid: 1, imagefile: 'a.png', isprimary: true, sortorder: 1 },
      { id: 2, productid: 1, imagefile: 'b.png', isprimary: false, sortorder: 2 },
      { id: 3, productid: 2, imagefile: 'c.png', isprimary: false, sortorder: 1 },
    ],
  );
  const exp = lib.expectedFromExport(dir);
  assert.equal(exp.productImages, 3);
  assert.equal(exp.productsWithAnyImage, 2);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('anon deny probes cover every POS table plus the derived view', () => {
  const probes = lib.anonDenyProbes();
  assert.equal(probes.length, lib.POS_TABLES.length + 1);
  assert.ok(probes.includes('order_status'), 'the view is probed too');
  for (const t of ['stores', 'orders', 'stock_events', 'day_closes', 'settings']) {
    assert.ok(probes.includes(t), `${t} probed`);
  }
});

test('verify.js signs in with the ANON client, never the service-role one', () => {
  const src = fs.readFileSync(path.join(__dirname, 'verify.js'), 'utf8');
  assert.ok(
    /anon\.auth\.signInWithPassword\(/.test(src),
    'the silent sign-in uses the anon client (the app\'s path)',
  );
  assert.ok(
    !/(admin|service)\.auth\.signInWithPassword\(/.test(src),
    'the service-role client must never sign in as the owner',
  );
  // The signup probe must delete the account it created and FAIL.
  assert.ok(/deleteUser\(signup\.data\.user\.id\)/.test(src));
  assert.ok(!/__pw/.test(src), 'the undefined __pw access is gone');
});

test('verify.js no longer hard-codes the inactive count', () => {
  const src = fs.readFileSync(path.join(__dirname, 'verify.js'), 'utf8');
  assert.ok(!/products inactive = 4/.test(src), 'the guess is gone');
  assert.ok(!/EXPECTED_TABLE_COUNT = 12/.test(src), 'the 12-table guess is gone');
});
