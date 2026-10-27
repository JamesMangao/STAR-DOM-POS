-- seed.sql — STAR:DOM POS seed (one store + payment methods).
--
-- Idempotent: fixed UUIDs + ON CONFLICT DO UPDATE. Run AFTER the migrations.
-- The owner auth user and stores.owner_id are created out-of-band (Supabase
-- dashboard / import script) because they need the OWNER_EMAIL/OWNER_PASSWORD
-- build-time secrets, which never live in this repo.

-- ---------------------------------------------------------------- store
insert into stores (
  id, name, tagline, receipt_name, receipt_tin, receipt_address,
  receipt_accreditation, receipt_footer, currency
) values (
  '11111111-1111-4111-8111-111111111111',
  'ST⭐️R:Dom x ka1ofakind',
  'Fast. Simple. Offline. Built for Filipino Small Businesses.',
  'STAR:DOM Artisan Marketplace & Pop-up Tour',
  '000-000-000-000',
  'Unit 12, South Luzon Atelier, Santa Rosa, Laguna',
  'PTU-2026-00015',
  'Salamat sa pagtangkilik!',
  'PHP'
)
on conflict (id) do update set
  name = excluded.name,
  tagline = excluded.tagline,
  receipt_name = excluded.receipt_name,
  receipt_tin = excluded.receipt_tin,
  receipt_address = excluded.receipt_address,
  receipt_accreditation = excluded.receipt_accreditation,
  receipt_footer = excluded.receipt_footer,
  currency = excluded.currency;

-- ------------------------------------------------------- payment methods
insert into payment_methods (
  id, store_id, name, type, color, qr_image_path, account_name,
  account_number, require_reference, is_enabled, sort_order
) values
  ('22222222-2222-4222-8222-222222222221',
   '11111111-1111-4111-8111-111111111111', 'Cash', 'cash', '#15803D',
   null, '', '', false, true, 0),
  ('22222222-2222-4222-8222-222222222222',
   '11111111-1111-4111-8111-111111111111', 'GCash', 'ewallet', '#0070E0',
   'pos-assets/payment/gcash.png', 'RIAN DOMINIC CABREROS', '0970 137 5033',
   true, true, 1),
  ('22222222-2222-4222-8222-222222222223',
   '11111111-1111-4111-8111-111111111111', 'GoTyme', 'ewallet', '#00A3A1',
   'pos-assets/payment/gotyme.png', 'RIAN DOMINIC CABREROS', '',
   true, true, 2)
on conflict (id) do update set
  name = excluded.name,
  type = excluded.type,
  color = excluded.color,
  qr_image_path = excluded.qr_image_path,
  account_name = excluded.account_name,
  account_number = excluded.account_number,
  require_reference = excluded.require_reference,
  is_enabled = excluded.is_enabled,
  sort_order = excluded.sort_order;
