# STARDOM-POS — Implementation Plan

Single-owner booth POS, shipped as a **Flutter web PWA installed on an iPad 9th gen**
(Safari → Share → Add to Home Screen, runs standalone). Offline-first, PDF receipts through
the system share/AirPrint sheet, multi-device sync.

**Web is the only target.** There is no APK, no iOS build, no TestFlight/Ad-Hoc profile and
no Bluetooth printing — the App Store, codesigning and TestFlight all need a paid developer
account, and this project is deliberately free-only:

* **Backend:** existing Supabase project (ref `pykhzrpgdszcwvpydebt`), reset + reseed for POS.
* **Hosting:** Cloudflare Pages free tier, direct upload of `build/web`.

Website retired — old website tables are dropped; products/categories/images are migrated, not lost.

---

## 0. Device engineering rules (iPad 9th gen, standalone PWA)

Target: **iPad 9th gen** — A13, 3 GB RAM, 10.2", 2160×1620 px @2× = **1080×810 pt landscape /
810×1080 pt portrait**, iPadOS Safari, Wi-Fi only at the booth and often offline. These rules
are binding for every screen and are repeated in `docs/design-system.md`.

| Rule | Why | Where it lives |
|---|---|---|
| Touch only: targets ≥ **48 pt**, no hover, no tooltips, no long-press or right-click dependence | a finger is the only input device | design-system.md §Touch |
| Standalone mode has **no URL bar and no browser back** — every pushed route has an in-app back button | the system back affordance does not exist | design-system.md §Navigation |
| The iOS edge-swipe-back must pop the Flutter route and never exit the app | an accidental edge swipe must not kill a sale | design-system.md §Navigation |
| The on-screen keyboard covers lower fields: the scaffold must resize for it and the reference-number field must stay visible | checkout fields sit at the bottom | design-system.md §Forms |
| Input font size ≥ **16 px** | Safari auto-zooms inputs smaller than 16 px | `lib/main.dart` sign-in screen; design-system.md §Forms |
| Safe-area insets (home indicator) respected, `viewport-fit=cover`, no pinch zoom, `overscroll-behavior: none` | notch/home indicator + accidental zoom | `web/index.html` |
| 3 GB RAM: product images ≤ **400 px**, lazy builders everywhere, never load all orders into memory | WebKit kills a heavy tab | §3.4, design-system.md §Performance |
| The peso sign **₱ (U+20B1)** must render in the bundled fonts | a missing glyph prints a blank box on every receipt | **verified**: `node scripts/font-check.js assets/fonts/*.ttf` — Sora lacks it, PlusJakartaSans has it, and every Sora style declares PlusJakartaSans as its fallback (`lib/core/theme.dart`) |
| Time zone **Asia/Manila (UTC+8, no DST)** | the business day is the store-local day | §3.11, `BusinessDate` in `lib/data/logic.dart` |
| **Wake lock** while the app is visible (`navigator.wakeLock('screen')`, guarded, silent if unsupported) | the screen must not sleep on the booth table | `lib/core/web_apis.dart` |

Operating procedure for the owner is `docs/owner-setup.md` (print it; it contains no code).

---

## 1. Stack recommendation

**Flutter (Dart) → web PWA on the iPad, Supabase backend, Cloudflare Pages hosting.**

1. The source stack (ASP.NET Web Forms VB.NET, desktop-only) cannot ship to an iPad, and a
   native iOS app needs a paid Apple Developer account. A PWA has none of those costs, installs
   from Safari's share sheet and works offline — the actual constraint at the booth.
2. Flutter compiles one `build/web` bundle. Offline SQLite is **drift on wasm**
   (`sqlite3.wasm` + `drift_worker.js`, both committed in `web/`, both same-origin), receipts are
   **PDF through the system share/print sheet** (`pdf` + `printing`), and the design tokens are
   ported 1:1 into `ThemeData` with **bundled** fonts (Sora + Plus Jakarta Sans assets, no
   `google_fonts` runtime fetch — an offline booth cannot reach a font CDN).
3. `--dart-define` injects **only** `SUPABASE_URL` and `SUPABASE_ANON_KEY`. The bundle is public,
   so the owner signs in once by hand (§6) and no credential is ever compiled in.
4. Supabase stays the backend (same project): Auth for the one-time owner sign-in, Postgres as
   the source of truth, Storage (`pos-assets`, private) for product/QR images.

