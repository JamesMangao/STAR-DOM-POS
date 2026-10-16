# STARDOM-POS — Implementation Plan

Single-owner booth/local POS. Android phone, offline-first, Bluetooth print, multi-device sync.
Backend: existing Supabase project (ref `pykhzrpgdszcwvpydebt`), reset + reseed for POS.
Website retired — old website tables are dropped; products/categories/images are migrated, not lost.

---

## 1. Stack recommendation

**Flutter (Dart) → Android APK, Supabase backend.**

1. Source stack (ASP.NET Web Forms VB.NET, desktop-only) cannot ship to an Android phone — offline-first + Bluetooth ESC/POS + mobile APK forces the change.
2. Flutter builds one Android APK with `--dart-define` env injection (SUPABASE_URL, SUPABASE_ANON_KEY, OWNER_EMAIL, OWNER_PASSWORD — never committed), has mature offline SQLite (drift) and Bluetooth printing (esc_pos_bluetooth) packages, and ports the design tokens 1:1 into ThemeData (Sora + Plus Jakarta Sans via google_fonts).
3. Supabase stays the backend (same project): Auth for silent owner sign-in, Postgres for source of truth, Storage (`pos-assets` bucket) for product/QR images.

---

## 2. Folder structure

```
D:\STARDOM-POS\
├── docs\
│   ├── design-system.md          # tokens + components (ported)
│   ├── plan.md                   # this file
│   └── chatgpt-mockup-prompt.md  # copy-paste image-gen prompt
├── supabase\
│   ├── export\                   # Step A output: products.json, categories.json, productimages.json
│   ├── reset\                    # Step B: reset.sql (NEVER run without CONFIRM RESET)
│   ├── migrations\               # Step C schema: 001_init, 002_commerce, 003_sync_rls
│   └── seed\                     # seed.sql (store, payment methods, receipt settings)
├── scripts\
│   ├── export.js                 # Step A: read-only dump → supabase/export/*.json
│   ├── import.js                 # Step C: transform → POS schema, upload images, seed
│   └── guard.js                 # pre-flight: export exists, row counts match, CONFIRM RESET
├── pos\                          # Flutter app
│   ├── lib\
│   │   ├── core\
│   │   │   ├── theme.dart        # AppColors/Radius/Shadows/Typography from design-system.md
│   │   │   ├── format.dart       # ₱ currency, order_no, dates
│   │   │   └── env.dart          # --dart-define config (url, keys, owner creds)
│   │   ├── data\
│   │   │   ├── db.dart           # drift SQLite (local primary DB)
│   │   │   ├── models.dart       # Store, Device, Product, Category, PaymentMethod, Order...
│   │   │   ├── api.dart          # Supabase REST + storage signed URLs
│   │   │   ├── auth.dart         # silent sign-in, secure storage, token refresh
│   │   │   ├── sync.dart         # outbox push, delta pull, backoff, dedupe
│   │   │   └── outbox.dart       # outbox queue ops
│   │   ├── screens\
│   │   │   ├── sell_screen.dart
│   │   │   ├── cart_screen.dart
│   │   │   ├── cash_payment_screen.dart
│   │   │   ├── noncash_payment_screen.dart   # GCash/GoTyme/bank/e-wallet + QR modal
│   │   │   ├── receipt_screen.dart
│   │   │   ├── orders_screen.dart
│   │   │   ├── report_screen.dart           # end-of-day
│   │   │   ├── products_screen.dart
│   │   │   ├── settings_screen.dart
│   │   │   ├── payment_methods_screen.dart  # CRUD + edit form
│   │   │   ├── devices_screen.dart
│   │   │   └── sync_details_screen.dart
│   │   └── widgets\
│   │       ├── app_button.dart  # .btn variants per design-system
│   │       ├── app_card.dart    # card / kpi / panel / pcard
│   │       ├── app_chip.dart    # chip / pill / badge / status_chip
│   │       ├── app_field.dart  # labeled input
│   │       ├── sync_chip.dart   # Synced | Offline-N | Failed
│   │       ├── product_card.dart
│   │       ├── qty_stepper.dart
│   │       ├── bottom_nav.dart  # Sell | Orders | Products | Reports | Settings
│   │       └── receipt_paper.dart
│   ├── assets\
│   │   ├── logo.webp             # copied from D:\STARDOM\STAR-DOM-Web\Assets\stardom-logo.webp
│   │   └── product_placeholder.webp
│   ├── pubspec.yaml
│   └── android\                  # bluetooth permission, min sdk 23+
├── .env.example                  # SUPABASE_URL, SUPABASE_ANON_KEY, OWNER_EMAIL, OWNER_PASSWORD
├── .gitignore                    # .env, build/, *.jks
└── README.md                     # build/release APK with env injection
```

