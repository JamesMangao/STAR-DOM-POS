// scripts/export.js — Step A: READ-ONLY export of the retired website tables.
//
//   node scripts/export.js                 -> supabase/export/
//   node scripts/export.js --out <dir>      -> an alternate directory (diff first)
//
// Dumps Products, Categories, ProductImages and PaymentSettings to *.json,
// extracts the QR BYTEA columns to qr_gcash.png / qr_gotyme.png, and writes
// manifest.json (source host label + counts + sha256 of every file).
//
// MONEY NEVER TOUCHES A JS NUMBER. `numeric(10,2)` money columns are cast to
// ::text inside the query, so the JSON carries the exact decimal string the
// database produced ("30.00") and nothing downstream can round it. The guard
// below fails the export if a money column ever arrives as a JS number again.
//
// READ-ONLY: the session sets default_transaction_read_only=on and wraps the
// work in BEGIN READ ONLY (see scripts/pg.js). A write would be rejected by
// the server before it ran.
'use strict';

const fs = require('fs');
const path = require('path');
const { readOnlyClient, hostLabel } = require('./pg');
const manifest = require('./manifest');

// numeric(10,2) columns, cast to text in the SELECT below.
const MONEY = { products: ['baseprice'] };

const Q = {
  products: `select json_agg(row_to_json(t)) as rows from (
      select id, name, baseprice::text as baseprice, stockquantity, sku,
             categoryid, isactive, slug
      from products order by id) t`,
  categories: `select json_agg(row_to_json(t)) as rows from (
      select id, name, slug, displayorder, isactive, parentid
      from categories order by displayorder, id) t`,
  productimages: `select json_agg(row_to_json(t)) as rows from (
      select id, productid, imagefile, isprimary, sortorder
      from productimages order by id) t`,
  paymentsettings: `select json_agg(row_to_json(t)) as rows from (
      select id, channel, accountname, accountnumber, qrimagefile,
             qrimagemime, isenabled, updatedby, updatedat
      from paymentsettings order by id) t`,
};

function outDir(argv) {
  const i = argv.indexOf('--out');
  return i >= 0 && argv[i + 1] ? path.resolve(argv[i + 1]) : manifest.EXPORT_DIR;
}

/** Refuse to ship money that went through a JS float. */
function assertMoneyIsText(name, rows) {
  for (const col of MONEY[name] || []) {
    const bad = rows.find((r) => typeof r[col] !== 'string');
    if (bad) {
      throw new Error(
        `${name}.${col} arrived as a JS ${typeof bad[col]} — money must be ::text`,
      );
    }
  }
}

async function main() {
  const OUT = outDir(process.argv.slice(2));
  fs.mkdirSync(OUT, { recursive: true });
  console.log('exporting to', OUT);

  const host = hostLabel();
  const { client, close } = await readOnlyClient();
  try {
    for (const [name, sql] of Object.entries(Q)) {
      const res = await client.query(sql);
      const rows = res.rows[0].rows || [];
      assertMoneyIsText(name, rows);
      fs.writeFileSync(path.join(OUT, `${name}.json`), JSON.stringify(rows, null, 2), 'utf8');
      const money = MONEY[name] ? ` money=${MONEY[name].map((c) => `${c}:text`).join(',')}` : '';
      console.log(`${name}.json: ${rows.length} rows${money}`);
    }

    const qr = await client.query(
      `select channel, qrimagemime, qrimagedata,
              length(qrimagedata) as bytes,
              encode(substring(qrimagedata from 1 for 8), 'hex') as magic
         from paymentsettings order by id`,
    );
    for (const r of qr.rows) {
      const slug = r.channel.toLowerCase() === 'gcash' ? 'gcash' : 'gotyme';
      const buf = r.qrimagedata;
      fs.writeFileSync(path.join(OUT, `qr_${slug}.png`), buf);
      console.log(`qr_${slug}.png: ${buf.length} bytes, ${r.qrimagemime}, magic=${r.magic}`);
    }
  } finally {
    await close();
  }

  const m = manifest.write(OUT, { source: host });
  console.log('manifest:', JSON.stringify(m.counts), 'source:', m.source);
}

main().catch((e) => {
  console.error('export failed:', e.message);
  process.exit(1);
});