---

## 2. Folder structure

```
D:\STARDOM-POS\
├── docs\
│   ├── design-system.md          # tokens + components + the iPad device rules
│   ├── owner-setup.md            # PRINT THIS: Add to Home Screen, Auto-Lock, Guided Access
│   ├── plan.md                   # this file
│   ├── db-facts.txt              # read-only facts about the live DB (reset drop list)
│   └── chatgpt-mockup-prompt.md  # copy-paste image-gen prompt
├── supabase\
│   ├── export\                   # Step A output: products/categories/productimages/paymentsettings + qr_*.png
│   ├── reset\                    # Step B: reset.sql (NEVER run without CONFIRM RESET)
│   ├── migrations\               # 001_init, 002_commerce, 003_sync_rls, 004_device_registration
│   └── seed\                     # seed.sql (store, payment methods, receipt settings)
├── scripts\                      # Node only; .env is the ONLY credential source
│   ├── env.js                    # the single .env loader + --dart-define whitelist (2 keys)
│   ├── export.js  import.js  verify.js  reset.js  db-facts.js  manifest.js  pg.js
│   ├── build-web.js              # build the PWA + scan it. NEVER deploys.
│   ├── offline-test.js           # Playwright: boot, no-CDN, offline reload
│   ├── font-check.js             # ₱ (U+20B1) must exist in the bundled fonts
│   ├── pwa-icons.js              # generate web/icons from the brand logo
│   └── sql.test.js env.test.js import.test.js verify.test.js reset.test.js font.test.js
├── lib\                          # the Flutter app (web is the only target)
│   ├── main.dart                 # app SHELL: boot, session, sync chip, unsynced guard, export
│   ├── core\
│   │   ├── theme.dart            # tokens + the Sora→PlusJakartaSans ₱ fallback
│   │   ├── tokens.dart format.dart icons.dart gallery.dart
│   │   ├── env.dart              # --dart-define: SUPABASE_URL + SUPABASE_ANON_KEY ONLY
│   │   └── web_apis.dart         # conditional: navigator.storage.persist, wake lock, blob download
│   └── data\
│       ├── db.dart  tables.dart  db.g.dart     # drift (local primary DB, schemaVersion 3)
│       ├── db_open.dart + db_open_web.dart / db_open_io.dart   # wasm on web, memory on the VM
│       ├── api.dart              # Supabase REST + storage (+ image bytes for the offline cache)
│       ├── auth.dart             # ONE-TIME sign-in; supabase_flutter persists the session
│       ├── sync.dart  sync_policy.dart          # outbox push, delta pull, backoff, dedupe
│       ├── device.dart           # server-assigned device code (B7)
│       ├── printing.dart         # ReceiptPrinter: PDF via the share/AirPrint sheet
│       └── bundle.dart  logic.dart
├── web\                          # the PWA shell (W4)
│   ├── index.html                # viewport-fit, no pinch zoom, safe areas, service worker
│   ├── manifest.json             # "Stardom POS", standalone, #B70011 / #FFF8F5, icons
│   ├── sw.js                     # OUR app-shell cache (Flutter's stub is removed at build)
│   ├── _headers                  # Cloudflare Pages cache rules
│   ├── sqlite3.wasm              # vendored: sqlite3.dart 2.9.4 (see §10.4)
│   ├── drift_worker.js  drift_worker.dart   # compiled FROM drift 2.31.0
│   └── icons\  favicon.png
├── assets\fonts\  assets\images\ # bundled fonts (no runtime CDN) + brand logo
├── test\                         # db_test, logic_test, sync_policy_test, bundle_push_test, widget_test
├── .env.example                  # SUPABASE_URL, SUPABASE_ANON_KEY, SERVICE_ROLE, DB_URL, OWNER_*
└── .gitignore                    # .env, build/, review bundles
```

**Not maintained:** `android/` and `ios/` were removed. There is no APK, no TestFlight and no
Ad-Hoc path; `scripts/build_apk.sh` and `scripts/apk-secret-scan.js` are gone with them, replaced
by `scripts/build-web.js`.

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
| receipt_name | text | "ST⭐️R:Dom x ka1ofakind Artisan Marketplace & Pop-up Tour" |
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

## 6. Auth — one-time sign-in (W1)

