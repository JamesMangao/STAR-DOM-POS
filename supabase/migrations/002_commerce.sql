-- 002_commerce.sql — STAR:DOM POS commerce + sync tables.
--
-- APPEND-ONLY: orders, order_items, payments, order_voids, stock_events are
-- never UPDATEd or DELETEd. A void is an `order_voids` row plus reversal
-- `stock_events`; the order row is written once and its voided state is
-- DERIVED: exists (select 1 from order_voids where order_id = orders.id).
--
-- The server inserts every append-only row with ON CONFLICT (id) DO NOTHING,
-- which the client reaches via PostgREST `Prefer: resolution=ignore-duplicates`.
-- The unique constraints below (order_no, order_voids.order_id, payments.order_id)
-- are the belt-and-braces guard for that idempotency.

-- ---------------------------------------------------------------- orders
create table if not exists orders (
  id                uuid primary key default gen_random_uuid(),
  store_id          uuid not null references stores (id) on delete cascade,
  device_id         uuid not null,
  order_no          text not null,
  subtotal          numeric(10, 2) not null default 0 check (subtotal >= 0),
  discount          numeric(10, 2) not null default 0 check (discount >= 0),
  total             numeric(10, 2) not null check (total >= 0),
  note              text not null default '',
  payment_method_id uuid,
  amount_received   numeric(10, 2),
  change_amount     numeric(10, 2),
  reference_no      text not null default '',
  status            text not null default 'completed'
                      check (status in ('completed', 'voided')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  synced_at         timestamptz,
  -- order_no is globally unique (device_code prefix makes it so); F2.
  unique (order_no),
  unique (store_id, order_no)
);

create index if not exists idx_orders_store_created
  on orders (store_id, created_at desc);

-- ------------------------------------------------------------ order_items
create table if not exists order_items (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references orders (id) on delete cascade,
  product_id   uuid,
  product_name text not null,
  unit_price   numeric(10, 2) not null,
  quantity     integer not null check (quantity > 0),
  line_total   numeric(10, 2) not null,
  created_at   timestamptz not null default now()
);

create index if not exists idx_order_items_order on order_items (order_id);

-- --------------------------------------------------------------- payments
-- One row per sale, written in the same transaction as the order. The method
-- name and type are snapshotted so editing a PaymentMethod never rewrites an
-- already-issued receipt.
create table if not exists payments (
  id              uuid primary key default gen_random_uuid(),
  store_id        uuid not null references stores (id) on delete cascade,
  device_id       uuid not null,
  order_id        uuid not null references orders (id) on delete cascade,
  method_id       uuid,
  method_name     text not null default '',
  method_type     text not null default '',
  amount          numeric(10, 2) not null,
  amount_received numeric(10, 2),
  change_amount   numeric(10, 2),
  reference_no    text not null default '',
  created_at      timestamptz not null default now(),
  unique (order_id)
);

-- ------------------------------------------------------------ order_voids
create table if not exists order_voids (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders (id) on delete cascade,
  device_id  uuid not null,
  reason     text not null default '',
  voided_at  timestamptz not null default now(),
  created_at timestamptz not null default now(),
  -- A second void must not create a second row.
  unique (order_id)
);

-- ----------------------------------------------------------- stock_events
create table if not exists stock_events (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null references stores (id) on delete cascade,
  product_id uuid not null,
  delta      integer not null,
  reason     text not null check (reason in ('sale', 'adjustment', 'import', 'sync', 'void')),
  order_id   uuid,
  device_id  uuid,
  created_at timestamptz not null default now()
);

create index if not exists idx_stock_events_product on stock_events (product_id);

-- ------------------------------------------------------------- day_closes
-- Replaces `shifts` (nothing used it). One row per (business_date, device_id):
-- closing the same day twice updates the row (LWW), never duplicates it.
create table if not exists day_closes (
  id            uuid primary key default gen_random_uuid(),
  store_id      uuid not null references stores (id) on delete cascade,
  device_id     uuid not null,
  business_date date not null,
  cash_expected numeric(10, 2),
  cash_actual   numeric(10, 2),
  variance      numeric(10, 2),
  closed_by     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  synced_at     timestamptz,
  unique (business_date, device_id)
);

-- ------------------------------------------------------------- sync_outbox
-- id = deterministic dedupe key (uuid v5 of entity + entity_id + updated_at).
-- payload jsonb carries a whole sale/void bundle for the append-only tables.
create table if not exists sync_outbox (
  id         uuid primary key,
  store_id   uuid not null references stores (id) on delete cascade,
  device_id  uuid,
  entity     text not null,
  entity_id  text not null,
  op         text not null check (op in ('insert', 'update', 'delete', 'void')),
  payload    jsonb not null default '{}'::jsonb,
  attempts   integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  synced_at  timestamptz
);

create index if not exists idx_outbox_store_created
  on sync_outbox (store_id, created_at);

-- ------------------------------------------- pull cursors + LWW (A3)
-- day_closes is mutable (LWW, one row per business_date+device): server clock +
-- stale-write guard, same as 001.
create or replace function lww_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return null;
  end if;
  new.server_updated_at := now();
  return new;
end $$;

alter table day_closes add column if not exists server_updated_at
  timestamptz not null default now();
drop trigger if exists trg_day_closes_lww on day_closes;
create trigger trg_day_closes_lww before insert or update on day_closes
  for each row execute function lww_guard();
create index if not exists idx_day_closes_server_updated
  on day_closes (server_updated_at, id);

-- Append-only tables carry server_created_at (there is no update to record).
-- A row is immutable, so its cursor value never moves.
alter table orders add column if not exists server_created_at
  timestamptz not null default now();
alter table order_items add column if not exists server_created_at
  timestamptz not null default now();
alter table payments add column if not exists server_created_at
  timestamptz not null default now();
alter table order_voids add column if not exists server_created_at
  timestamptz not null default now();
alter table stock_events add column if not exists server_created_at
  timestamptz not null default now();

create index if not exists idx_orders_server_created
  on orders (server_created_at, id);
create index if not exists idx_order_items_server_created
  on order_items (server_created_at, id);
create index if not exists idx_payments_server_created
  on payments (server_created_at, id);
create index if not exists idx_order_voids_server_created
  on order_voids (server_created_at, id);
create index if not exists idx_stock_events_server_created
  on stock_events (server_created_at, id);

-- Voided is derived — this view is the single source of truth for "voided".
-- A3/A1: security_invoker, so the view runs with the CALLER's rights. Without
-- it the view runs as its owner and returns every store's rows to `anon`.
drop view if exists order_status;
create view order_status with (security_invoker = true) as
  select
    o.id,
    o.store_id,
    o.device_id,
    o.order_no,
    o.total,
    o.created_at,
    (v.order_id is not null) as is_voided,
    v.voided_at,
    v.reason
  from orders o
  left join order_voids v on v.order_id = o.id;
