// scripts/export.js — Step A: READ-ONLY export of the retired website tables.
//
//   node scripts/export.js
//
// Dumps Products, Categories, ProductImages and PaymentSettings to
// supabase/export/*.json, extracts the QR BYTEA columns to qr_gcash.png and
// qr_gotyme.png, and writes supabase/export/manifest.json (counts + sha256).
//
// READ-ONLY: the session sets default_transaction_read_only=on and wraps the
// work in BEGIN READ ONLY (see scripts/pg.js). Every statement here is a
// SELECT; a write would be rejected by the server before it ran.
'use strict';

const fs = require('fs');
const { readOnlyClient } = require('./pg');
const manifest = require('./manifest');

const Q = {
  products: `select json_agg(row_to_json(t)) as rows from (
      select id, name, baseprice, stockquantity, sku, categoryid, isactive, slug
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

async function main() {
  fs.mkdirSync(manifest.EXPORT_DIR, { recursive: true });
  const { client, close } = await readOnlyClient();
  try {
    for (const [name, sql] of Object.entries(Q)) {
      const res = await client.query(sql);
      const rows = res.rows[0].rows || [];
      fs.writeFileSync(
        `${manifest.EXPORT_DIR}/${name}.json`,
        JSON.stringify(rows, null, 2),
        'utf8',
      );
      console.log(`${name}.json: ${rows.length} rows`);
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
      fs.writeFileSync(`${manifest.EXPORT_DIR}/qr_${slug}.png`, buf);
      console.log(
        `qr_${slug}.png: ${buf.length} bytes, ${r.qrimagemime}, magic=${r.magic}`,
      );
    }
  } finally {
    await close();
  }

  const m = manifest.write();
  console.log('manifest:', JSON.stringify(m.counts));
  console.log(
    'manifest.json sha256:',
    Object.entries(m.files)
      .map(([k, v]) => `${k}=${v.sha256.slice(0, 16)}…`)
      .join(' '),
  );
}

main().catch((e) => {
  console.error('export failed:', e.message);
  process.exit(1);
});
