-- reseed.sql — the ONE reset list for the STAR:DOM POS database.
--
-- Executed verbatim by scripts/reseed.js (DRY RUN by default; --execute needs
-- a real terminal, the project ref and a typed CONFIRM RESEED). These
-- statements carry NO transaction control: reseed.js wraps this file and the
-- catalogue stock updates in ONE transaction, so a failure halfway rolls back
-- every delete as well.
--
-- KEPT (the catalogue the owner configured):
--   stores, categories, product rows (names, prices, images, category links,
--   soft deletes), payment_methods, settings (receipt data, bundle_rules, ...),
--   and every is_active flag EXCEPT the photo-less mirror at the bottom.
--
-- RESET (operational history, back to a fresh booth):
--   orders (+ order_items, payments, order_voids), stock_events, day_closes,
--   devices, sync_outbox. Product STOCK is reset by reseed.js from
--   assets/catalogue/catalogue.json, which also rewrites the opening-stock
--   events so the column and the event sum agree.

delete from order_voids;
delete from payments;
delete from order_items;
delete from orders;
delete from stock_events;
delete from day_closes;
delete from devices;
delete from sync_outbox;

-- Mirror of AppDatabase.deactivatePhotolessProducts — the app's one-shot
-- launch sweep: a live product the owner has never given art is INACTIVE.
-- This is the only is_active change a reseed makes, and it exists because the
-- stock reset bumps server_updated_at on every product — the next pull then
-- overwrites the booth's flags with THESE values. Without the mirror the
-- photo-less shelf would silently come back as Active right after a reseed;
-- with it the booth keeps exactly the shelf it had before.
update products
   set is_active = false,
       updated_at = now()
 where deleted_at is null
   and is_active
   and coalesce(btrim(image_path), '') = '';