**Decision log:** "No login UI, creds compiled in" → **"One-time sign-in screen; credentials
never in the bundle"**. `OWNER_EMAIL`/`OWNER_PASSWORD` are no longer `--dart-define` values: a
public web bundle is readable by anyone with devtools, so a compiled-in password is a published
password. They stay in `.env` for the Node scripts only (`import.js` creates the owner through
the admin API).

1. First run (or after the session is lost): a single screen takes email + password,
   `signInWithPassword`, and nothing else — **no signup, no forgot-password**, generic error copy,
   and a deliberate 2 s client-side delay after a rejection.
2. `supabase_flutter` persists the session itself (localStorage on web), so afterwards the app
   refreshes silently and the screen never appears again.
3. **Selling never depends on auth.** The local database is primary and the outbox keeps filling
   while signed out; a missing session is a small "Sign in to sync" chip plus a Settings line.
4. Offline start: local DB → no blocking splash. An expired token with no network just means
   "not syncing yet".
5. The store row is seeded by `import.js`; ownership is `stores.owner_id = auth.uid()`, enforced
   by RLS (003) — not by the client.
6. Build-time enforcement: `scripts/env.js`'s whitelist is exactly
   `['SUPABASE_URL','SUPABASE_ANON_KEY']`, both `OWNER_*` keys are on the never-in-app list, and
   `scripts/build-web.js` scans the built bundle for their values.

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
`reset.js` is the only runner and it executes `reset.sql` verbatim (single source of truth — there
is no second drop list in JS). Inside one transaction it: prechecks that the database is the
WEBSITE one (raises if any POS-only table exists, if `public.products` has `store_id`, or if the
website signature `products.baseprice` is missing), unschedules any `cron.job` whose command
references a dropped object, drops exactly the 32 named website tables plus the named functions
(`run_delivery_sweep`, `trg_star_dom_touch_updated_at`), sequences and triggers from
`docs/db-facts.txt`. It never drops the `public` schema and there is **no `auth.users` block**
(the website has 0 auth users).

After the SQL commits, `reset.js` deletes the retired bucket through the **Storage API**
(`assets`: 44 objects, no backup — a user decision), because Supabase blocks
`delete from storage.objects` and inside the transaction that would roll the whole reset back.
It refuses any other bucket id.

**Requires:** a real TTY on stdin AND stdout, then the project ref typed exactly, then
`CONFIRM RESET` typed exactly. An agent cannot satisfy that: piped stdio exits 1 before any DB
connection. Dry run (`node reset.js --ref …`) is unrestricted and prints `sha256(reset.sql)`,
the website signature verdict and "will delete N objects, X bytes".

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

## 9. Dependency table (W7)

Every package, whether it works on the web, and what happened to it. "Removed" means it is gone
from `pubspec.yaml`; the web build never had an implementation of it.

| Package | Web support | Action |
|---|---|---|
| `flutter` (SDK) | yes — the only target | keep |
| `supabase_flutter` | yes (REST/Storage/Auth over fetch; persists its own session on web) | keep |
| `drift` | yes, on wasm (`sqlite3.wasm` + `drift_worker.js`, both committed in `web/`) | keep, **pinned family** |
| `web` | yes — `navigator.storage`, WakeLock, Blob download | added |
| `pdf` + `printing` | yes (`sharePdf`/`layoutPdf`; Web Share API on iOS, download fallback) | added (W5) |
| `http` | yes — only for the portable `ClientException` network shape | added |
| `material_symbols_icons` | yes (font asset, bundled) | keep |
| `uuid` | yes (pure Dart) | keep |
| `intl` | yes (pure Dart) | keep |
| `cupertino_icons` | yes | keep (unused by screens yet) |
| `drift_dev`, `build_runner` | dev only | keep |
| `sqlite3` | dev only — `NativeDatabase` for `flutter test` on the VM | keep as a dev dependency |
| `sqlite3_flutter_libs` | **no web implementation** | removed (nothing native ships) |
| `flutter_secure_storage` | web impl exists, but pointless here: `supabase_flutter` already persists the session and the device id lives in drift | removed |
| `device_info_plus` | web impl exists (user agent only) — a UUID is enough | removed |
| `path_provider` | no writable filesystem in a browser tab | removed |
| `print_bluetooth_thermal` | no Web Bluetooth-to-ESC/POS path, and no hardware pairing on iPad | removed (W5) |
| `esc_pos_utils_plus` | ESC/POS byte building for the above | removed (W5) |
| `google_fonts` | would fetch fonts at runtime from a CDN — impossible offline | never used; fonts are bundled assets |

