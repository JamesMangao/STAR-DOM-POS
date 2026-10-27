-- reset.sql — retire the STAR:DOM WEBSITE objects.
--
-- *** NOT RUN WITHOUT "CONFIRM RESET" ***
-- reset.js is the ONLY runner: it reads this file and executes it verbatim, so
-- the drop lists below are the single source of truth (no second list in JS).
--
-- The object names come from docs/db-facts.txt (the fail-fast db-facts run):
--   2 functions, 0 views, 31 sequences, 0 standalone types, 8 triggers.
--
-- Guarantees:
--   1. REFUSES on anything POS-shaped. `products`, `categories`, `orders` and
--      `payments` are BOTH website and POS names, so a run against a database
--      that already has the POS schema would drop live POS data. Precheck
--      raises if any POS-only table exists or if public.products has store_id.
--   2. REFUSES unless the website signature is present (products.baseprice).
--   3. Drops ONLY the named website tables + the named non-table objects.
--   4. NEVER runs `DROP SCHEMA public` and never drops the public schema or
--      its grants.
--   5. Does NOT touch storage — Supabase blocks `delete from storage.objects`
--      (protect_delete trigger) and an orphaned file would be worse than an
--      orphaned row. reset.js removes the bucket through the Storage API AFTER
--      this file commits.
--   6. The website's 0 auth.users rows need no cleanup, so there is no
--      auth.users block here at all.

begin;

-- ------------------------------------------------ 1. precheck + allowlists
do $$
declare
  -- POS-only tables: their presence means this is a POS database, not the
  -- website one. (categories/products/orders/payments are shared names and
  -- are detected through the products columns below instead.)
  pos_only text[] := array[
    'stores', 'devices', 'payment_methods', 'settings', 'order_items',
    'order_voids', 'stock_events', 'day_closes', 'sync_outbox'
  ];
  website text[] := array[
    'apperrors', 'assetimages', 'bundleitems', 'bundles', 'cart', 'cartitems',
    'categories', 'commissionreferenceimages', 'commissions',
    'commissionstatushistory', 'eventinventory', 'eventsales', 'notifications',
    'ordercommissions', 'orderitems', 'orders', 'orderstatushistory',
    'payments', 'paymentsettings', 'popupevents', 'productimages', 'products',
    'productvariants', 'promotions', 'receipts', 'reviews', 'roles', 'shipping',
    'storelocations', 'useraddresses', 'users', 'wishlistitems'
  ];
  found_pos text[];
  unknown text[];
  found_website int;
begin
  -- 1a. POS schema present? Stop before dropping anything.
  select array_agg(t.table_name order by t.table_name) into found_pos
    from information_schema.tables t
   where t.table_schema = 'public'
     and t.table_type = 'BASE TABLE'
     and t.table_name = any (pos_only);

  if found_pos is not null then
    raise exception
      'Precheck failed: POS tables already exist in public (%). This is a POS '
      'database — reset would drop POS data. Nothing was dropped.',
      array_to_string(found_pos, ', ');
  end if;

  -- 1b. public.products is the POS table (it has store_id), not the website one.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'store_id'
  ) then
    raise exception
      'Precheck failed: public.products.store_id exists — that is the POS '
      'products table. Nothing was dropped.';
  end if;

  -- 1c. Website signature: the website products table has `baseprice`.
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'baseprice'
  ) then
    raise exception
      'Precheck failed: public.products.baseprice is missing — the website '
      'signature was not found. Wrong database? Nothing was dropped.';
  end if;

  select count(*) into found_website
    from information_schema.tables
   where table_schema = 'public' and table_name = any (website);

  if found_website = 0 then
    raise exception
      'Precheck failed: no website tables found in public — wrong database?';
  end if;

  -- 1d. Nothing unnamed is ever touched.
  select array_agg(t.table_name order by t.table_name) into unknown
    from information_schema.tables t
   where t.table_schema = 'public'
     and t.table_type = 'BASE TABLE'
     and t.table_name <> all (website)
     and t.table_name <> all (pos_only);

  if unknown is not null then
    raise exception
      'Precheck failed: % unexpected object(s) in public: %. Aborting; '
      'nothing was dropped.', array_length(unknown, 1), array_to_string(unknown, ', ');
  end if;

  raise notice 'Precheck OK: % of % website tables present.',
    found_website, array_length(website, 1);
