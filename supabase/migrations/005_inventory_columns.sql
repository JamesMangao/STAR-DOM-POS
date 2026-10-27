-- 005_inventory_columns.sql — the inventory sheet's own columns on products.
--
-- The paper inventory (docs/inventory/ARTSHOP_DATABASE_2.md) carries four
-- things the POS schema had nowhere for:
--
--   stock_status  the shelf status the owner writes by hand ("In Stock",
--                 "Low Stock", "Restock", "Out of Stock"). It is NOT derivable
--                 from stock_quantity: the source says "Low Stock" at 10 units
--                 and "In Stock" at 10 units on different rows, so it is
--                 stored, never guessed.
--   source_ref    the item id from the sheet ("#001"), so a row can be found
--                 in the PDF without searching by name.
--   notes         the free-text note ("RESTOCK", "9(otherdesign)").
--   source_col1   the sheet's unnamed "Column 1". Its meaning is undefined in
--                 the source, so it is carried verbatim and never interpreted.
--
-- All four are nullable/optional: a row that predates this migration simply
-- has none, and the app keeps whatever it had locally.

alter table products
  add column if not exists stock_status text not null default 'In Stock',
  add column if not exists source_ref text,
  add column if not exists notes text,
  add column if not exists source_col1 integer;

comment on column products.stock_status is
  'Shelf status from the inventory sheet: In Stock | Low Stock | Restock | Out of Stock';
comment on column products.source_ref is
  'Item id from the inventory sheet (e.g. #001)';
comment on column products.notes is
  'Free-text note from the inventory sheet';
comment on column products.source_col1 is
  'The inventory sheet''s unnamed "Column 1", carried verbatim';
