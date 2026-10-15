# STAR:DOM POS — Design System (ported from D:\STARDOM)

Source of truth: `D:\STARDOM\STAR-DOM-Web\css\site.css` ("STAR:DOM design system v2").
Values below are copied verbatim. POS adaptations are marked **[POS]** — everything else is identical to the website.

Style: **Structured Pop-Brutalism meets Utility Desktop.** Deep crimson + electric gold on warm stone. Sora display face, Plus Jakarta Sans body, Material Symbols icons.

---

## 1. Tokens

### 1.1 Color

| Token | Hex | Usage |
|---|---|---|
| `--primary` | `#B70011` | Brand, CTAs, prices, logo dot, active states |
| `--primary-hi` | `#DC2626` | Primary hover |
| `--on-primary` | `#FFFFFF` | Text on primary |
| `--yellow` | `#FED01B` | Accent, badges, highlights, active nav, focus ring |
| `--yellow-soft` | `#FFF3B8` | Soft yellow fills (pills, bundle note) |
| `--on-yellow` | `#6F5900` | Text on yellow |
| `--line-yellow` | `#EEC200` | Yellow borders |
| `--surface` | `#FFF8F5` | App background (warm cream) |
| `--surface-low` | `#FAF2EE` | Subtle fills, table headers, panel headers |
| `--surface-mid` | `#F4ECE8` | Icon tiles, mini-stats |
| `--surface-hi` | `#EEE7E3` | Muted badges, meters |
| `--surface-highest` | `#E9E1DD` | Muted badge bg, empty stamps |
| `--card` | `#FFFFFF` | Cards, sheets, modals |
| `--ink` | `#1E1B19` | Headings, primary text |
| `--ink-soft` | `#5C403C` | Secondary text, labels |
| `--ink-faint` | `#8A6A62` | Tertiary text, placeholders |
| `--line` | `#E6BDB8` | Borders (warm pink-tan) |
| `--line-hi` | `#D6D3D1` | Stronger borders, hover borders |
| `--green` | `#15803D` | Success, change amount, synced |
| `--tertiary` | `#954000` | Warm brown accent |
| `--tertiary-full` | `#BC5200` | Gradient end |
| `--tertiary-fixed` | `#FFDBCA` | Olive icon tile bg |
| `--on-tertiary-fixed` | `#341100` | Olive icon tile fg |
| `--outline` | `#916F6B` | Outline text on muted chips |
| `--ring-yellow` | `#FED01B` | Focus ring |

**[POS]** Semantic status colors (not in source; derived from source palette):
- Synced/success: `#15803D` (source `--green`)
- Pending/warning: bg `#FFF3B8`, border `#EEC200`, text `#6F5900` (source yellow family)
- Failed/error: `#B70011` (source `--primary`), bg `#FFE0DE`, border `#FFB4AB`, text `#93000A` (source alert-err)
- Voided/muted: bg `#E9E1DD`, text `#5C403C` (source `--surface-hi` / `--ink-soft`)

### 1.2 Typography

| Role | Family | Weights | Notes |
|---|---|---|---|
| Display | **Sora** | 600 / 700 / 800 | Headings, prices, KPIs, buttons. `letter-spacing: -.01em` (h1-h4), `-.5px` on brand wordmark |
| Body | **Plus Jakarta Sans** | 400 / 500 / 600 / 700 / 800 | UI text, inputs, tables |
| Mono | **Cascadia Mono** (fallback Consolas, Courier New) | 700 / 800 | Order numbers, SKUs, reference numbers, currency chips. `font-variant-numeric: tabular-nums` |

Base: `400 14px/1.6` body on `--surface`. Google Fonts import (same as source):
`Sora:wght@600;700;800` + `Plus+Jakarta+Sans:wght@400;500;600;700;800`.

**[POS]** Mobile type scale (portable, same families):
- Display XL (amount due, totals): Sora 800, 30–34px
- Display L (screen titles): Sora 800, 22–24px
- Display M (card titles, section heads): Sora 700, 15–18px
- Body: Plus Jakarta Sans 400/600, 14–15px
- Label/eyebrow: Sora 800, 10–11px, `letter-spacing: .12em`, uppercase
- Price: Sora 800, 15.5–20px, tabular-nums, `--primary`