---

## 3. DB schema (Supabase/Postgres)

Every table: `id UUID` client-generated, `store_id`, `device_id` (where applicable), `created_at`, `updated_at`, `deleted_at` (soft delete), `synced_at`. PKs UUID. `timestamptz` everywhere. Money `numeric(10,2)`.

### 3.1 `stores`
| col | type | notes |
|---|---|---|
| id | uuid pk | |
| name | text | "STAR:DOM Artisan & Pop-up Hub" |
| tagline | text | "Fast. Simple. Offline. Built for Filipino Small Businesses." |
| owner_id | uuid | → auth.users(id), single owner |
| receipt_name | text | "STAR:DOM Artisan Marketplace & Pop-up Tour" |
| receipt_tin | text | "000-000-000-000" |
| receipt_address | text | "Unit 12, South Luzon Atelier, Santa Rosa, Laguna" |
| receipt_accreditation | text | "PTU-2026-00015" |
| receipt_footer | text | customizable line on receipt |
| currency | text | default 'PHP' |

### 3.2 `devices`
| id uuid pk | store_id uuid fk | device_name text | device_code text (unique per store, 2–4 chars, used in order_no) | is_active bool default true | last_sync_at timestamptz | created_at, updated_at, synced_at |

### 3.3 `categories`
| id uuid pk | store_id | name text | sort_order int | is_active bool | created_at, updated_at, deleted_at, synced_at |
Seeded from migrated website categories (active ones only).

### 3.4 `products`
| col | type | notes |
|---|---|---|
| id | uuid pk | |
| store_id | uuid fk | |
| category_id | uuid fk null | |
| name | text not null | trimmed |
| price | numeric(10,2) not null check ≥ 0 | from baseprice |
| barcode | text null | from old SKU (unique per store) |
| image_path | text null | pos-assets path or signed URL |
| stock_quantity | int default 0 | computed from stock_events, mirrored |
| is_active | bool default true | |
| created_at, updated_at, deleted_at, synced_at | | |

Unique partial index: `(store_id, barcode) where barcode is not null`.

### 3.5 `payment_methods`
| id uuid pk | store_id | name text | type text check ('cash','ewallet','bank') | color text | qr_image_path text | account_name text | account_number text | require_reference bool | is_enabled bool | sort_order int | timestamps |
Seeded: Cash, GCash, GoTyme (from website PaymentSettings).

### 3.6 `orders` (append-only)
| col | type |
|---|---|
| id | uuid pk |
| store_id, device_id | uuid fk |
| order_no | text unique per store — `{device_code}-{YYMMDD}-{seq}` |
| subtotal, discount, total | numeric(10,2) |
| note | text |
| payment_method_id | uuid fk |
| amount_received, change_amount | numeric(10,2) (cash) |
| reference_no | text (non-cash) |
| status | text check ('completed','voided') |
| created_at, updated_at, synced_at | |

`status` is written ONCE at insert (`'completed'`) and never updated. Void is
an `order_voids` row + reversal `stock_events`; the order row is NEVER
UPDATED or DELETED. **Voided is DERIVED**: `exists (select 1 from order_voids
where order_id = orders.id)`. Unique: `(order_no)` and `(store_id, order_no)`.

### 3.7 `order_items` (append-only)
| id uuid pk | order_id uuid fk | product_id uuid fk null | product_name text (snapshot) | unit_price numeric(10,2) | quantity int | line_total numeric(10,2) | created_at |

