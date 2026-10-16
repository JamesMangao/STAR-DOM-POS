// scripts/db-facts.js — Step 3b: READ-ONLY facts about the live project.
//
//   node scripts/db-facts.js
//
// Same read-only enforcement as export.js (default_transaction_read_only=on +
// BEGIN READ ONLY). Prints raw rows; prints no credential values.
'use strict';

const { readOnlyClient } = require('./pg');

async function safe(client, label, sql, params = []) {
  try {
    const res = await client.query(sql, params);
    console.log(`\n===== ${label} =====`);
    console.log(JSON.stringify(res.rows, null, 2));
  } catch (e) {
    console.log(`\n===== ${label} =====`);
    console.log(`(not available: ${e.message})`);
  }
}

async function main() {
  const { client, close } = await readOnlyClient();
  try {
    await safe(
      client,
      'public base tables',
      `select count(*)::int as tables from information_schema.tables
        where table_schema='public' and table_type='BASE TABLE'`,
    );
    await safe(
      client,
      'table list',
      `select c.relname as table_name, c.reltuples::bigint as est_rows
         from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='r' order by c.relname`,
    );
    await safe(
      client,
      'exact counts',
      `select 'products' k, count(*) n from products
       union all select 'categories', count(*) from categories
       union all select 'productimages', count(*) from productimages
       union all select 'paymentsettings', count(*) from paymentsettings
       union all select 'users', count(*) from users
       union all select 'orders', count(*) from orders
       union all select 'orderitems', count(*) from orderitems
       union all select 'reviews', count(*) from reviews
       union all select 'commissions', count(*) from commissions order by k`,
    );
    await safe(
      client,
      'products sample',
      `select id,name,categoryid,baseprice,stockquantity,sku,isactive
         from products order by id limit 10`,
    );
    await safe(
      client,
      'products per category',
      `select c.name, count(p.id)::int n from categories c
         left join products p on p.categoryid=c.id
        group by c.name,c.displayorder order by c.displayorder`,
    );
    await safe(
      client,
      'categories',
      `select id,name,displayorder,isactive from categories order by displayorder`,
    );
    await safe(
      client,
      'productimages (distinct vs rows)',
      `select count(distinct imagefile)::int distinct_paths, count(*)::int rows
         from productimages`,
    );
    await safe(
      client,
      'paymentsettings + QR',
      `select id,channel,accountname,accountnumber,qrimagemime,isenabled,
              length(qrimagedata)::int qr_bytes,
              encode(substring(qrimagedata from 1 for 8),'hex') magic,
              md5(qrimagedata) qr_md5
         from paymentsettings order by id`,
    );
    await safe(
      client,
      'auth.users count',
      `select count(*)::int auth_users from auth.users`,
    );
    await safe(
      client,
      'storage buckets',
      `select id,name,public from storage.buckets order by id`,
    );
    await safe(
      client,
      'storage object counts per bucket',
      `select bucket_id, count(*)::int objects from storage.objects
        group by bucket_id order by bucket_id`,
    );
    // cron: jobid/jobname/schedule ONLY (never command text).
    await safe(
      client,
      'pg_cron jobs (jobid/jobname/schedule only)',
      `select jobid, jobname, schedule from cron.job order by jobid`,
    );
  } finally {
    await close();
  }
}

main().catch((e) => {
  console.error('db-facts failed:', e.message);
  process.exit(1);
});