### 1.3 Spacing

Source uses a 4px rhythm: `4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 26, 28, 30, 34, 40, 44, 46, 48, 50, 60`.
Card padding: `16px` (source `.card`), panel body `16px`, panel header `12px 16px`.
Grid gap: `16px` (source `.grid`), KPI gap `14px`.

**[POS]** Screen padding: `16px` sides, `12px` between sections, `8px` inside dense rows. Bottom nav height `64px` + safe-area.

### 1.4 Radius

| Token | Value | Usage |
|---|---|---|
| `--r-s` | `8px` | Small inputs, chips, pay-chips |
| `--r-m` | `11px` | Nav items, act-fields, search focus |
| `--r-l` | `14px` | Cards, KPIs, panels, product cards |
| `--r-xl` | `18px` | Modals, auth card |
| pill | `999px` | Badges, pills, chips, search box, status chips |

### 1.5 Elevation & tactile stamp

```
--sh-1: 0 1px 2px rgba(60,20,16,.05), 0 1px 1px rgba(60,20,16,.03)   /* cards, KPIs */
--sh-2: 0 2px 6px rgba(60,20,16,.06), 0 8px 20px rgba(60,20,16,.06)  /* hover, modals */
--sh-3: 0 8px 24px rgba(60,20,16,.12), 0 2px 6px rgba(60,20,16,.06)  /* modal backdrop card */
--stamp: 2px 2px 0 var(--ink)                                     /* brutalist hard offset */
--focus-ring: 0 0 0 2px #fff, 0 0 0 4px var(--yellow), 0 0 0 6px rgba(254,208,27,.35)
```

**[POS]** `--stamp` is used sparingly: primary CTA on cash payment, receipt paper, "Complete Sale" button. Everywhere else `--sh-1`/`--sh-2`.

### 1.6 Breakpoints

Source (desktop): `900px` (layout stacks), `560px` (mobile tweaks).
**[POS]** Mobile-first: base `360–430px` (phone portrait), `≥768px` (large phone / small tablet), `≥1024px` (tablet landscape). Bottom nav is fixed; content pads `64px + safe-area` at bottom.

### 1.7 Dark / light mode

Source is **light-only** (no dark tokens exist). **[POS]** Ship light theme only. Do not invent dark tokens.

### 1.8 Icons

**Material Symbols Outlined** (source: Google Fonts `Material+Symbols+Outlined:opsz,wght,FILL,GRAD@20..48,500..700,0..1,-50..200`).
Sizes: `.sm` 15px, base 20px, `.lg` 24px, `.xl` 30px. Filled variant via `FILL 1` for active states.
**[POS]** Flutter: `material_symbols_icons` package (or Material Icons fallback). One outlined glyph per action, never emoji.

---

## 2. Components (ported)

### 2.1 Buttons (`.btn`)

Base: inline-flex, gap 7px, radius 10px, padding `10px 18px`, Sora 600 13px, white-space nowrap. Hover `translateY(-1px)`, active `scale(.97)`.

| Variant | Style |
|---|---|
| `.primary` | bg `--primary`, white text, `--sh-1`; hover bg `--primary-hi`, `--sh-2` |
| `.secondary` | bg `--yellow`, text `#231B00`, border `1px --line-yellow`, `--sh-1`; hover bg `--line-yellow` |
| `.ghost` | transparent, `--ink` text, border `1px --line-hi`; hover bg `--surface-low`, border `--ink` |
| `.light` | white bg, `--primary` text, border `1px --line`; hover border `--primary` |
| `.danger` | white bg, `--primary` text, border `--primary`; hover bg `--primary`, white text |
| `.sm` | padding `5px 11px`, 12px, radius 8px |