### 3.8 `payments` (append-only)
| id uuid pk | store_id | device_id | order_id uuid fk (unique) | method_id uuid null | method_name text (snapshot) | method_type text (snapshot) | amount numeric(10,2) | amount_received numeric(10,2) null | change_amount numeric(10,2) null | reference_no text | created_at |
Written in the SAME transaction as the order; `method_name`/`method_type` are
snapshotted so editing or deleting a PaymentMethod never rewrites an issued
receipt.

### 3.9 `order_voids` (append-only events)
| id uuid pk | order_id uuid fk (unique) | device_id uuid fk | reason text | voided_at | created_at |
Unique on `order_id` — a second void inserts nothing and returns a clear
result instead of a second row or a second stock reversal.

### 3.10 `stock_events` (delta events — computed sum, never absolute overwrite)
| id uuid pk | store_id | product_id uuid fk | delta int (negative = sale) | reason text ('sale','adjustment','import','sync','void') | order_id uuid fk null | device_id | created_at |

### 3.11 `day_closes` (replaces `shifts`)
| id uuid pk | store_id | device_id | business_date date | cash_expected numeric null | cash_actual numeric null | variance numeric null | closed_by text null | created_at, updated_at, synced_at |
Unique `(business_date, device_id)` — closing the same day twice updates the
row (last-write-wins), it never duplicates. Expected cash = active (non-voided)
cash orders for the day, i.e. **cash orders minus voids**.

> `shifts` was removed: nothing referenced it (no screen, no logic — only a
deleted test), and the mockup has no shift flow. `day_closes` replaces it.

### 3.12 `sync_outbox`
| id uuid pk (event id = dedupe key) | store_id | device_id | entity text | entity_id text | op text ('insert','update','delete','void') | payload jsonb | attempts int default 0 | last_error text | created_at, synced_at |
Index: `(store_id, created_at)`. A sale is ONE row (`entity='sale'`) whose
payload carries the whole bundle: order + items + payment + stock_events. A
void is one row (`entity='void'`) with the order_voids row + reversal events.

### 3.13 `settings`
| store_id uuid fk | key text | value text | updated_at, synced_at | pk (store_id, key) |
Keys: `receipt_footer`, `printer_name`, `device_disabled_banner`, etc.

**Total: 13 POS tables.**

---

## 4. RLS policies

RLS ON for every POS table. Access = authenticated owner only, matched by `store_id`:

```sql
-- example (all tables get the same shape, scoped to their store_id column)
CREATE POLICY owner_all ON products
  FOR ALL TO authenticated
  USING (store_id IN (SELECT id FROM stores WHERE owner_id = auth.uid()))
  WITH CHECK (store_id IN (SELECT id FROM stores WHERE owner_id = auth.uid()));
```

- `anon` role: **no policies → zero access**.
- `authenticated` non-owner: zero rows (subquery returns empty).
- `orders`/`order_items`/`payments`/`order_voids`/`stock_events`: owner-only
  **SELECT + INSERT policies only** — with no UPDATE/DELETE policy the
  append-only rule is enforced at the database, not just in app code.
- Storage bucket `pos-assets` (**private**): authenticated owner read/write via same store match; app uses **signed URLs** (5 min TTL) for product/QR images. anon: none.
- Migrations create policies idempotently (`drop policy if exists` + `create policy`).

---

## 5. Sync architecture

**Local DB is primary.** All flows (sell, cart, cashier, reports) write SQLite first, then enqueue.

**Push (outbox):**
1. Every local mutation writes the row + a `sync_outbox` event (same SQLite transaction). Event `id` = deterministic UUID from (entity, entity_id, updated_at) → idempotent, deduped on the server.
2. Background worker flushes when online: batch POST to `/rest/v1/{entity}` with `Prefer: resolution=ignore-duplicates`; on success set `synced_at` locally + server.
3. Retry: exponential backoff (1s → 2s → 4s → … cap 60s), max 8 attempts, then park with `last_error` + banner in Sync Details. Manual **Retry** re-queues.
4. Offline: events accumulate; SyncChip shows `Offline - N pending` (amber).

