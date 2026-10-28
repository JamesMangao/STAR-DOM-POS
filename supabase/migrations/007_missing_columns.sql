-- 007_missing_columns.sql — complete server columns used by the current app.
--
-- These columns are already present in the live project, but were absent from
-- the migration history. Keep fresh installs and reset/rebuild databases in
-- sync with that schema.

alter table public.devices
  add column if not exists persistent_storage boolean not null default false;

alter table public.stores
  add column if not exists synced_at timestamptz;
