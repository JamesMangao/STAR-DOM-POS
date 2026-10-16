-- reset.sql — retire the STAR:DOM WEBSITE objects.
--
-- *** NOT RUN WITHOUT "CONFIRM RESET" ***
-- Run only after supabase/export/*.json exists and the row counts match
-- (products 100, categories 11, productimages 58, paymentsettings 2).
--
-- Guarantees:
--   1. PRECHECK + ALLOWLIST. Every public table must be either a known
--      website table (the 32 below) or a known POS table. Anything else
--      aborts the whole script — nothing unknown is ever touched.
--   2. Drops ONLY the allowlisted website tables (cascade).
--   3. NEVER runs `DROP SCHEMA public` and never drops the public schema
--      or its grants.

begin;

-- ------------------------------------------------ 1. precheck + allowlist
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
  -- POS tables created by migrations. `categories`, `products`, `orders` and
  -- `payments` are shared names and already covered by `website` above.
  pos text[] := array[
    'stores', 'devices', 'payment_methods', 'settings', 'order_items',
    'order_voids', 'stock_events', 'day_closes', 'sync_outbox'
  ];
  unknown text[];
  found_website int;
  expected_website int := array_length(website, 1);
begin
  select count(*) into found_website
    from information_schema.tables
   where table_schema = 'public' and table_name = any (website);

  if found_website = 0 then
    raise exception
      'Precheck failed: no website tables found in public — wrong database?';
  end if;

  -- Any public table that is not allowlisted (website or POS) aborts.
  select array_agg(t.table_name) into unknown
    from information_schema.tables t
   where t.table_schema = 'public'
     and t.table_type = 'BASE TABLE'
     and t.table_name <> all (website)
     and t.table_name <> all (pos);

  if unknown is not null then
    raise exception
      'Precheck failed: % unexpected object(s) in public: %. Aborting; '
      'nothing was dropped.', array_length(unknown, 1), array_to_string(unknown, ', ');
  end if;

  raise notice 'Precheck OK: % of % website tables present.',
    found_website, expected_website;
end $$;

-- ------------------------------------------ 2. drop the website tables only
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

-- The `_backend_access` policies lived on those tables and vanish with them.
-- Drop the helper function if it exists (ignore if absent).
drop function if exists public.backend_access_ok() cascade;

-- ------------------------------------------------------- 3. website storage
-- The website's public `assets` bucket is retired. POS uses `pos-assets`.
delete from storage.objects where bucket_id = 'assets';
delete from storage.buckets where id = 'assets';

-- ----------------------------------------------- 4. legacy auth users (opt-in)
-- The website had 0 auth.users rows, so this is usually a no-op. Uncomment
-- ONLY if you have confirmed there are legacy auth rows to remove; it is
-- deliberately not automatic because auth.users is shared infrastructure.
--
-- delete from auth.users u
--  where not exists (select 1 from public.stores s where s.owner_id = u.id);

commit;

-- `public` schema and its grants are intentionally left untouched.
