// TEMP read-only: does the live website DB still match supabase/export/,
// and does it hold rows the export does not (drift / real sales)?
'use strict';
const fs = require('fs');
const path = require('path');
const { readOnlyClient } = require('./pg');

const EXPORT_DIR = path.resolve(__dirname, '..', 'supabase', 'export');
const readJson = (n) => JSON.parse(fs.readFileSync(path.join(EXPORT_DIR, `${n}.json`), 'utf8'));

(async () => {
  const { client, close } = await readOnlyClient();
  const q = async (sql, params) => (await client.query(sql, params)).rows;

  // --- row counts for every website table that can hold real activity
  const tables = (await q(
    `select table_name from information_schema.tables
      where table_schema='public' and table_type='BASE TABLE' order by table_name`)).map((r) => r.table_name);
  const counts = [];
  for (const t of tables) {
    const r = await q(`select count(*)::int c from "${t}"`);
    if (r[0].c > 0) counts.push(`${t}=${r[0].c}`);
  }
  console.log('non-empty website tables:', counts.length ? counts.join(', ') : '(none)');

  // --- drift: live products vs exported products
  const live = await q('select id, name, baseprice, stockquantity, sku, categoryid, isactive from products order by id');
  const exp = readJson('products');
  const expById = new Map(exp.map((p) => [p.id, p]));
  const liveById = new Map(live.map((p) => [p.id, p]));

  const added = live.filter((p) => !expById.has(p.id)).map((p) => `${p.id}:${p.name}`);
  const removed = exp.filter((p) => !liveById.has(p.id)).map((p) => `${p.id}:${p.name}`);
  const changed = [];
  for (const p of live) {
    const e = expById.get(p.id);
    if (!e) continue;
    const diffs = [];
    if (String(p.name) !== String(e.name)) diffs.push(`name "${e.name}"->"${p.name}"`);
    if (Number(p.baseprice) !== Number(e.baseprice)) diffs.push(`price ${e.baseprice}->${p.baseprice}`);
    if (Number(p.stockquantity) !== Number(e.stockquantity)) diffs.push(`stock ${e.stockquantity}->${p.stockquantity}`);
    if (p.categoryid !== e.categoryid) diffs.push(`cat ${e.categoryid}->${p.categoryid}`);
    if (!!p.isactive !== !!e.isactive) diffs.push(`active ${e.isactive}->${p.isactive}`);
    if (diffs.length) changed.push(`${p.id}:${p.name} [${diffs.join(', ')}]`);
  }
  console.log('\nproducts — live:', live.length, 'export:', exp.length);
  console.log('  added since export  :', added.length ? added.join(' | ') : 'none');
  console.log('  removed since export:', removed.length ? removed.join(' | ') : 'none');
  console.log('  changed since export:', changed.length ? changed.join('\n                       ') : 'none');

  // --- categories / images drift
  const liveCats = await q('select id, name, displayorder, isactive from categories order by id');
  const expCats = readJson('categories');
  console.log('\ncategories — live:', liveCats.length, 'export:', expCats.length);
  const catDrift = liveCats.filter((c) => {
    const e = expCats.find((x) => x.id === c.id);
    return !e || e.name !== c.name || e.displayorder !== c.displayorder || !!e.isactive !== !!c.isactive;
  }).map((c) => `${c.id}:${c.name}`);
  console.log('  category drift:', catDrift.length ? catDrift.join(' | ') : 'none');

  const liveImgs = await q('select id, productid, imagefile from productimages order by id');
  const expImgs = readJson('productimages');
  const imgDrift = liveImgs.filter((i) => {
    const e = expImgs.find((x) => x.id === i.id);
    return !e || e.productid !== i.productid || e.imagefile !== i.imagefile;
  }).map((i) => `${i.id}:${i.imagefile}`);
  console.log('\nproductimages — live:', liveImgs.length, 'export:', expImgs.length);
  console.log('  image drift:', imgDrift.length ? imgDrift.join(' | ') : 'none');

  // --- auth users (the owner) — does a user exist already?
  try {
    const users = await q('select id, email, created_at from auth.users order by created_at');
    console.log('\nauth.users:', users.length);
    users.forEach((u) => console.log('  ', u.email, u.created_at.toISOString()));
  } catch (e) { console.log('\nauth.users: ERR', e.message); }

  await close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
