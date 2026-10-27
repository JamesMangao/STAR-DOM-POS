# ST⭐️R:Dom POS

> **Offline-first booth POS** for the ST⭐️R:Dom × ka1ofakind artisan pop-up.  
> Flutter web PWA · Supabase backend · Cloudflare Pages hosting.

---

## Overview

Single-owner point-of-sale system designed to run on an **iPad 9th gen** (Add to Home Screen → standalone PWA). Works fully offline at the booth — products, cart, and sales are stored locally via SQLite-on-WASM, then synced to Supabase when the booth gets Wi-Fi.

| Concern | Solution |
|---|---|
| Target device | iPad 9th gen (iPadOS Safari, standalone PWA) |
| Offline storage | `drift` on WASM (`sqlite3.wasm` + `drift_worker.js`, same-origin) |
| Backend | Supabase (Postgres + Auth + Storage) |
| Hosting | Cloudflare Pages (free tier, direct `build/web` upload) |
| Receipts | PDF via system share/AirPrint (`pdf` + `printing` packages) |
| Fonts | Bundled — Sora + Plus Jakarta Sans (no CDN fetch at runtime) |
| Secrets | `--dart-define` for `SUPABASE_URL` + `SUPABASE_ANON_KEY` only |

---

## Tech Stack

- **Flutter 3.x** (web-only target, no APK/iOS build)
- **Dart** with `drift` for local SQLite via WASM
- **Supabase** — Auth (owner sign-in), Postgres (source of truth), Storage (product images)
- **Cloudflare Pages** — free-tier hosting, direct upload
- **Node.js scripts** — build, scan, seed, import/export, offline tests

---

## Project Structure

```
STARDOM-POS/
├── lib/
│   ├── main.dart          # App shell: boot, session, sync, cart, adaptive nav
│   ├── core/              # Design tokens, theme, icons, env, format/PDF, web APIs
│   ├── data/              # Drift schema, Supabase sync, business logic, printing
│   └── ui/                # Every screen + the shared UI primitives
│       ├── sell.dart      # Sell grid, top sellers, barcode
│       ├── orders.dart    # Order history, voids, re-sell
│       ├── products.dart  # Shelf list, categories, stock
│       ├── reports.dart   # Per-day / all-time report + cash count + Close Day
│       ├── settings.dart  # Shop, receipt, devices, sync, export
│       ├── cart*.dart, payment*.dart, receipt.dart, sign_in.dart
│       ├── adaptive.dart  # Breakpoints: compact / medium / wide
│       ├── scope.dart     # PosScope (db, sync, cart, devices) above MaterialApp
│       └── widgets.dart   # Shared primitives (PosButton, SectionCard, PillChip…)
├── web/
│   ├── index.html         # PWA entry, viewport-fit=cover, no pinch-zoom
│   ├── sw.js              # Custom service worker (offline shell)
│   ├── sqlite3.wasm       # SQLite engine (same-origin, offline)
│   └── drift_worker.js    # Compiled Drift WASM worker
├── scripts/               # Node-only tooling (never imported by Flutter)
│   ├── build-web.js       # Build PWA + secret scan (never deploys)
│   ├── env.js             # Single .env loader + dart-define whitelist
│   ├── import.js          # Seed products from Supabase Storage
│   ├── verify.js          # Verify DB state post-import
│   ├── reset.js           # Nuclear reset (requires CONFIRM_RESET)
│   ├── reseed.js          # Re-seed the catalogue into a live DB
│   ├── change-owner.js    # Rotate the owner account
│   └── ...                # offline-test, sw-test, font-check, pwa-icons, review-bundle
├── supabase/
│   ├── migrations/        # SQL migrations (001_init → 006_dedupe_uniqueness)
│   ├── seed/              # Base seed (store, payment methods, receipt settings)
│   ├── reseed/            # Catalogue re-seed payloads (pairs with scripts/reseed.js)
│   └── reset/             # reset.sql (nuclear, pairs with scripts/reset.js)
├── docs/
│   ├── design-system.md   # Design tokens, components, iPad device rules
│   ├── owner-setup.md     # Print this — Add to Home Screen + Guided Access guide
│   ├── plan.md            # Full implementation plan + architecture decisions
│   ├── mockup/            # Board mockups the design system was traced from
│   └── archive/           # Earlier plans, inventory notes, review bundles
└── assets/
    ├── fonts/             # Sora.ttf, PlusJakartaSans.ttf (bundled, no CDN)
    ├── images/            # Brand assets (stardom-logo.webp, favicon set)
    └── catalogue/         # Offline product catalogue + images
```

