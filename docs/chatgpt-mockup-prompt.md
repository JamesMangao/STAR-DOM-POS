# STAR:DOM POS — Mockup Generation Prompt

Copy the block between `PROMPT START` / `PROMPT END` and paste it into ChatGPT (GPT-4o image / DALL-E).
Attach the product image files listed in section 10 to the chat for best fidelity.

---

PROMPT START

Create a polished mobile app UI presentation board for a point-of-sale (POS) app called **STAR:DOM POS**, for a single-owner artisan booth / local pop-up store in the Philippines. The cashier uses it on an Android phone. It is offline-first with multi-device sync. There is NO login screen, NO delivery, NO online orders, NO commission, NO rider or shipping UI anywhere — do not draw any of those.

OUTPUT FORMAT:
- One presentation board, Dribbble / Behance case-study look.
- 8 phone screens, portrait 9:19.5, arranged 2 rows of 4, side by side, evenly spaced.
- Clean light-gray board background (#F2F2F4). A short label under each screen in small gray uppercase text: "01 SELL", "02 CART", "03 CASH PAYMENT", "04 GCASH PAYMENT", "05 RECEIPT", "06 PAYMENT METHODS", "07 ORDER HISTORY", "08 END-OF-DAY REPORT".
- A board header at top: the STAR:DOM star logo + "STAR:DOM" wordmark, then "STAR:DOM POS" as the title, and the tagline "Fast. Simple. Offline. Built for Filipino Small Businesses."
- Crisp legible text, consistent spacing, soft shadows under each phone, flat UI mockup style (not photorealistic).

DESIGN SYSTEM (follow exactly on every screen — consistency is mandatory):
- Primary red (brand, CTAs, prices, active states): #B70011. Primary hover: #DC2626.
- Accent yellow (badges, highlights, active nav, focus): #FED01B. Soft yellow fill: #FFF3B8. Yellow border: #EEC200. Text on yellow: #6F5900.
- App background: warm cream #FFF8F5. Subtle fills: #FAF2EE. Muted fills: #F4ECE8. Muted badge bg: #E9E1DD.
- Cards: #FFFFFF with 1px border #E6BDB8.
- Ink (headings): #1E1B19. Secondary text: #5C403C. Tertiary text: #8A6A62. Stronger borders: #D6D3D1.
- Success green: #15803D. Error red: #B70011 on #FFE0DE bg with #FFB4AB border, text #93000A.
- Typography: **Sora** (weights 600/700/800) for all headings, prices, buttons, labels. **Plus Jakarta Sans** (400–800) for body text. Monospace (Cascadia Mono or similar) for order numbers, SKUs, reference numbers.
- Border radius: 14px on cards and product cards, 18px on modals, 999px (full pill) on chips, badges, search bar, status pills.
- Shadows: cards use a soft shadow (0 2px 6px rgba(60,20,16,.06)); primary CTA buttons use a hard offset "stamp" shadow 2px 2px 0 #1E1B19; modals use a deeper soft shadow.
- Buttons: primary = solid #B70011, white text, Sora 600 13px, radius 10px, padding 10px 18px, hard stamp shadow on the big CTA. Secondary = #FED01B background, #231B00 text, 1px #EEC200 border. Ghost = transparent, #1E1B19 text, 1px #D6D3D1 border.
- Chips: pill shape, 1px #E6BDB8 border, white bg, #5C403C text, Sora 700 12px. Active chip = solid #B70011 bg, white text.
- Badges: pill, Sora 800 10px uppercase. Yellow badge = #FED01B bg, #6F5900 text. Green badge = #15803D text on #E5F6E7 bg. Red badge = #B70011 bg white text. Gray badge = #E9E1DD bg, #5C403C text.
- Logo: hand-drawn style wordmark — a big yellow five-pointed star with a cute face (two star-shaped eyes, toothy grin), the word "STAR" in hand-lettered green/red/blue letters flowing into the star, "DOM" in white bubble letters, and "by nick" in small orange handwriting under it. Use the attached stardom-logo.webp as the logo on every screen header.
- All prices in Philippine pesos with the ₱ symbol, 2 decimals, tabular numerals, in Sora 800, colored #B70011 (e.g. ₱30.00, ₱120.00).
- Icons: simple outlined glyphs (Material Symbols Outlined style), never emoji.
- Bottom navigation bar on Screens 1, 2, 7: 5 tabs — Sell, Orders, Products, Reports, Settings — outlined icon + 11px label, active tab = yellow gradient pill (#FFF3B8 → #FED01B) with #1E1B19 text and a hard 2px offset shadow.

SCREEN 01 — SELL:
- Header: STAR:DOM star logo + "STAR:DOM" wordmark (Sora 800, #1E1B19) with a small solid #B70011 dot after it; below it tiny letterspaced "ARTISAN & POP-UP HUB" in #5C403C. On the right a sync chip: yellow pill (#FFF3B8 bg, #EEC200 border, #6F5900 text) with a small yellow dot and the text "Offline - 3 pending".
- Search bar: pill, #FAF2EE fill, magnify outline glyph on the left, placeholder "Search products", barcode/scan outline glyph on the right.
- Category chips row (scrollable): "All" (active, solid #B70011 white text), "Stickers", "Art Print", "Keychains", "Button Pins", "Sticker Sheets", "Other".
- Product grid, 2 columns, white cards (1px #E6BDB8 border, 14px radius, soft shadow), each with a square product image, product name (Sora 700 14.5px, #1E1B19, max 2 lines), and price (Sora 800 15.5px, #B70011). Use these REAL products with REAL prices:
  "Bleeding heart" ₱30.00 · "Tamaraw" ₱30.00 · "Tarsier" ₱30.00 · "Goby" ₱30.00 · "Kalaw" ₱30.00 · "Hinata" ₱30.00 · "Punch" ₱30.00 · "Hollanov" ₱30.00 · "Trees (4x6")" ₱100.00 · "Heated Rivalry (4x6")" ₱100.00 · "Goby keychain" ₱150.00 · "Bread tag" ₱150.00 · "Doggo" ₱35.00 · "Gay af" ₱35.00 · "Fishies (4x3)" ₱80.00 · "Smiskis (4x3)" ₱80.00.
  Product images: hand-drawn die-cut sticker art with thick dark ink outlines on white background (a bleeding-heart pigeon with a yellow star, a tamaraw, a tarsier, a goby fish, a kalaw bird, an anime-style girl, a hockey player, a hollandov bird, art prints, acrylic keychains, enamel pins, sticker sheets). Use the attached product images as the card art.
- Sticky cart bar at the bottom (above the nav): white bar, 1px #E6BDB8 top border, left side "3 items - ₱120.00" in Sora 800 #1E1B19, right side a solid #B70011 pill button "View Cart" in white Sora 700.
- Bottom nav: Sell (active), Orders, Products, Reports, Settings.

SCREEN 02 — CART:
- Header: back arrow glyph + title "Cart" (Sora 800 22px #1E1B19) + the same sync chip "Offline - 3 pending" on the right.
- Line item rows (white cards, 14px radius): each row has the product thumbnail, product name (Sora 700 14.5px), unit price (Sora 800 #B70011), and a quantity stepper: a 46px square minus button, the quantity number centered in Sora 800 19px, a 46px square plus button — all with 1px #E6BDB8 borders, 12px radius.
  Items: "Good Boy" ₱30.00 ×1 · "Rozanov" ₱30.00 ×1 · "Hinata" ₱30.00 ×2.
- Discount field: labeled input "Discount" with ₱ prefix, value "0.00".
- Order note field: labeled input "Order note", placeholder "Add a note (optional)".
- Totals block: "Subtotal" ₱120.00, "Discount" -₱0.00, then "Total" ₱120.00 in large bold Sora 800 24px #1E1B19 with the amount in #B70011.
- Payment method buttons row (from enabled methods): "Cash" (solid #B70011, white text, active), "GCash" (white, 1px #E6BDB8 border, blue G glyph), "GoTyme" (white, 1px border, green glyph), and a "More" ghost button.
- Bottom nav: Sell, Orders, Products, Reports, Settings.

SCREEN 03 — CASH PAYMENT:
- Header: back arrow + "Cash Payment" (Sora 800 22px) + sync chip.
- "Amount Due" label (Sora 800 10px uppercase #5C403C, letterspaced) and the amount "₱120.00" very large (Sora 800 34px, #B70011).
- Quick amounts row: pill buttons "₱100", "₱200", "₱500", "₱1000", and "Exact" — white bg, 1px #E6BDB8 border, Sora 700 13px #1E1B19; the "₱200" pill is active (solid #B70011 white text).
- Numeric keypad: 3×4 grid of large round buttons (1px #E6BDB8 border, white bg, Sora 700 20px): 1 2 3 / 4 5 6 / 7 8 9 / . 0 ⌫.
- "Amount Received" display: "₱200.00" in Sora 800 28px #1E1B19.
- Change line: "Change" label + "₱80.00" in Sora 800 28px #15803D (green, prominent).
- Big full-width primary button "Complete Sale" — solid #B70011, white Sora 800 15px, radius 10px, hard stamp shadow 2px 2px 0 #1E1B19.

SCREEN 04 — GCASH PAYMENT:
- Header: back arrow + "GCash Payment" + sync chip.
- "Amount Due" label + "₱120.00" large Sora 800 34px #B70011.
- Button "Show QR" — white bg, 1px #E6BDB8 border, Sora 700 13px, with a small QR outline glyph.
- Fullscreen QR modal state shown as the main content: white card (18px radius, soft shadow + hard stamp shadow) containing a large square QR code placeholder (black and white QR pattern), below it "GCash" in Sora 800 18px #1E1B19, "RIAN DOMINIC CABREROS" in Plus Jakarta Sans 600 13px #5C403C, and "Amount Due ₱120.00" in Sora 800 20px #B70011.
- Below the modal: "Reference Number" labeled input with value "091712345678" in monospace, and a small note "Required for e-wallet payments" in #8A6A62 11px.
- Big full-width primary button "Confirm Payment" — solid #B70011, white Sora 800 15px, hard stamp shadow.

SCREEN 05 — RECEIPT:
- Success check: a 52px circle icon tile in #E5F6E7 with a green check glyph (#15803D).
- "Payment Successful" title (Sora 800 20px #1E1B19) and a small gray badge "Saved offline - will sync" (pill, #FFF3B8 bg, #EEC200 border, #6F5900 text).
- Receipt preview: white paper card, 1px #1E1B19 border, 4px radius, soft + hard stamp shadow, containing:
  - Header: small red rounded square with a yellow ★, "STAR:DOM" Sora 800 22px, "ARTISAN & POP-UP HUB" tiny letterspaced, and on the right "OR" in red mono + order number "A1-261016-007" in monospace.
  - A 3px double #1E1B19 divider.
  - Item rows: "Good Boy" ₱30.00 ×1 — ₱30.00 · "Rozanov" ₱30.00 ×1 — ₱30.00 · "Hinata" ₱30.00 ×2 — ₱60.00 (12.5px, dashed row borders #D6D3D1).
  - "Subtotal" ₱120.00, "Discount" -₱0.00, then "TOTAL" ₱120.00 in Sora 800 15px with a 2px top / 3px double bottom #1E1B19 border.
  - "Payment: Cash" · "Received ₱200.00" · "Change ₱80.00" in small text.
  - A faint red circular "PAID" stamp rotated -14°.
- Action buttons row: "Print" (primary #B70011 with printer glyph), "Share" (ghost), "New Sale" (secondary #FED01B).

SCREEN 06 — SETTINGS > PAYMENT METHODS:
- Header: back arrow + "Payment Methods" (Sora 800 22px) + sync chip.
- List of payment method rows (white cards, 14px radius): each row has a colored icon tile (38px, 10px radius), the method name (Sora 700 14.5px), a small gray subtitle, and a toggle switch on the right (green #15803D when on):
  - "Cash" — subtitle "Physical currency" — toggle ON.
  - "GCash" — subtitle "RIAN DOMINIC CABREROS · 097***33" — toggle ON.
  - "GoTyme" — subtitle "RIAN DOMINIC CABREROS" — toggle ON.
- "Add Payment Method" button: full-width ghost button with a plus glyph, 1px #D6D3D1 border, Sora 700 13px #1E1B19.
- Edit form card below (white, 14px radius): title "Edit GCash" (Sora 700 15px), fields "Name" (value "GCash"), "Type" (dropdown value "E-wallet"), a QR upload area (dashed 1px #D6D3D1 border box with an upload glyph and "Upload QR image" text), "Account Name" (value "RIAN DOMINIC CABREROS"), "Account Number" (value "097***33"), and a "Require reference number" toggle (ON, green).
- Bottom nav: Sell, Orders, Products, Reports, Settings (active).

SCREEN 07 — ORDER HISTORY:
- Header: "Orders" (Sora 800 22px) + sync chip.
- Filter bar: a segmented pill bar (#FAF2EE bg, 11px radius) with segments "All" (active, solid #1E1B19 white text), "Cash", "GCash", "GoTyme", and a date pill "Today" on the right in yellow.
- Order rows (white cards, 14px radius, 1px #E6BDB8 border): each row shows the order number in monospace ("A1-261016-007"), the time below it in #8A6A62 ("2:41 PM"), the total on the right in Sora 800 15.5px #B70011 ("₱120.00"), a small method icon, and status badges:
  - "A1-261016-007" · 2:41 PM · ₱120.00 · Cash · green badge "Synced" + gray badge "Completed".
  - "A1-261016-006" · 2:12 PM · ₱80.00 · GCash · amber badge "Pending" + gray badge "Completed".
  - "A1-261016-005" · 1:47 PM · ₱150.00 · GoTyme · green badge "Synced" + gray badge "Completed".
  - "A1-261016-004" · 1:05 PM · ₱60.00 · Cash · red badge "Failed" + gray badge "Completed".
  - "A1-261016-003" · 12:30 PM · ₱100.00 · GCash · gray badge "Voided".
- A small "Void" text action (red #B70011, Sora 700 12.5px) on the first row.
- Bottom nav: Sell, Orders (active), Products, Reports, Settings.

SCREEN 08 — END-OF-DAY REPORT:
- Header: "End-of-Day Report" (Sora 800 22px) + sync chip.
- Total sales card (white, 14px radius, 6px top accent gradient #B70011 → #FED01B → #BC5200): label "TOTAL SALES" (Sora 800 10px uppercase #5C403C), value "₱3,480.00" (Sora 800 30px #B70011), sub "29 transactions · 1 voided" in #5C403C.
- Hourly bar chart card: title "Hourly Sales" (Sora 700 15px), 12 vertical bars for 10 AM–9 PM in #B70011 with the tallest bar highlighted in #FED01B, hour labels below in #8A6A62 10px.
- Per-method breakdown card: title "By Payment Method", rows with an 11px color swatch, method name, count and amount in monospace: "Cash" 14 · ₱1,940.00 (red swatch) · "GCash" 11 · ₱1,080.00 (blue swatch) · "GoTyme" 4 · ₱460.00 (green swatch).
- Cash count card: title "Cash Count", rows "Expected ₱1,940.00", "Actual ₱1,935.00", "Variance -₱5.00" in #B70011 Sora 800.
- Big full-width primary button "Close Day" — solid #B70011, white Sora 800 15px, hard stamp shadow.

GLOBAL RULES:
- Keep every screen consistent with the tokens above: same hex values, same Sora / Plus Jakarta Sans type, same 14px card radius, same pill chips, same yellow active states, same hard stamp shadow on primary CTAs.
- No login, no register, no delivery, no shipping, no riders, no online orders, no commission, no user management UI anywhere.
- All money in ₱ with 2 decimals. All text crisp and legible. Flat UI mockup style, soft shadows, clean light-gray board.

PROMPT END

---

## Optional second prompt (same board style, 3 more screens)

PROMPT START

Continue the STAR:DOM POS presentation board with 3 more screens in the exact same design system (same hex tokens #B70011 / #FED01B / #FFF8F5 / #1E1B19, Sora + Plus Jakarta Sans, 14px card radius, pill chips, hard stamp shadow on primary CTAs, outlined glyphs, ₱ prices). Labels: "09 DEVICES", "10 SYNC DETAILS", "11 PRODUCTS".

SCREEN 09 — SETTINGS > DEVICES:
- Header: back arrow + "Devices" (Sora 800 22px) + sync chip.
- Device rows (white cards, 14px radius): device icon tile, device name (Sora 700 14.5px), "Last sync" line in #8A6A62, and a yellow "This device" pill badge on the first row:
  - "Cashier Phone A1" — "Last sync: 2 min ago" — yellow "This device" badge — toggle ON.
  - "Backup Tablet B2" — "Last sync: 1 hr ago" — toggle OFF (gray).
- A small gray note: "Disabled devices stop syncing and show a banner."

SCREEN 10 — SYNC DETAILS:
- Header: back arrow + "Sync Details" (Sora 800 22px).
- Status card (white, 14px radius): green dot + "Signed in as owner" in #15803D, "Last sync: 2:41 PM" in #5C403C.
- Pending queue card: title "Pending Queue" (Sora 700 15px), 3 rows with a small entity icon, entity name and detail: "Order A1-261016-006" · "Push failed - retrying", "Product Hinata" · "Updated 2:12 PM", "Product Trees (4x6")" · "Updated 1:47 PM" — each with a small amber clock glyph.
- Buttons: "Retry" (ghost, 1px #D6D3D1 border) and "Sync now" (primary #B70011, hard stamp shadow).

SCREEN 11 — PRODUCTS MANAGEMENT:
- Header: "Products" (Sora 800 22px) + sync chip.
- Search bar (pill, #FAF2EE) + category chips row: "All" (active #B70011), "Stickers", "Art Print", "Keychains".
- Product rows (white cards, 14px radius): square thumbnail, product name (Sora 700 14.5px), price (Sora 800 #B70011), stock line "24 in stock" in #8A6A62, and an active toggle (green ON):
  - "Bleeding heart" ₱30.00 · 17 in stock.
  - "Hinata" ₱30.00 · 21 in stock.
  - "Goby keychain" ₱150.00 · 4 in stock.
- A floating action button (FAB) bottom-right: solid #B70011 circle with a white plus glyph, hard stamp shadow.
- Bottom nav: Sell, Orders, Products (active), Reports, Settings.

PROMPT END

---

## Files to attach to the chat (from D:\STARDOM\STAR-DOM-Web\Assets)

Logo / brand:
- `stardom-logo.webp` (960×540 — the hand-drawn star wordmark; use on every header)

Product art for SELL grid / PRODUCTS / cart thumbnails (hand-drawn die-cut stickers, thick ink outlines):
- `Stickers\Bleeding heart.webp` (2000×1500)
- `Stickers\Tamaraw.webp` (2000×1500)
- `Stickers\Tarsier.webp` (2000×2571)
- `Stickers\Goby.webp` (2000×2829)
- `Stickers\Kalaw.webp` (2000×2571)
- `Stickers\Hinata.webp` (1620×2160)
- `Stickers\Punch.webp` (2000×2829)
- `Stickers\Hollanov.webp` (2000×1500)
- `Art Prints\Trees (4x6).webp` (873×658)
- `Art Prints\Heated Rivalry (4x6).webp` (1400×2100)
- `Keychains\Goby keychain.webp` (244×331)
- `Keychains\Bread tag keychain.webp` (217×316)
- `Button Pins\Doggo.webp` (2000×2000)
- `Button Pins\Gay af.webp` (2000×2000)
- `Sticker Sheets\Fishies (4x3).webp` (2000×1500)
- `Sticker Sheets\Smiskis (4x3).webp` (2000×1500)

Payment method icons:
- `Payment\GCash.webp` (400×400 blue G logo)
- `Payment\GOtyme.webp` (554×554 green logo)

Note: "Good Boy" and "Rozanov" (used in CART and RECEIPT) have no image files in the Assets folder — reuse the attached sticker art as their thumbnails.