**[POS]** Tap targets ≥ `48px` height. Primary CTA = full-width `.primary` with `--stamp` shadow on payment screens. Bottom nav uses outlined glyphs + 11px Sora 700 labels; active tab = yellow pill bg (`linear-gradient(135deg,#FFF3B8,#FFE37A 40%,#FED01B)`), border `#D89F00`, `--ink` text, hard shadow `2px 3px 0 rgba(35,27,0,.95)`.

### 2.2 Inputs (`.field input/select/textarea`)

Border `1px --line`, radius 10px, padding `10px 12px`, 14px body, white bg. Hover border `--line-hi`. Focus: border `--ink` + `--focus-ring`. Placeholder: `--ink-faint`, italic. Number inputs: spinners removed. Labels: Sora 800 11px, `letter-spacing .06em`, uppercase, `--ink-soft`. Required marker `*` in `--primary`.

**[POS]** Min input height `48px`. Search box: pill (999px), bg `--surface-low`, 40px input, focus-within white + border `--ink` + focus ring.

### 2.3 Cards (`.card`, `.kpi`, `.panel`, `.pcard`)

- `.card`: white, border `1px --line`, radius `--r-l` (14px), padding 16px, `--sh-1`.
- `.kpi`: card + min-height 96px; label Sora 800 10px uppercase `--ink-soft`; value Sora 800 24px `--primary` tabular-nums; icon tile top-right 34px radius 9px bg `#FFE0DE` `--primary`.
- `.panel`: white card + 6px top accent gradient (`--primary → --yellow → --tertiary-full`); header bg `--surface-low` padding `12px 16px`; body 16px.
- `.pcard` (product card): white, border `--line`, radius `--r-l`, hover `translateY(-3px)` + `--stamp` + `--sh-2`; art area 190px cover; body padding `12px 14px 14px`; brand 9.5px uppercase `--ink-soft`; name Sora 700 14.5px; price `.money` = Sora 800 15.5px `--primary` tabular-nums.

**[POS]** Product grid card: 2-col, art square (1:1), name 2-line clamp, price Sora 800 `--primary`, stock line 10.5px `--ink-soft`, low-stock flag (bg `#FFE0DE`, text `#93000A`, border `#FFB4AB`).

### 2.4 Chips / pills / badges

- `.chip`: border `1px --line`, pill, padding `6px 14px`, Sora 700 12px, white bg, `--ink-soft`; hover border `--ink` + lift; `.on` = bg `--primary`, white, border `--primary`, `--sh-1`.
- `.badge`: pill, padding `3px 9px`, Sora 800 10px uppercase `letter-spacing .05em`. Variants: `.live`/`.red` (primary bg), `.warn`/`.yellow` (yellow bg, `--on-yellow`), `.muted`/`.gray` (`--surface-hi` bg, `--ink-soft`).
- `.pill`: pill, padding `4px 12px`, Sora 800 11px. `.yellow` = `--yellow-soft` bg + `--line-yellow` border + `--on-yellow` text; `.red` = primary bg white text; `.gray` = muted.
- `.status-chip`: pill with 7px dot; `.yellow` (pending), `.gray` (voided), `.red` (failed/live).

**[POS]** SyncChip: pill, dot + label. Synced = green family; Offline-N-pending = yellow family; Failed = red family, tappable to retry.

### 2.5 Modals (`.modal-backdrop` / `.modal-card`)

Backdrop: fixed, `rgba(24,18,16,.45)`, blur 6px, `safe center` alignment, padding 20px. Card: max-width 420px, max-height `100vh-40px` scroll, white, border `1px --line-hi`, radius 18px, `--sh-2` + `--stamp`, padding `26px 26px 22px`, enter `translateY(14px) scale(.97)` → none, `.26s cubic-bezier(.22,1,.36,1)`. Icon tile 52px radius 14px bg `rgba(183,0,17,.1)` `--primary`. Title Sora 800 20px. Actions row: flex-end, gap 10px, buttons min-width 96px.

**[POS]** Bottom sheets preferred over center modals on phone; same tokens. Fullscreen QR modal: white, method QR centered, method name Sora 800, account name, amount due Sora 800 28px `--primary`.