---

## Screens

Five tabs — **Sell · Orders · Products · Reports · Settings** — behind one adaptive shell:

| Canvas | Nav |
|---|---|
| `< 600 pt` (phone) | Bottom bar, 5 tabs, ≥ 56 pt targets |
| `600–899 pt` (portrait iPad, Android tablet) | 72 px icon rail (icon above label) |
| `≥ 900 pt` (iPad landscape, desktop) | 250 px rail with wordmark + two-pane Sell/cart split |

The active tab is the design system's **yellow gradient pill with a 4.5 px crimson accent bar and a hard `2px 3px 0` stamp shadow** (§2.7). The bar's slot is reserved in both states, so switching tabs never nudges the icon or label sideways.

**Reports** is scoped by the header button: **Today**, **Pick a date…**, or **All time**. Totals, by-payment-method, by-hour and by-category follow the scope; the drawer tools (Cash count, Close Day, End-of-Day nudge) only appear on a single business day, because a drawer closes per day.

---

## Development

### Prerequisites

- Flutter SDK (channel stable, web enabled)
- Node.js 20+
- A `.env` file — copy `.env.example` and fill in your Supabase credentials

### Run locally

```bash
flutter run -d chrome
```

### Checks

```bash
flutter analyze   # static analysis (0 errors expected)
flutter test      # unit + widget suites: shell boot, adaptive layout,
                  # cart/undo, sell screen, drift DB, sync policy
```

### Build the PWA (+ secret scan)

```bash
node scripts/build-web.js
```

This builds `build/web` in release mode, replaces Flutter's stub service worker with `web/sw.js`, generates `build-manifest.json` for the SW cache, and scans every output file for leaked secrets. It **never deploys**.

### Deploy to Cloudflare Pages

The project's production branch is **`main`**. Without `--branch`, Wrangler
uploads a *preview* deployment that `stardom-pos.pages.dev` does not serve:

```bash
npx wrangler pages deploy build/web --project-name stardom-pos --branch=main
```

Verify the production domain picked up the build by comparing the `build` id
in `build/web/build-manifest.json` against
`https://stardom-pos.pages.dev/build-manifest.json`.

**Live:** https://stardom-pos.pages.dev

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `node scripts/build-web.js` | Build PWA + scan for secret leaks |
| `node scripts/import.js` | Import products from Supabase Storage into the DB |
| `node scripts/verify.js` | Verify product/image state post-import |
| `node scripts/export.js` | Export current DB state to JSON |
| `node scripts/db-facts.js` | Print live DB stats (read-only) |
| `node scripts/reset.js` | Nuclear DB reset (requires `CONFIRM_RESET=yes`) |
| `node scripts/reseed.js` | Re-seed the catalogue into a live DB |
| `node scripts/change-owner.js` | Rotate the owner account |
| `node scripts/sw-test.js` | Service-worker cache + offline assertions |
| `node scripts/pwa-icons.js` | Regenerate the PWA icon set |
| `node scripts/manifest.js` | Regenerate `web/manifest.json` |
| `node scripts/font-check.js` | Verify ₱ (U+20B1) exists in bundled fonts |
| `node scripts/offline-test.js` | Playwright: boot + offline reload smoke test |

---

## Environment Variables

Copy `.env.example` → `.env`. Only two variables are compiled into the Flutter bundle via `--dart-define`:

| Variable | Used for |
|---|---|
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_ANON_KEY` | Supabase anon (public) key |

All other variables in `.env` are Node-script-only and are never passed to the Flutter build.

---

## Design System

See [`docs/design-system.md`](docs/design-system.md) for the full token reference, component specs, and iPad device rules (touch targets ≥ 48 pt, no hover dependencies, safe-area insets, font-size ≥ 16 px for inputs, etc.).

See [`docs/owner-setup.md`](docs/owner-setup.md) for the step-by-step iPad setup guide (print and keep at the booth).

---

## Key Constraints

- **Web only** — no APK, no iOS build, no paid Apple Developer account required.
- **Offline-first** — the app must load, show products, and record a sale with zero network.
- **No CDN at runtime** — CanvasKit, fonts, and SQLite are all same-origin assets.
- **No secrets in the bundle** — `build-web.js` scan exits non-zero if any credential leaks.
- **Bundled fonts** — Sora lacks ₱ (U+20B1); Plus Jakarta Sans is the declared fallback in `lib/core/theme.dart`.
