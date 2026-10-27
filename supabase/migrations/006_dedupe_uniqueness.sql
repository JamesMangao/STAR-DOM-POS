-- 006_dedupe_uniqueness.sql — one name means one row, everywhere.
--
-- The live database grew duplicates the way offline-first catalogues do:
-- every install seeded its own "Cash" and pushed it (six survived), a CSV
-- import ran twice under different UUIDs ("Tamaraw" x3, "Goby" x2), and
-- case/spacing variants were treated as different items ("PHM" vs "phm",
-- "Gay af" vs "gay af"). The Sell screen showed every twin as its own chip.
--
-- This migration does two things:
--   1. ONE-TIME MERGE: for products, categories and payment_methods, live
--      rows sharing a normalised name collapse to a single survivor. All id
--      references (order_items.product_id, stock_events.product_id,
--      orders/ payments' method ids …) are repointed to
--      the survivor before the twin is deleted, so no sale history is touched
--      — product_name / method snapshots on receipts stay as issued.
--      Deliberately NOT day_closes: its unique (business_date, device_id)
--      could collide on repoint, and its device_id is informational.
--
--      Devices are the exception: they are IDENTITIES, not catalogue items.
--      Each re-registration is a real row that issued real order numbers, so
--      no device row is deleted and no order is repointed. Nine "Booth iPad"
--      registrations of one tablet simply become eight inactive rows plus the
--      newest active one. Nothing in the app gates a sale on that flag.

--   2. PERMANENT UNIQUENESS: partial unique indexes on
--      (store_id, norm_name(name)) WHERE deleted_at IS NULL for products,
--      categories and payment_methods. A push that tries to create a second
--      "PHM" is refused by the database itself — the app's pull-time merge,
--      post-pull dedupe and save-form guards are the polite layers; this is
--      the one that cannot be bypassed by an old client build.
--
-- The merge touches order_items / stock_events / payments / orders — the
-- append-only tables correctly carry NO UPDATE policy, and FORCE RLS applies
-- to the owner too. This is deliberate owner-side maintenance (the same
-- repair the app's dedupe does on-device), so the block lifts FORCE RLS for
-- its own duration and restores it before committing; an exception inside the
-- block rolls everything back, FORCE included.
--
-- norm_name() must stay byte-identical in behaviour to NameNorm.normalize in
-- lib/data/norm.dart — that file's doc comment points here.

create or replace function norm_name(name text) returns text
language sql immutable parallel safe
as $$
  select lower(btrim(regexp_replace(coalesce(name, ''), '\s+', ' ', 'g')))
$$;

do $$
declare
  g record;          -- one duplicate group (store, normalised name)
  loser uuid;        -- a twin that is about to disappear
  winner uuid;       -- the row that survives the group
  n int;
begin
  execute 'alter table products no force row level security';
  execute 'alter table categories no force row level security';
  execute 'alter table payment_methods no force row level security';
  execute 'alter table order_items no force row level security';
  execute 'alter table stock_events no force row level security';
  execute 'alter table orders no force row level security';
  execute 'alter table payments no force row level security';
  execute 'alter table order_voids no force row level security';
  execute 'alter table devices no force row level security';

  -- ---------------------------------------------------------- products
  for g in
    select store_id, norm_name(name) as k
      from products
     where deleted_at is null
     group by 1, 2
    having count(*) > 1
  loop
    -- Survivor: most order_items references (the row with real sales
    -- history), ties broken by earliest created_at, then id for determinism.
    select p.id into winner
      from products p
     where p.store_id = g.store_id
       and p.deleted_at is null
       and norm_name(p.name) = g.k
     order by ((select count(*) from order_items oi
                 where oi.product_id = p.id)) desc,
              p.created_at asc,
              p.id asc
     limit 1;

    for loser in
      select p.id from products p
       where p.store_id = g.store_id
         and p.deleted_at is null
         and norm_name(p.name) = g.k
         and p.id <> winner
    loop
      update order_items set product_id = winner where product_id = loser;
      update stock_events set product_id = winner where product_id = loser;
      get diagnostics n = row_count;
      delete from products where id = loser;
      -- stock_quantity is a MIRROR the devices keep from the events (there is
      -- no trigger): after the events have moved, the survivor's count must
      -- be recomputed or it understates the shelf.
      if n > 0 then
        update products p
           set stock_quantity = (
                 select coalesce(sum(s.delta), 0)::int from stock_events s
                  where s.product_id = winner)
         where p.id = winner;
      end if;
      raise notice 'dedupe products: % -> % (% rows)', loser, winner, n;
    end loop;
  end loop;

  -- -------------------------------------------------------- categories
  for g in
    select store_id, norm_name(name) as k
      from categories
     where deleted_at is null
     group by 1, 2
    having count(*) > 1
  loop
    -- Survivor: most products on the shelf, ties earliest, then id.
    select c.id into winner
      from categories c
     where c.store_id = g.store_id
       and c.deleted_at is null
       and norm_name(c.name) = g.k
     order by ((select count(*) from products p
                 where p.category_id = c.id)) desc,
              c.created_at asc,
              c.id asc
     limit 1;

    for loser in
      select c.id from categories c
       where c.store_id = g.store_id
         and c.deleted_at is null
         and norm_name(c.name) = g.k
         and c.id <> winner
    loop
      update products set category_id = winner where category_id = loser;
      delete from categories where id = loser;
      raise notice 'dedupe categories: % -> %', loser, winner;
    end loop;
  end loop;

  -- --------------------------------------------------- payment_methods
  for g in
    select store_id, norm_name(name) as k
      from payment_methods
     where deleted_at is null
     group by 1, 2
    having count(*) > 1
  loop
    -- Survivor: most orders settled with it, ties earliest, then id.
    select m.id into winner
      from payment_methods m
     where m.store_id = g.store_id
       and m.deleted_at is null
       and norm_name(m.name) = g.k
     order by ((select count(*) from orders o
                 where o.payment_method_id = m.id)) desc,
              m.created_at asc,
              m.id asc
     limit 1;

    for loser in
      select m.id from payment_methods m
       where m.store_id = g.store_id
         and m.deleted_at is null
         and norm_name(m.name) = g.k
         and m.id <> winner
    loop
      update orders set payment_method_id = winner
       where payment_method_id = loser;
      update payments set method_id = winner where method_id = loser;
      delete from payment_methods where id = loser;
      raise notice 'dedupe payment_methods: % -> %', loser, winner;
    end loop;
  end loop;

  -- ----------------------------------------------------------- devices
  -- Re-registrations of the same hardware (each web install used to mint a
  -- fresh UUID): the live DB had nine "Booth iPad" rows, each with its own
  -- device_code, and each order keeps the code it was issued under. So this
  -- is a DEACTIVATION, not a merge: every row survives, no order is
  -- repointed, no code is recycled. Only the newest registration of a name
  -- stays active (`is_active` is display metadata; the app gates sales on its
  -- locally stored code, so deactivating an install cannot stop it selling).
  -- No unique index on device_name afterwards: two real booths may share it.
  update devices d set is_active = false
   where exists (
     select 1 from devices k
      where k.store_id = d.store_id
        and norm_name(k.device_name) = norm_name(d.device_name)
        and (k.created_at, k.id) > (d.created_at, d.id)
   );
  get diagnostics n = row_count;
  raise notice 'devices deactivated as stale re-registrations: %', n;

  execute 'alter table products force row level security';
  execute 'alter table categories force row level security';
  execute 'alter table payment_methods force row level security';
  execute 'alter table order_items force row level security';
  execute 'alter table stock_events force row level security';
  execute 'alter table orders force row level security';
  execute 'alter table payments force row level security';
  execute 'alter table order_voids force row level security';
  execute 'alter table devices force row level security';
end $$;

-- ------------------------------------------------- permanent uniqueness
-- Partial: a tombstoned row never blocks a new one with the same name (the
-- app soft-deletes, and the tombstone must stay pullable so devices hide it
-- too). If either index build fails here, duplicates still exist — the
-- merge above and this index use the SAME norm_name(), so it cannot.
create unique index if not exists uq_products_store_normname
  on products (store_id, norm_name(name))
  where deleted_at is null;

create unique index if not exists uq_categories_store_normname
  on categories (store_id, norm_name(name))
  where deleted_at is null;

create unique index if not exists uq_payment_methods_store_normname
  on payment_methods (store_id, norm_name(name))
  where deleted_at is null;
