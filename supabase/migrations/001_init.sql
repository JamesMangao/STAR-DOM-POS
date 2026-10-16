-- 001_init.sql — STAR:DOM POS core tables (catalogue + config).
--
-- Idempotent: safe to re-run. Every table mirrors lib/data/tables.dart 1:1.
-- Conventions (plan.md §3): uuid PKs, store_id, device_id where applicable,
-- created_at/updated_at timestamptz, deleted_at soft delete, synced_at.
-- Money is numeric(10,2). All timestamps are timestamptz (UTC on the wire).
--
-- LAST WRITE WINS (A3): `updated_at` is the CLIENT clock and is only ever
-- compared. The server keeps its OWN `server_updated_at`, written by
-- lww_guard() on every insert/update, and that is what pull cursors use.
-- A client update that is older than the stored row is discarded server-side
-- (`return null`), so a slow device can never overwrite newer data.

-- ------------------------------------------------- website-schema guard (A2)
-- `create table if not exists` would silently KEEP a website table of the same
-- name (products/categories/orders/payments are shared names). Refuse instead.
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'baseprice'
  ) then
    raise exception
      'website schema still present (public.products.baseprice exists): run reset first';
  end if;
end $$;

-- No pgcrypto: gen_random_uuid() is core since PG13, so the extension was an
-- unnecessary dependency (and the reason this file could not run on a plain
-- local Postgres).

-- ---------------------------------------------------------------- stores
create table if not exists stores (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  tagline               text not null default '',
  owner_id              uuid references auth.users (id),
  receipt_name          text not null default '',
  receipt_tin           text not null default '',
  receipt_address       text not null default '',
  receipt_accreditation text not null default '',
  receipt_footer        text not null default '',
  currency              text not null default 'PHP',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- --------------------------------------------------------------- devices
create table if not exists devices (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references stores (id) on delete cascade,
  device_name  text not null,
  device_code  text not null,
  is_active    boolean not null default true,
  last_sync_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  synced_at    timestamptz,
  unique (store_id, device_code)
);

-- ------------------------------------------------------------ categories
create table if not exists categories (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null references stores (id) on delete cascade,
  name       text not null,
  sort_order integer not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  synced_at  timestamptz
);

-- -------------------------------------------------------------- products
create table if not exists products (
  id             uuid primary key default gen_random_uuid(),
  store_id       uuid not null references stores (id) on delete cascade,
  category_id    uuid references categories (id),
  name           text not null,
  price          numeric(10, 2) not null default 0 check (price >= 0),
  barcode        text,
  image_path     text,
  stock_quantity integer not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  synced_at      timestamptz
);

create unique index if not exists idx_products_store_barcode
  on products (store_id, barcode) where barcode is not null;

-- -------------------------------------------------------- payment_methods
create table if not exists payment_methods (
  id                uuid primary key default gen_random_uuid(),
  store_id          uuid not null references stores (id) on delete cascade,
  name              text not null,
  type              text not null check (type in ('cash', 'ewallet', 'bank')),
  color             text not null default '#B70011',
  qr_image_path     text,
  account_name      text not null default '',
  account_number    text not null default '',
  require_reference boolean not null default false,
  is_enabled        boolean not null default true,
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  synced_at         timestamptz
);

-- -------------------------------------------------------------- settings
create table if not exists settings (
  store_id   uuid not null references stores (id) on delete cascade,
  key        text not null,
  value      text not null,
  updated_at timestamptz not null default now(),
  synced_at  timestamptz,
  primary key (store_id, key)
);

-- ------------------------------------------------- last-write-wins (A3)
-- The old set_updated_at() overwrote the client clock with now(), which made
-- every push look newest and made stale writes invisible. Gone.
drop trigger if exists trg_stores_updated_at on stores;
drop trigger if exists trg_devices_updated_at on devices;
drop trigger if exists trg_categories_updated_at on categories;
drop trigger if exists trg_products_updated_at on products;
drop trigger if exists trg_payment_methods_updated_at on payment_methods;
drop function if exists set_updated_at();

-- Stale-write guard + server clock. `return null` skips the row entirely.
create or replace function lww_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return null;                       -- stale write ignored
  end if;
  new.server_updated_at := now();      -- the only clock a cursor may use
  return new;
end $$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'stores', 'devices', 'categories', 'products', 'payment_methods', 'settings'
  ] loop
    execute format(
      'alter table %1$I add column if not exists server_updated_at '
      'timestamptz not null default now()', t
    );
    execute format('drop trigger if exists trg_%1$s_lww on %1$I', t);
    execute format(
      'create trigger trg_%1$s_lww before insert or update on %1$I '
      'for each row execute function lww_guard()', t
    );
  end loop;
end $$;

-- Pull-cursor indexes. settings has no id (plan.md §3.13 composite PK), so its
-- cursor index carries the whole key.
create index if not exists idx_stores_server_updated
  on stores (server_updated_at, id);
create index if not exists idx_devices_server_updated
  on devices (server_updated_at, id);
create index if not exists idx_categories_server_updated
  on categories (server_updated_at, id);
create index if not exists idx_products_server_updated
  on products (server_updated_at, id);
create index if not exists idx_payment_methods_server_updated
  on payment_methods (server_updated_at, id);
create index if not exists idx_settings_server_updated
  on settings (server_updated_at, store_id, key);
