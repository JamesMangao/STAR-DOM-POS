-- 003_sync_rls.sql — Row Level Security for every POS table.
--
-- Access model: authenticated owner only, matched by store ownership
-- (auth.uid() = stores.owner_id). `anon` has no policies -> zero access.
-- An authenticated non-owner sees zero rows (the subquery is empty).
--
-- Append-only tables get SELECT + INSERT policies only. No UPDATE and no
-- DELETE policy means PostgREST/Postgres rejects any attempt to rewrite an
-- order, item, payment, void or stock event.

-- ------------------------------------------------- enable RLS everywhere
do $$
declare
  t text;
begin
  foreach t in array array[
    'stores', 'devices', 'categories', 'products', 'payment_methods',
    'settings', 'orders', 'order_items', 'payments', 'order_voids',
    'stock_events', 'day_closes', 'sync_outbox'
  ] loop
    execute format('alter table if exists %I enable row level security', t);
    execute format('alter table if exists %I force row level security', t);
  end loop;
end $$;

-- ----------------------------------------------------------- stores (owner)
drop policy if exists owner_all on stores;
create policy owner_all on stores
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- ------------------------------- mutable tables: full owner-scoped access
do $$
declare
  t text;
begin
  foreach t in array array[
    'devices', 'categories', 'products', 'payment_methods',
    'settings', 'day_closes', 'sync_outbox'
  ] loop
    execute format('drop policy if exists owner_all on %I', t);
    execute format(
      $f$create policy owner_all on %1$I
           for all to authenticated
           using (
             exists (select 1 from stores s
                     where s.id = %1$I.store_id and s.owner_id = auth.uid())
           )
           with check (
             exists (select 1 from stores s
                     where s.id = %1$I.store_id and s.owner_id = auth.uid())
           )$f$, t
    );
  end loop;
end $$;

-- ---------------------- append-only tables: SELECT + INSERT only (no rewrite)
do $$
declare
  t text;
begin
  foreach t in array array[
    'orders', 'order_items', 'payments', 'order_voids', 'stock_events'
  ] loop
    execute format('drop policy if exists owner_read on %I', t);
    execute format('drop policy if exists owner_insert on %I', t);
    -- orders/payments/stock_events carry store_id; order_items/order_voids
    -- reach the store through their parent order.
    if t in ('orders', 'payments', 'stock_events') then
      execute format(
        $f$create policy owner_read on %1$I
             for select to authenticated
             using (
               exists (select 1 from stores s
                       where s.id = %1$I.store_id and s.owner_id = auth.uid())
             )$f$, t
      );
      execute format(
        $f$create policy owner_insert on %1$I
             for insert to authenticated
             with check (
               exists (select 1 from stores s
                       where s.id = %1$I.store_id and s.owner_id = auth.uid())
             )$f$, t
      );
    else
      execute format(
        $f$create policy owner_read on %1$I
             for select to authenticated
             using (
               exists (select 1 from orders o
                       join stores s on s.id = o.store_id
                       where o.id = %1$I.order_id and s.owner_id = auth.uid())
             )$f$, t
      );
      execute format(
        $f$create policy owner_insert on %1$I
             for insert to authenticated
             with check (
               exists (select 1 from orders o
                       join stores s on s.id = o.store_id
                       where o.id = %1$I.order_id and s.owner_id = auth.uid())
             )$f$, t
      );
    end if;
  end loop;
end $$;

-- --------------------------------------------------------------- storage
-- pos-assets is PRIVATE. The app reads product/QR images via short-lived
-- signed URLs. Only the authenticated owner may read or write.
insert into storage.buckets (id, name, public)
  values ('pos-assets', 'pos-assets', false)
  on conflict (id) do update set public = false;

drop policy if exists pos_assets_owner_rw on storage.objects;
create policy pos_assets_owner_rw on storage.objects
  for all to authenticated
  using (
    bucket_id = 'pos-assets'
    and exists (select 1 from stores s where s.owner_id = auth.uid())
  )
  with check (
    bucket_id = 'pos-assets'
    and exists (select 1 from stores s where s.owner_id = auth.uid())
  );

-- ------------------------------------------- anon has no grants (A1)
-- RLS is the gate, but Supabase grants new objects to `anon` by default, and
-- a VIEW runs with its owner's rights unless it is security_invoker. Revoke the
-- grants too: a missing grant cannot be bypassed by a policy mistake.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;

-- …and keep future objects from re-acquiring them.
alter default privileges for role postgres in schema public
  revoke all on tables from anon;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke all on functions from anon;