**Pull (delta):**
- Each device stores `last_sync_at`. Pull `?updated_at=gt.<last_sync_at>` for products, categories, payment_methods, settings. New device: full pull (products + payment methods + categories) + image cache warm.
- Local apply: last-write-wins by `updated_at`; server wins ties (device clock drift).
- Realtime (optional): supabase channel on `orders`/`products` for cross-device refresh.

**Image cache:** product QR/product images downloaded to app docs dir on pull/sale; served locally offline. Re-download on new device.

---

## 6. Silent auth (no login UI)

1. App start: read session from **flutter_secure_storage**. If none → `supabase.auth.signInWithPassword(email: OWNER_EMAIL, password: OWNER_PASSWORD)` (creds from `--dart-define` / env, never committed).
2. Persist session; auto-refresh via Supabase token refresh (refresh token stored in secure storage).
3. **Offline start:** cached session + local DB → no blocking splash. If token expired and offline → keep working; retry sign-in in background when online.
4. **No logout / no register / no password screens anywhere.**
5. Repeated sign-in failure: non-blocking banner in **Sync Details** ("Signing in… retrying"), keep working offline.
6. Store bootstrap: single `stores.id` (seeded); owner row linked via `stores.owner_id = auth.uid()`.

---

## 7. Conflict rules

| Data | Rule |
|---|---|
| orders, order_items, payments | **Append-only.** Never edit/delete. Void = new `order_voids` event referencing order_id; the order row is untouched. |
| order_voids | Append-only. |
| stock | **Delta events only** — `stock_events.delta`; current stock = sum. No absolute overwrite. |
| products, categories, payment_methods, settings | **Last-write-wins by `updated_at`**, soft delete (`deleted_at`). |
| devices | Register on first launch (UUID + model name + short `device_code`). Rename in Settings. Disable → stops syncing + banner. |
| order_no | `{device_code}-{YYMMDD}-{seq}` — seq = count of that device's orders that day + 1, unique per store. |
| payment_methods.qr_image | Stored in `pos-assets`, cached local, re-downloaded on new device. |
| Reports | Aggregate **all devices**. Cash count + Close Day per device/day (day_closes); store-level summary on top. |

---

## 8. Data migration plan (export → reset → import)

