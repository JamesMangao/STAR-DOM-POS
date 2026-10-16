-- 004_device_registration.sql — server-assigned device codes (B7).
--
-- order_no = {device_code}-{YYMMDD}-{seq} and is GLOBALLY unique, but devices
-- are registered locally at first launch. Two devices inventing their own code
-- hand out the same order_no forever, and every later push of the second
-- device's sale is rejected with a permanent 409 that no retry can fix.
--
-- So the SERVER assigns the code. register_device() picks the first 2-character
-- code (A0..Z9) still free for that store, and is idempotent on the device id:
-- a retry after a dropped response returns the same code, never a new one.
-- The app cannot create a sale until this call has succeeded.
--
-- SECURITY INVOKER (the default) on purpose: the caller is the authenticated
-- owner, 003's policies already scope devices to that owner, and 003 FORCEs RLS
-- on every table — a SECURITY DEFINER function would have to hope the definer
-- bypasses RLS.

-- ---------------------------------------------------- outbox backoff (B5)
-- The local outbox backs off after a failure; the server mirror carries the
-- same column so the two schemas stay 1:1 (plan.md §3).
alter table sync_outbox add column if not exists next_attempt_at timestamptz;

-- --------------------------------------------------------- register_device
create or replace function public.register_device(
  p_device_id   uuid,
  p_store_id    uuid,
  p_device_name text
)
-- NOTE: the OUT column is `device_id`, not `id`. A RETURNS TABLE column shadows
-- the table column inside plpgsql, which makes `on conflict (id)` ambiguous
-- (SQLSTATE 42702) — hit while testing this migration.
returns table (device_id uuid, device_code text, device_name text)
language plpgsql
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_code  text;
  v_name  text := coalesce(nullif(btrim(p_device_name), ''), 'Device');
  v_found public.devices;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- Only the store's owner may register a device on it.
  if not exists (
    select 1 from public.stores s
     where s.id = p_store_id and s.owner_id = v_uid
  ) then
    raise exception 'not the owner of store %', p_store_id
      using errcode = '42501';
  end if;

  -- Idempotent: this device already has a code, so return it unchanged.
  select d.* into v_found from public.devices d where d.id = p_device_id;
  if found then
    return query select v_found.id, v_found.device_code, v_found.device_name;
    return;
  end if;

  -- First free code for THIS store, in a stable order (A0, A1 … Z9).
  select l || d
    into v_code
    from unnest(string_to_array('ABCDEFGHIJKLMNOPQRSTUVWXYZ', null)) as l,
         unnest(string_to_array('0123456789', null)) as d
   where not exists (
           select 1 from public.devices x
            where x.store_id = p_store_id and x.device_code = l || d
         )
   order by l, d
   limit 1;

  if v_code is null then
    raise exception 'no free device code left for store %', p_store_id
      using errcode = '54000';
  end if;

  insert into public.devices (id, store_id, device_name, device_code)
  values (p_device_id, p_store_id, v_name, v_code)
  on conflict (id) do nothing;

  -- A concurrent registration may have taken the code first; the unique
  -- constraint (store_id, device_code) then makes the insert a no-op and the
  -- re-read returns whatever this device actually holds.
  select d.* into v_found from public.devices d where d.id = p_device_id;
  if not found then
    raise exception 'device registration lost a race, retry'
      using errcode = '40001';
  end if;

  return query select v_found.id, v_found.device_code, v_found.device_name;
end $$;

-- Only the app's signed-in owner may call it. anon has no grants (003), and the
-- default privileges were revoked there too, but be explicit for this one.
revoke all on function public.register_device(uuid, uuid, text) from anon, public;
grant execute on function public.register_device(uuid, uuid, text) to authenticated;
