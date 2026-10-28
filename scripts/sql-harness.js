// scripts/sql-harness.js — local Postgres (PGlite) harness for the POS SQL.
//
// The live project is NEVER used for these tests. PGlite is Postgres compiled
// to wasm, so RLS, policies, triggers and privilege checks behave for real.
//
// What the stubs provide (everything Supabase has that our SQL assumes):
//   auth.users(id, email)      + auth.uid() reading the request GUC
//   storage.buckets / storage.objects
//   roles anon + authenticated (both NOLOGIN, NONSUPERUSER)
//   Supabase's default privileges, which GRANT to `anon` — that is what makes
//   migration 003's REVOKEs testable rather than vacuous.
'use strict';

const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const ROOT = path.resolve(__dirname, '..');
const MIGRATIONS = path.join(ROOT, 'supabase', 'migrations');
const RESET_SQL = path.join(ROOT, 'supabase', 'reset', 'reset.sql');

const SUPABASE_STUBS = `
create schema if not exists auth;
create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text unique
);

-- auth.uid() mirrors Supabase: the JWT subject, per request.
create or replace function auth.uid() returns uuid
language sql stable
set search_path = ''
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create schema if not exists storage;
create table if not exists storage.buckets (
  id         text primary key,
  name       text not null,
  public     boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text not null,
  name       text not null,
  metadata   jsonb,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
end $$;

grant usage on schema public to anon, authenticated;
grant usage on schema auth to anon, authenticated;
grant usage on schema storage to anon, authenticated;
grant select on auth.users to authenticated;
grant all on storage.buckets to authenticated;
grant all on storage.objects to authenticated;
`;

/** Postgres grants new public objects to anon/authenticated like Supabase does. */
function supabaseDefaultPrivileges() {
  return `
alter default privileges for role current_user in schema public
  grant all on tables to anon, authenticated;
alter default privileges for role current_user in schema public
  grant all on sequences to anon, authenticated;
alter default privileges for role current_user in schema public
  grant all on functions to anon, authenticated;
`;
}

async function createDb() {
  const db = new PGlite();
  await db.exec(SUPABASE_STUBS);
  await db.exec(supabaseDefaultPrivileges());
  return db;
}

function migrationFiles() {
  return fs
    .readdirSync(MIGRATIONS)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((f) => path.join(MIGRATIONS, f));
}

/** Apply every numbered migration in order. `rounds` > 1 proves idempotency. */
async function applyMigrations(db, { rounds = 1 } = {}) {
  for (let r = 0; r < rounds; r++) {
    for (const file of migrationFiles()) {
      await db.exec(fs.readFileSync(file, 'utf8'));
    }
  }
}

async function runReset(db) {
  return db.exec(fs.readFileSync(RESET_SQL, 'utf8'));
}

/**
 * A database shaped like the retired website: the shared-name tables with the
 * WEBSITE columns, the 2 real functions, a serial sequence and the touch
 * trigger — and none of the POS-only tables.
 */
async function websiteFixture(db) {
  await db.exec(`
create table products (
  id bigserial primary key,
  name text not null,
  baseprice numeric(10,2),
  stockquantity integer,
  sku text,
  slug text,
  categoryid bigint,
  isactive boolean
);
create table categories (
  id bigserial primary key, name text, slug text, displayorder integer, isactive boolean, parentid bigint
);
create table orders (id bigserial primary key, total numeric(10,2), userid uuid);
create table orderitems (id bigserial primary key, orderid bigint, quantity integer);
create table payments (id bigserial primary key, orderid bigint, amount numeric(10,2));
create table paymentsettings (
  id bigserial primary key, channel text, accountname text, accountnumber text,
  qrimagefile text, qrimagemime text, qrimagedata bytea, isenabled boolean,
  updatedby text, updatedat timestamptz
);
create table productimages (
  id bigserial primary key, productid bigint, imagefile text, isprimary boolean, sortorder integer
);
create table users (id bigserial primary key, email text);

-- the website's real helper functions (docs/db-facts.txt)
create or replace function run_delivery_sweep() returns void language plpgsql as $$
begin
  perform 1;
end $$;
create or replace function trg_star_dom_touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updatedat := now();
  return new;
end $$;

create trigger trg_products_updatedat before update on products
  for each row execute function trg_star_dom_touch_updated_at();
`);
}

/** Two stores with one product each, owned by two different auth users. */
async function posFixture(db, ids) {
  const { ownerId, otherOwnerId, storeId, otherStoreId, productId, otherProductId } = ids;
  await db.exec(`
insert into auth.users (id, email) values
  ('${ownerId}', 'owner@example.invalid'),
  ('${otherOwnerId}', 'other@example.invalid');
insert into stores (id, name, owner_id) values
  ('${storeId}', 'Owner store', '${ownerId}'),
  ('${otherStoreId}', 'Other store', '${otherOwnerId}');
insert into products (id, store_id, name, price, stock_quantity) values
  ('${productId}', '${storeId}', 'Owner product', 30.00, 5),
  ('${otherProductId}', '${otherStoreId}', 'Other product', 10.00, 1);
`);
}

/** Run `fn` inside a transaction as `role`, with the JWT subject set. */
async function asRole(db, role, subject, fn) {
  return db.transaction(async (tx) => {
    await tx.exec(`set local role ${role}`);
    if (subject) {
      await tx.exec(`set local "request.jwt.claim.sub" = '${subject}'`);
    }
    return fn(tx);
  });
}

module.exports = {
  ROOT,
  MIGRATIONS,
  RESET_SQL,
  createDb,
  applyMigrations,
  migrationFiles,
  runReset,
  websiteFixture,
  posFixture,
  asRole,
};