### Step A — EXPORT (scripts/export.js, read-only SELECT)
Dump to `supabase\export\`:
- `products.json` — all 100 rows (id, name, baseprice, stockquantity, sku, categoryid, isactive, slug)
- `categories.json` — all 11 rows
- `productimages.json` — all 58 rows (productid → imagefile path)
Print row counts; abort if 0.

### Step B — RESET (supabase\reset\reset.sql) — **NOT EXECUTED**
Idempotent SQL: drop all 32 old website tables (`drop table if exists ... cascade`), drop their 32 `_backend_access` policies, drop storage bucket `assets` + storage policies, delete `auth.users` rows, revoke anon/authenticated on old objects.
**Requires:** user types `CONFIRM RESET` in chat + confirms project ref `pykhzrpgdszcwvpydebt` + export files exist with matching row counts (guard.js).
Optional pre-step: `pg_dump` backup (skippable).

### Step C — IMPORT/SEED (scripts/import.js + seed.sql)
1. Apply `supabase/migrations/*.sql` (idempotent).
2. Transform export → POS schema:
   - UUIDs generated for every row (uuid v4).
   - `store_id` = seeded store. `price = baseprice::numeric(10,2)`.
   - `barcode = sku`. `is_active = isactive`. Names trimmed.
   - Categories: keep the 6 active ones (Stickers, Art Print, Keychains, Button Pins, Sticker Sheets, Other). Inactive categories have no products → not migrated. Products keep `category_id` mapping.
3. Images: for each `productimages.imagefile` (`/Assets/...`), read `D:\STARDOM\STAR-DOM-Web\Assets\...` from disk (verified: 0 missing paths), optimize to ≤400px WebP, upload to `pos-assets` bucket as `products/{product_uuid}.webp`, set `image_path`. 42 products have no image → `product_placeholder.webp` fallback (no upload).
4. Seed:
   - 1 store (name/receipt fields from web.config appSettings — business data, not secrets).
   - 3 payment methods: **Cash** (cash), **GCash** (ewallet, account RIAN DOMINIC CABREROS, QR from `Payment/GCash.webp`, require_reference), **GoTyme** (ewallet, account RIAN DOMINIC CABREROS, QR from `Payment/GOtyme.webp`, require_reference).
   - 1 owner auth user (email/password from `OWNER_EMAIL`/`OWNER_PASSWORD` env) → `stores.owner_id`.
5. Print import report: products imported, images uploaded, failures.

### Data-cleaning issues found (ASK BEFORE APPLYING FIXES)
1. **4 products with price 0.00** (ids 94–97: Desk buddies ×2, Pins big/small — all inactive). Options: import inactive / skip / set price. **Default: import as inactive.**
2. **42 products have no image** → placeholder fallback. No fix needed.
3. **2 exact duplicate names** ("Gay af" id 14 sticker ₱30 + id 50 pin ₱35; "Tamaraw" id 2 sticker ₱30 + id 60 keychain ₱150) — different products (different merch type + price), **not merged**. Case-variant pairs (Maral, Santan, Jade, PHM, Goby, Pigeon, Phyton, Honeybee) likewise kept distinct.
4. **9 inactive products** (ids 65–69, 94–97) → import with `is_active=false`.
5. Names with trailing spaces (e.g. "Rafflesia  (5x7\")") → trimmed on import.
6. Old website has 10 users, 7 orders, 0 auth users, 44 mall-photo storage objects → **dropped in reset** (not migrated).

---

## 9. Dependencies

**Flutter app (`pos/pubspec.yaml`):**
| Package | Purpose |
|---|---|
| supabase_flutter | Auth (silent sign-in), REST, realtime |
| drift + sqlite3_flutter_libs | Local offline DB (primary) |
| flutter_secure_storage | Session persistence |
| esc_pos_bluetooth + flutter_blue_serial | Bluetooth ESC/POS receipt printing |
| google_fonts | Sora + Plus Jakarta Sans |
| material_symbols_icons | Material Symbols Outlined glyphs |
| image / image_compression | Product/QR image resize + local cache |
| path_provider | Local image cache dir |
| uuid | Client-side UUIDs (outbox dedupe) |
| intl | ₱ formatting, dates |

**Scripts (Node 18+):** `pg` (export/import), `@supabase/supabase-js` (admin: owner user, storage upload), `sharp` (image optimize to ≤400px WebP).

**Env (build-time injection, never committed):**
```
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_ANON_KEY=<anon key>
OWNER_EMAIL=<owner email>
OWNER_PASSWORD=<owner password>
```
Flutter: `flutter build apk --release --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... --dart-define=OWNER_EMAIL=... --dart-define=OWNER_PASSWORD=...`

---

## 10. Build & release

```bash
cd pos
flutter pub get
flutter build apk --release \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=OWNER_EMAIL=$OWNER_EMAIL \
  --dart-define=OWNER_PASSWORD=$OWNER_PASSWORD
# output: pos/build/app/outputs/flutter-apk/app-release.apk
```

Android manifest: `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `INTERNET`, `ACCESS_NETWORK_STATE`. minSdk 23, targetSdk 34.

### 10.1 APK secret scan — what it proves, and what it does not

`scripts/apk-secret-scan.js` unzips an APK to a temp dir, scans every file's
bytes for `SUPABASE_SERVICE_ROLE_KEY` and the `SUPABASE_DB_URL` password, plants
both needles into a stub file to prove the scan can actually see them, then
deletes the temp dir. It prints hit COUNTS only — never a value.

**Measured limit (do not trust a bare `found=0`):** `Env.*` is
`String.fromEnvironment`, so Dart tree-shakes any constant the app never reads.
In the placeholder build the debug APK contains no anon key, no URL and no owner
email at all — `CONTROL TIER2 (SUPABASE_URL host) found=0` — while a compiled
string literal is found — `CONTROL TIER1 (STAR:DOM POS) found=1`. Until the app
reads `Env.*`, a clean scan of the server secrets proves nothing about them,
which is why TIER2 controls exist.

**Mandatory release step (Part B):**

```bash
scripts/build_apk.sh release
node scripts/apk-secret-scan.js build/app/outputs/flutter-apk/app-release.apk --require-dart-defines
```

Required result: `CONTROL TIER1 = 1`; `CONTROL TIER2` SUPABASE_URL host `= 1`
and OWNER_EMAIL `= 1` (i.e. the app really does read `Env.*`);
`SUPABASE_SERVICE_ROLE_KEY = 0`; `SUPABASE_DB_PASSWORD = 0`;
`SELF-TEST overall: OK`. With `--require-dart-defines` any TIER2 zero is a
non-zero exit — a scan that cannot see the dart-define values must never be
reported as proof that the secrets are absent.

---

## 11. Stage 2 runbook (print only — DO NOT RUN FROM AN AGENT)

Everything below is executed BY THE USER, in his own terminal. An agent prints
this section; it never runs steps 3–6. The live project is
`pykhzrpgdszcwvpydebt`.

```bash
# 1. EXPORT (read-only SELECTs; writes supabase/export/ + manifest.json)
cd scripts && node export.js
node export.js --verify          # byte-compare + QR sha256 + DEEP-EQUAL per file

# 2. IMPORT DRY CHECK (no writes; prints the plan and every rule it would apply)
node import.js --dry

# 3. RESET — THE USER ONLY. TTY prompts, exact project ref, CONFIRM RESET.
node reset.js --ref pykhzrpgdszcwvpydebt            # dry run, first
node reset.js --execute --ref pykhzrpgdszcwvpydebt  # then, in a real terminal

# 4. MIGRATIONS 001 → 004
#    Apply supabase/migrations/*.sql in order, then:
node verify.js --schema-only

# 5. IMPORT (images → pos-assets, products, store, payment methods, stock)
node import.js --live

# 6. VERIFY + SIGN-IN SMOKE TEST
node verify.js
scripts/build_apk.sh debug     # install on the booth phone and sign in
```

Order and preconditions:

1. `export.js` — read-only. Re-run until both files are `DEEP-EQUAL y` and the
   QR sha256 pair is `IDENTICAL`; `manifest.json` must carry the host label only.
2. `import.js --dry` — refuses a re-run unless `--force` (settings key
   `import_completed_at`), and `--force` is still `ON CONFLICT DO NOTHING`.
3. `reset.js --execute` — refuses to run unless stdin AND stdout are a TTY, then
   asks for the project ref and `CONFIRM RESET`. It runs `supabase/reset/reset.sql`
   verbatim (single source of truth), then deletes the `assets` bucket through
   the Storage API: **44 objects, 35,144,842 bytes, no backup, not recoverable**.
   The dry run prints `sha256(reset.sql)` and the object count/bytes first.
4. Migrations 001→004 are the POS schema. 004 adds `register_device()`, which
   assigns each device its 2-character code — the app cannot ring a sale before
   that call succeeds, so the FIRST device must sign in while online.
5. `import.js --live` — images are resized to fit 400×400 WebP (QR files are
   uploaded byte-identical), zero-price products are imported inactive, opening
   stock arrives as `stock_events(reason='import')`, and the store row carries no
   invented TIN/PTU/address.
6. `verify.js` — computed counts (inactive = `isactive=false OR baseprice=0`),
   the anon probe with a throwaway user, `security_invoker` on `order_status`,
   the `pos-assets` bucket private, 5 random images ≤400px, and
   `sum(stock_events) = products.stock_quantity` for every product.

**Local pre-flight (agent-safe, no live DB):** `node --test scripts/` runs the
PGlite suite — migrations 001→004 applied twice, RLS, append-only enforcement,
server LWW, the reset prechecks and `register_device`.

**Sync notes that the runbook depends on:** pull cursors are per table
(`pull_cursor:<table>`), keyset-paged on `server_updated_at` (mutable) and
`server_created_at` (append-only); a device clock 10 minutes ahead or behind
loses nothing. Offline is never a failure: a sale stays pending indefinitely,
and only a real 4xx/5xx burns an attempt (8 attempts, 1s→60s backoff).