**Scripts (Node 18+):** `pg` (read-only export/db-facts), `@supabase/supabase-js` (admin: owner
user, storage upload/delete), `sharp` (images to ≤400 px WebP, PWA icons),
`@electric-sql/pglite` (dev: run migrations + RLS tests with no live DB), `playwright`
(dev, dev-only: `scripts/offline-test.js`).

**Env (never committed).** Only these two are compiled into the bundle:
```
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_ANON_KEY=<anon/publishable key>
```
Build: `node scripts/build-web.js` → `flutter build web --release --no-web-resources-cdn
--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`

---

## 10. Build, release and hosting

```bash
# ONE build+scan command. It never deploys and never prints a value.
node scripts/build-web.js            # build + scan
node scripts/build-web.js --scan-only
```

What it does: reads `.env` through `scripts/env.js`, passes ONLY
`SUPABASE_URL` + `SUPABASE_ANON_KEY` as `--dart-define`s, runs
`flutter build web --release --no-web-resources-cdn`, then

1. neutralises Flutter's `serviceWorkerSettings` in `flutter_bootstrap.js` and deletes the
   generated `flutter_service_worker.js` (Flutter 3.47's worker calls
   `self.registration.unregister()` and caches nothing — see §10.5),
2. scans all 50+ files in `build/web` for the service-role key, the DB password and the owner
   credentials, with the SUPABASE_URL host as a POSITIVE control,
3. asserts the offline set is present: `canvaskit/canvaskit.wasm`, `sqlite3.wasm`,
   `drift_worker.js`, `sw.js`, both bundled fonts, the logo and the icons.

### 10.1 Hosting (Cloudflare Pages, free — the USER deploys)

```bash
npx wrangler pages deploy build/web --project-name stardom-pos
```

`web/_headers` is copied into the build and sets the cache policy: `index.html`,
`flutter_service_worker.js`-successor (`sw.js` — see §10.5) and `version.json` must
revalidate; hashed assets, `canvaskit/*`, the wasm and the fonts may be cached forever;
`sqlite3.wasm` is served as `application/wasm`.

**Free-tier note:** a Supabase free project **pauses after 7 days with no activity**. Data is
kept; it is restored from the dashboard when the project wakes. The booth iPad therefore opens
the app online at least every few days (the sync loop is enough activity), and the owner-setup
checklist says so.

### 10.2 Web bundle secret scan — what it proves, and what it does not

The scan searches the BUILT bundle, so `Env.*` tree-shaking no longer hides anything:
`--dart-define` values end up in `main.dart.js` as string literals. That is exactly why the
SUPABASE_URL host is a required POSITIVE control. A genuine `found=0` for the owner credentials
is only meaningful next to `CONTROL (SUPABASE_URL host) found=1` — a build that lost its defines
must never be reported as "no secrets".

`sb_secret_` is matched only with a ≥20-character payload: supabase's own Dart code contains the
bare prefix while checking key style, so a substring search reports a leak in every build. The
bare-prefix count is still printed, with its maximum payload length, so the conclusion
"prefix literal, not a value" is evidenced rather than assumed.

### 10.3 Vendored web assets (and why those exact files)

| File | Source | Why this one |
|---|---|---|
| `web/sqlite3.wasm` | sqlite3.dart release **2.9.4** (730,989 bytes, sha256 `922a76b1…b52117`) | drift 2.x is built against the **2.x** sqlite3 package, and a 3.x wasm does not load. The first attempt used a wasm copied out of drift's devtools bundle and the app failed at boot: the worker came up, `sqlite3.wasm` was requested, and nothing else happened. Version-matched, verified by the offline test. |
| `web/drift_worker.js` | compiled here: `dart compile js -O2 web/drift_worker.dart -o web/drift_worker.js` from **drift 2.31.0** | the worker speaks drift's wire protocol to `main.dart.js`, so it must be the same drift version. Compiling it locally is reproducible and cannot silently mismatch a `pub upgrade`. |
| `web/icons/*`, `web/favicon.png` | generated: `node scripts/pwa-icons.js` from `assets/images/stardom-logo.webp` | the real brand logo (read from the read-only website folder), with maskable variants padded to the 60 % safe zone. |
| `web/sw.js` | hand-written | Flutter's worker unregisters itself (§10.3); the shell list inside it is generated by `scripts/build-web.js` from the actual build output. |

