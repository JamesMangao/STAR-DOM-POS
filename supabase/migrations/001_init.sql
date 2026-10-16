-- 001_init.sql — STAR:DOM POS core tables (catalogue + config).
--
-- Idempotent: safe to re-run. Every table mirrors lib/data/tables.dart 1:1.
-- Conventions (plan.md §3): uuid PKs, store_id, device_id where applicable,
-- created_at/updated_at timestamptz, deleted_at soft delete, synced_at.
-- Money is numeric(10,2). All timestamps are timestamptz (UTC on the wire).

create extension if not exists pgcrypto;

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

-- ------------------------------------------------ updated_at maintenance
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

do $$
declare
  t text;
begin
  foreach t in array array[
    'stores', 'devices', 'categories', 'products', 'payment_methods'
  ] loop
    execute format(
      'drop trigger if exists trg_%1$s_updated_at on %1$s', t
    );
    execute format(
      'create trigger trg_%1$s_updated_at before update on %1$s '
      'for each row execute function set_updated_at()', t
    );
  end loop;
end $$;