end $$;

-- ------------------------------------------- 2. unschedule dependent cron jobs
-- A job whose command calls a function or table we are about to drop would fail
-- nightly forever. The command TEXT is never selected here (no secrets in logs):
-- only a boolean about whether it references a dropped name.
do $$
declare
  j record;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    for j in
      select jobid, jobname
        from cron.job
       where regexp_replace(command, 'auth\.[a-z_]+', '', 'gi')
             ~* '\m(products|orders|payments|categories|users|cart|reviews|commissions|promotions|bundles|receipts|shipping|notifications|run_delivery_sweep|trg_star_dom_touch_updated_at)\M'
    loop
      perform cron.unschedule(j.jobid);
      raise notice 'Unscheduled cron job % (jobid %) — it references a dropped object.',
        j.jobname, j.jobid;
    end loop;
  end if;
end $$;

-- ------------------------------------------ 3. drop the website tables only
do $$
declare
  website text[] := array[
    'apperrors', 'assetimages', 'bundleitems', 'bundles', 'cart', 'cartitems',
    'categories', 'commissionreferenceimages', 'commissions',
    'commissionstatushistory', 'eventinventory', 'eventsales', 'notifications',
    'ordercommissions', 'orderitems', 'orders', 'orderstatushistory',
    'payments', 'paymentsettings', 'popupevents', 'productimages', 'products',
    'productvariants', 'promotions', 'receipts', 'reviews', 'roles', 'shipping',
    'storelocations', 'useraddresses', 'users', 'wishlistitems'
  ];
  t text;
begin
  foreach t in array website loop
    execute format('drop table if exists public.%I cascade', t);
  end loop;
end $$;

-- --------------------------------- 4. drop website non-table objects by name
-- Source: docs/db-facts.txt. `backend_access_ok()` was a guess and does NOT
-- exist — the real functions are run_delivery_sweep() and the touch trigger.
do $$
declare
  -- 8 triggers (already gone with their tables; named for documentation).
  trig_tables text[] := array[
    'assetimages', 'cart', 'commissions', 'orders',
    'paymentsettings', 'popupevents', 'products', 'users'
  ];
  -- 31 serial sequences.
  seqs text[] := array[
    'apperrors_id_seq', 'bundleitems_id_seq', 'bundles_id_seq', 'cart_id_seq',
    'cartitems_id_seq', 'categories_id_seq', 'commissionreferenceimages_id_seq',
    'commissions_id_seq', 'commissionstatushistory_id_seq',
    'eventinventory_id_seq', 'eventsales_id_seq', 'notifications_id_seq',
    'ordercommissions_id_seq', 'orderitems_id_seq', 'orders_id_seq',
    'orderstatushistory_id_seq', 'payments_id_seq', 'paymentsettings_id_seq',
    'popupevents_id_seq', 'productimages_id_seq', 'products_id_seq',
    'productvariants_id_seq', 'promotions_id_seq', 'receipts_id_seq',
    'reviews_id_seq', 'roles_id_seq', 'shipping_id_seq', 'storelocations_id_seq',
    'useraddresses_id_seq', 'users_id_seq', 'wishlistitems_id_seq'
  ];
  s text;
  t text;
begin
  foreach t in array trig_tables loop
    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = t) then
      execute format('drop trigger if exists trg_%s_updatedat on public.%I', t, t);
    end if;
  end loop;

  foreach s in array seqs loop
    execute format('drop sequence if exists public.%I', s);
  end loop;
end $$;

-- The website's helpers. Plain drops (no cascade): if something unexpected
-- still depends on them, the transaction aborts rather than silently removing
-- a dependent object.
drop function if exists public.run_delivery_sweep();
drop function if exists public.trg_star_dom_touch_updated_at();

commit;

-- The `public` schema, its grants and its storage buckets are untouched here.
-- `pos-assets` stays; the retired website bucket is removed by reset.js
-- through the Storage API after this transaction commits.
