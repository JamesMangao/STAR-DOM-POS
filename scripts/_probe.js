// TEMP read-only probe of the live Supabase schema + catalogue state.
'use strict';
const { readOnlyClient } = require('./pg');

(async () => {
  const { client, close } = await readOnlyClient();
  const q = async (sql, params) => (await client.query(sql, params)).rows;

  for (const t of ['categories', 'products', 'productimages', 'stock_events', 'settings', 'stores', 'payment_methods']) {
    const cols = await q(
      `select column_name, data_type from information_schema.columns
        where table_schema = 'public' and table_name = $1 order by ordinal_position`,
      [t],
    );
    console.log('==', t, '==', cols.length ? cols.map((c) => c.column_name + ':' + c.data_type).join(', ') : '(missing)');
  }

  console.log('\n--- counts ---');
  for (const t of ['products', 'categories', 'productimages', 'stock_events', 'orders']) {
    try {
      const r = await q(`select count(*)::int c from ${t}`);
      console.log(t, r[0].c);
    } catch (e) { console.log(t, 'ERR', e.message); }
  }

  console.log('\n--- categories ---');
  console.log(JSON.stringify(await q('select * from categories order by id'), null, 1));

  console.log('\n--- products (first 15) ---');
  console.log(JSON.stringify(await q('select id,name,price,stock_quantity,image_path,category_id,is_active,barcode from products order by id limit 15'), null, 1));

  console.log('\n--- productimages (first 8) ---');
  console.log(JSON.stringify(await q('select * from productimages order by id limit 8'), null, 1));

  console.log('\n--- settings ---');
  console.log(JSON.stringify(await q('select * from settings'), null, 1));

  console.log('\n--- stores ---');
  console.log(JSON.stringify(await q('select id,name,owner_id,currency from stores'), null, 1));

  await close();
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