### 2.6 Tables (`.tbl`)

Header: Sora 800 10px uppercase `letter-spacing .1em`, `--ink-soft`, bg `--surface-low`, padding `11px 12px`, sticky. Cells: padding `11px 12px`, 13px, border-bottom `1px #F3E9E6`. Row hover `#FFFAF3`. Mono for order numbers (Cascadia 12.5px 700). Price cells: Sora 800 `--primary` tabular-nums.

**[POS]** Tables → card lists on phone (same row content, stacked). Order rows: order_no mono, time `--ink-soft`, total Sora 800 `--primary`, method icon, status badges.

### 2.7 Nav

Source: sticky sidebar 250px, nav items radius 11px, active = yellow gradient pill + 4.5px `--primary` left bar + hard shadow.
**[POS]** Fixed bottom nav, 5 tabs: Sell | Orders | Products | Reports | Settings. Active tab per source active style (yellow gradient, hard shadow, filled glyph). Tap target ≥ 56px.

### 2.8 Receipt (`.rp-*`)

Paper: white, border `1px --ink`, radius 4px, `--sh-2` + `--stamp`, padding `30px 34px 22px`. Star mark: 44px radius 12px bg `--primary` with `★` in `--yellow` + `--stamp`. Header: 3px double `--ink` border-bottom. KV labels 9px uppercase `--ink-faint`. Items table: 12.5px, dashed row borders `--line-hi`. Total: 2px top / 3px double bottom `--ink` borders, Sora 800 14–15px. Stamp: 118px circle, 4px double `--primary` border, rotated -14°, mono uppercase. Issuer line centered 11px `--ink-soft`.

**[POS]** Receipt preview on screen = same paper look, max-width 340px, centered on `--surface-mid` stage. Print = ESC/POS Bluetooth, monochrome-safe.

### 2.9 Alerts / toasts / empty states

- `.alert.err`: bg `#FFE0DE`, text `#93000A`, border `#FFB4AB`. `.alert.ok`: bg `#E5F6E7`, text `#14532D`, border `#BBF7D0`. `.alert.info`: bg `#E5F2FF`, text `#1E3A8A`, border `#BFDBFE`.
- Toast: white, border `1.5px --line`, left bar 4px `--green`, radius 14px, shadow `0 10px 34px rgba(30,27,25,.16)`.
- Empty state: centered, icon tile 52px radius 14px `--surface-hi` `--ink-faint`, title Sora 700 15px.

### 2.10 Motion

Page enter: `.32s cubic-bezier(.16,1,.3,1)` fade + 8px rise. Hover lifts 1–3px. Modal spring `.26s cubic-bezier(.22,1,.36,1)`. `prefers-reduced-motion`: everything instant.
**[POS]** Keep ≤ 200ms for taps; no page-enter animation on tab switch.

---

## 3. Layout patterns & naming conventions

- Max content width 1400px (source). **[POS]** Full-bleed phone, 16px side padding.
- Naming: BEM-ish utility classes, kebab-case (`.page-head`, `.panel-hd`, `.k-value`). **[POS]** Flutter: `PascalCase` widgets, `camelCase` vars; token file `app_theme.dart` with `AppColors`, `AppRadius`, `AppShadows`, `AppTypography`.
- Currency: `₱` symbol, tabular-nums, 2 decimals (`₱120.00`). Mono for numbers in chips.
- Brand: `STAR:DOM` wordmark Sora 800 19px `letter-spacing -.5px` + 9px `--primary` dot with `0 0 0 3px rgba(183,0,17,.12)` halo. Sub: 9.5px `letter-spacing .14em` Sora 700 `--ink-soft`.
- Logo asset: `stardom-logo.webp` (960×540, hand-drawn yellow star with face, "STAR" green/red/blue, "DOM" white bubble, "by nick" orange). Favicon: `favicon-32.webp`.
- Focus-visible: `2px solid --primary`, offset 2px. Selection: `--yellow` bg, `--ink` text.
