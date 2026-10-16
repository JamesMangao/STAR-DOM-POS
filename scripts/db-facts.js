// scripts/db-facts.js — Step 3b: READ-ONLY facts about the live project.
//
//   node scripts/db-facts.js
//
// Same read-only enforcement as export.js (default_transaction_read_only=on +
// BEGIN READ ONLY). Prints raw rows; prints no credential values.
//
// FAIL-FAST: any query error stops the whole run with a non-zero exit and the
// section name + SQLSTATE. A missing section is never silently skipped.
'use strict';

const { readOnlyClient } = require('./pg');

let ok = 0;
let total = 0;

async function section(client, label, sql, params = []) {
  total++;
  console.log(`\n===== ${label} =====`);
  try {
    const res = await client.query(sql, params);
    console.log(JSON.stringify(res.rows, null, 2));
    ok++;
  } catch (e) {
    console.error(`QUERY FAILED: ${label}`);
    console.error(`  SQLSTATE ${e.code || 'n/a'}: ${e.message}`);
    throw new Error(`section "${label}" failed (SQLSTATE ${e.code || 'n/a'})`);
  }
}

async function main() {
  const { client, close } = await readOnlyClient();
  try {
    await section(
      client,
      'public base tables',
      `select count(*)::int as tables from information_schema.tables
        where table_schema='public' and table_type='BASE TABLE'`,
    );
    await section(
      client,
      'table list',
      `select c.relname as table_name, c.reltuples::bigint as est_rows
         from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind='r' order by c.relname`,
    );
    await section(
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
    await section(
      client,
      'products sample',
      `select id,name,categoryid,baseprice,stockquantity,sku,isactive
         from products order by id limit 10`,
    );
    await section(
      client,
      'products per category',
      `select c.name, count(p.id)::int n from categories c
         left join products p on p.categoryid=c.id
        group by c.name,c.displayorder order by c.displayorder`,
    );
    await section(
      client,
      'categories',
      `select id,name,displayorder,isactive from categories order by displayorder`,
    );
    await section(
      client,
      'productimages (distinct vs rows)',
      `select count(distinct imagefile)::int distinct_paths, count(*)::int rows
         from productimages`,
    );
    await section(
      client,
      'paymentsettings + QR',
      `select id,channel,accountname,accountnumber,qrimagemime,isenabled,
              length(qrimagedata)::int qr_bytes,
              encode(substring(qrimagedata from 1 for 8),'hex') magic,
              md5(qrimagedata) qr_md5
         from paymentsettings order by id`,
    );
    await section(
      client,
      'auth.users count',
      `select count(*)::int auth_users from auth.users`,
    );
    await section(
      client,
      'public.users + auth.users counts',
      `select 'public.users' k, count(*)::int n from public.users
       union all select 'auth.users', count(*)::int from auth.users order by k`,
    );
    await section(
      client,
      'storage buckets',
      `select id,name,public from storage.buckets order by id`,
    );
    await section(
      client,
      'storage object counts per bucket',
      `select bucket_id, count(*)::int objects from storage.objects
        group by bucket_id order by bucket_id`,
    );
    await section(
      client,
      'pg_default_acl',
      `select pg_get_userbyid(defaclrole)::text as grantee,
              defaclnamespace::regnamespace::text as schema,
              defaclobjtype,
              defaclacl::text as acl
         from pg_default_acl order by 1,2,3`,
    );
    await section(
      client,
      'pg_cron jobs (jobid/jobname/schedule only)',
      `select jobid, jobname, schedule from cron.job order by jobid`,
    );
    // The reset drop-list source of truth: every non-table object in public.
    await section(
      client,
      'public functions (drop list)',
      `select p.proname,
              pg_get_function_identity_arguments(p.oid) as args,
              l.lanname
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         join pg_language l on l.oid = p.prolang
        where n.nspname = 'public'
          and p.prokind = 'f'
        order by 1, 2`,
    );
    await section(
      client,
      'public views + matviews (drop list)',
      `select c.relname, c.relkind
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('v', 'm') order by 1`,
    );
    await section(
      client,
      'public sequences (drop list)',
      `select c.relname
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'S' order by 1`,
    );
    await section(
      client,
      'public standalone types (drop list)',
      `select t.typname, t.typtype
         from pg_type t join pg_namespace n on n.oid = t.typnamespace
        where n.nspname = 'public' and t.typtype in ('e', 'd', 'c')
          and not exists (
            select 1 from pg_class c
             where c.oid = t.typrelid and c.relkind = 'r')
        order by 1`,
    );
    await section(
      client,
      'public triggers (non-internal)',
      `select c.relname as table_name, t.tgname
         from pg_trigger t
         join pg_class c on c.oid = t.tgrelid
         join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and not t.tgisinternal
        order by 1, 2`,
    );
    // Booleans only — the job COMMAND text is never selected or printed.
    await section(
      client,
      'cron jobs: does the command reference an object reset will drop?',
      `select jobid, jobname, schedule,
              (regexp_replace(command, 'auth\\.[a-z_]+', '', 'gi')
                 ~* '\\m(products|orders|payments|categories|users|cart|reviews|commissions|promotions|bundles|receipts|shipping|notifications|run_delivery_sweep|trg_star_dom_touch_updated_at)\\M')
                as references_dropped_object
         from cron.job order by jobid`,
    );
  } finally {
    await close();
  }
  console.log(`\nsections ok ${ok}/${total}`);
  if (ok !== total) process.exit(1);
}

main().catch((e) => {
  console.error(`\ndb-facts failed: ${e.message}`);
  console.error(`sections ok ${ok}/${total}`);
  process.exit(1);
});