### 10.4 Measured result (this build)

`node scripts/offline-test.js`, Chromium (headless), serving `build/web` over loopback:

```
OK   app boots online (Flutter view mounted)
OK   drift reports which storage backend it picked — storageMode=sharedIndexedDb persistent=true
OK   navigator.storage.persist()'s answer is recorded — storagePersisted=unknown
OK   zero CDN requests while online
OK   our service worker is registered
OK   app OPENS with the network off (shell served from cache)
OK   the local database opens offline too (same storage backend) — storageMode=sharedIndexedDb
OK   the outbox state is readable offline (no sale is lost) — pendingSales=0 imagesCached=0
OK   zero CDN requests while offline
```

**Storage mode measured: `sharedIndexedDb`** — a durable, shared-worker IndexedDB backend, chosen
WITHOUT cross-origin isolation. That is why no COOP/COEP headers are served (§10.1): the mode
WebKit can actually use here does not need them, and adding them would break the cross-origin
Supabase requests instead. `storagePersisted=unknown` on this run is correct, not a bug: it is
written into settings once a store row exists (the test build has none yet).

**Not verified:** real Safari on the iPad and its storage-mode choice — Playwright's WebKit on
Windows is not iOS Safari. Settings and `window.__stardomBootInfo` REPORT the mode on the real
device; `docs/owner-setup.md` has the on-device Airplane-Mode check.

### 10.5 Service worker and updates

Flutter 3.47's generated worker is a stub that unregisters itself, so `web/sw.js` is ours:
app-shell precache (entry point, engine, wasm, worker, fonts, logo, icons) plus a network-first
navigation strategy. Supabase REST/Storage/Auth are cross-origin and are never intercepted.

**Update behaviour:** reopening the app while online fetches a fresh `index.html` (network-first)
and revalidates `sw.js`; the new version is used from the next load on. Offline, the cached shell
keeps the booth running. `VERSION` in `web/sw.js` is the cache-busting knob.

---

## 11. Stage 2 runbook (print only — DO NOT RUN FROM AN AGENT)

Everything below is executed BY THE USER, in his own terminal. An agent prints
this section; it never runs steps 3–5. The live project is
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

# 6. VERIFY (read-only probes; throwaway anon user for the deny tests)
node verify.js

# 7. BUILD THE PWA (no deploy; scans the bundle and prints the deploy command)
node scripts/build-web.js

# 8. DEPLOY (the USER)
npx wrangler pages deploy build/web --project-name stardom-pos
# then, ON THE iPAD: open the URL in Safari -> Share -> Add to Home Screen ->
# open from the icon -> sign in ONCE -> docs/owner-setup.md from step 1.
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
   the anon probe with a **throwaway** user, `security_invoker` on `order_status`,
   the `pos-assets` bucket private, 5 random images ≤400px, and
   `sum(stock_events) = products.stock_quantity` for every product.
7. `node scripts/build-web.js` — build the PWA and scan it (no deploy).
8. Open the deployed URL **on the iPad**, Add to Home Screen, open it from the icon, and sign in
   ONCE inside the installed app (W1). Follow `docs/owner-setup.md`.

**Local pre-flight (agent-safe, no live DB):** `node --test scripts/*.test.js` runs the PGlite
suite — migrations 001→004 applied twice, RLS, append-only enforcement, server LWW, the reset
prechecks, `register_device` — plus the env-whitelist and ₱-glyph checks. `flutter test` runs the
Dart suite, and `node scripts/offline-test.js` boots the built PWA in Chromium, asserts that no
CDN was contacted and reloads it with the network off.

**What has NOT been verified here:** real Safari on the iPad (Playwright's WebKit on Windows is
not iOS Safari), and the storage backend WebKit actually picks — it is REPORTED in Settings and
on `window.__stardomBootInfo`, never assumed. See `docs/owner-setup.md` for the on-device checks.

**Sync notes that the runbook depends on:** pull cursors are per table
(`pull_cursor:<table>`), keyset-paged on `server_updated_at` (mutable) and
`server_created_at` (append-only); a device clock 10 minutes ahead or behind
loses nothing. Offline is never a failure: a sale stays pending indefinitely,
and only a real 4xx/5xx burns an attempt (8 attempts, 1s→60s backoff).
