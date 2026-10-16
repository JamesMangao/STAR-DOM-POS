// scripts/verify-lib.js — expectations for scripts/verify.js, computed from the
// EXPORT rather than hard-coded. Everything here is pure: it reads the export
// files and returns numbers, so it is unit-tested without a database.
'use strict';

const fs = require('fs');
const path = require('path');
const { isZeroDecimal } = require('./import-lib');

const POS_TABLES = [
  'stores', 'devices', 'categories', 'products', 'payment_methods', 'settings',
  'orders', 'order_items', 'payments', 'order_voids', 'stock_events',
  'day_closes', 'sync_outbox',
];

function readJson(dir, name) {
  return JSON.parse(fs.readFileSync(path.join(dir, `${name}.json`), 'utf8'));
}

/**
 * What the POS database must contain after a correct import. The inactive and
 * stock numbers are DERIVED: the old `products inactive = 4` was a guess.
 */
function expectedFromExport(exportDir) {
  const products = readJson(exportDir, 'products');
  const categories = readJson(exportDir, 'categories');
  const images = readJson(exportDir, 'productimages');
  const payments = readJson(exportDir, 'paymentsettings');

  const zeroPrice = products.filter((p) => isZeroDecimal(p.baseprice));
  const inactive = products.filter((p) => !p.isactive || isZeroDecimal(p.baseprice));
  const withStock = products.filter((p) => Number(p.stockquantity ?? 0) !== 0);
  const withImage = new Set(images.map((i) => i.productid)).size;

  return {
    products: products.length,
    categories: categories.length,
    productImages: images.length,
    paymentSettings: payments.length,
    zeroPriceProducts: zeroPrice.length,
    zeroPriceIds: zeroPrice.map((p) => p.id),
    inactiveProducts: inactive.length,
    inactiveIds: inactive.map((p) => p.id),
    productsWithStock: withStock.length,
    expectedImportStockEvents: withStock.length,
    productsWithAnyImage: withImage,
    // website channels that must exist as POS payment methods
    ewalletChannels: payments.map((p) => String(p.channel).toUpperCase()),
    qrFiles: payments.map((p) => `qr_${String(p.channel).toLowerCase()}.png`),
    tableCount: POS_TABLES.length,
  };
}

/** Tables anon must not be able to read, plus the derived view. */
function anonDenyProbes() {
  return [...POS_TABLES, 'order_status'];
}

module.exports = { POS_TABLES, readJson, expectedFromExport, anonDenyProbes };
