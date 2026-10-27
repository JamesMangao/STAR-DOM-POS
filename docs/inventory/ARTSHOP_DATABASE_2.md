# Art Shop Inventory Database

Source: ARTSHOP_DATABASE_2_pdf.pdf. Currency: PHP (₱). Row order within each type follows source order.

## Schema

| Field | Meaning |
|---|---|
| ID | Item ID from source. `—` = source had no ID (placeholder text "Item ID") |
| Name | Item name, as written in source |
| Price | PHP per unit. `unknown` = source had placeholder `₱xx.xx` |
| Stock | Units in stock. `unknown` = source showed `##` |
| Status | One of: In Stock, Low Stock, Restock, Out of Stock |
| Notes | Raw value from Notes column. Empty = source had default placeholder "Notes" |
| Col1 | Raw value from unnamed "Column 1". Meaning unclear in source |

## Data caveats

- Only stickers #001–#024 have IDs. All other rows have no ID.
- Status not strictly tied to Stock count (e.g. 10 units = "Low Stock" for some, "In Stock" for #023). Values kept as in source.
- Notes and Col1 numeric values: meaning not defined in source. Kept raw.
- Stickers appear in two source groups (#001–#024 and later unnumbered group). Merged below, source order kept.

## Bundle deals

| Bundle | Rule | Bundle price | Eligible types |
|---|---|---|---|
| Stickers Bundle | any 4 | ₱100.00 | STICKER |
| Button Pins Bundle | any 3 | ₱100.00 | BUTTON PINS |
| Artisan Prints & Sheet Set | any 2 | ₱200.00 | ART PRINT, STICKER SHEETS (assumed from bundle name) |

## STICKER (₱30.00 each)

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| #001 | Bleeding heart | 30 | 21 | In Stock | RESTOCK | 6 |
| #002 | Tamaraw | 30 | 16 | In Stock |  | 16 |
| #003 | Tarsier | 30 | 10 | Low Stock |  | 10 |
| #004 | Goby | 30 | 12 | Low Stock | RESTOCK | 12 |
| #005 | Kalaw | 30 | 12 | Low Stock |  | 12 |
| #006 | Irrawady | 30 | 5 | Restock |  | 5 |
| #007 | Deer | 30 | 10 | Low Stock |  | 10 |
| #008 | Punch | 30 | 10 | Low Stock |  | 10 |
| #009 | Hollanov | 30 | 26 | In Stock |  | 26 |
| #010 | Hollander | 30 | 12 | Low Stock |  | 12 |
| #011 | Rozanov | 30 | 11 | Low Stock |  | 12 |
| #012 | Good Boy | 30 | 38 | In Stock |  | 10 |
| #013 | Good Girl | 30 | 52 | In Stock | 9(otherdesign) | 14 |
| #014 | Gay af | 30 | 20 | In Stock |  | 2 |
| #015 | Tobio | 30 | 21 | In Stock |  | 5 |
| #016 | Hinata | 30 | 21 | In Stock |  | 5 |
| #017 | Zigzagoon | 30 | 1 | Restock |  | 1 |
| #018 | PHM | 30 | 6 | Restock |  | 6 |
| #019 | Life is lifing | 30 | 20 | In Stock |  | 0 |
| #020 | Fame whore | 30 | 24 | In Stock |  | 4 |
| #021 | Jade | 30 | 20 | In Stock |  | 5 |
| #022 | Santan | 30 | 31 | In Stock |  | 7 |
| #023 | hello | 30 | 10 | In Stock |  | 10 |
| #024 | dont kys | 30 | 20 | In Stock |  | 0 |
| — | Disappoint your parents | 30 | 11 | Low Stock | 5 | 11 |
| — | One day at a time | 30 | 17 | In Stock |  | 2 |
| — | Know it's for the better | 30 | 13 | Low Stock | 10 | 13 |
| — | ICU paint tube | 30 | 10 | Low Stock |  | 10 |
| — | Drowning risk | 30 | 12 | Low Stock |  | 12 |
| — | Button girl | 30 | 7 | Restock |  | 7 |
| — | Nothing matters | 30 | 36 | In Stock | 4 | 8 |
| — | Tomorrow will be better | 30 | 15 | In Stock | 6 | 15 |
| — | Always an angel | 30 | 15 | In Stock |  | 15 |
| — | Girl | 30 | 42 | In Stock |  | 14 |
| — | Phone | 30 | 0 | Out of Stock |  | 0 |
| — | World | 30 | 12 | Low Stock |  | 12 |
| — | Lapida | 30 | 9 | Low Stock |  | 9 |
| — | Waiting | 30 | 32 | In Stock |  | 6 |
| — | Affirmations | 30 | 17 | In Stock |  | 17 |
| — | idk lol | 30 | 20 | In Stock |  | 2 |
| — | i forgor | 30 | 26 | In Stock |  | 2 |
| — | i don car | 30 | 37 | In Stock |  | 13 |
| — | eleveneleven | 30 | 6 | Restock |  | 6 |
| — | paper doll | 30 | 11 | Low Stock |  | 11 |
| — | we ball | 30 | 39 | In Stock |  | 11 |
| — | war | 30 | unknown | In Stock |  |  |
| — | honeybee | 30 | 12 | In Stock |  |  |

## STICKER SHEETS

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| — | Dinostarz | 120 | 4 | Low Stock |  |  |
| — | fishies | 80 | 1 | Restock |  |  |
| — | smiskis | 80 | 6 | Low Stock |  |  |
| — | starcraze | 120 | 6 | In Stock |  |  |
| — | skulz | 120 | 5 | In Stock |  |  |
| — | love | 70 | 8 | In Stock |  |  |

## ART PRINT

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| — | Trees (4x6") | 100 | 5 | In Stock |  |  |
| — | Trees (5x7") | 100 | 2 | Restock |  |  |
| — | Heated Rivalry (4x6") | 100 | 10 | In Stock |  |  |
| — | Maya (5x7") | 120 | 3 | Low Stock | 2 |  |
| — | Bleeding Fame (5x7") | 120 | 4 | Low Stock |  |  |
| — | Maral (5x7") | 120 | 6 | In Stock | 2 |  |
| — | Rafflesia (5x7") | 120 | 6 | In Stock |  |  |
| — | align (5x7") | 120 | 6 | In Stock |  |  |
| — | Space (5x7") | 120 | 6 | Low Stock |  |  |
| — | grace (5x7") | 120 | 6 | In Stock |  |  |
| — | Olruggio | 120 | 1 | Restock |  |  |
| — | ticket (4x6") | 100 | 6 | In Stock |  |  |
| — | bawal umihi d2 (4x6") | 100 | 1 | Restock |  |  |
| — | A.I. (4x6") | 100 | 6 | Low Stock |  |  |
| — | Beetle | 100 | 4 | Restock |  |  |
| — | Peacock | 100 | 3 | Restock |  |  |
| — | Forwards beckon rebound | 100 | 7 | Restock |  |  |
| — | Everything stays | 100 | 5 | Restock |  |  |
| — | Honeybee | 100 | 6 | Restock |  |  |

## BUTTON PINS (₱35.00 each)

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| — | bleh | 35 | 0 | Out of Stock |  |  |
| — | Bleed | 35 | 4 | Restock |  |  |
| — | bangus | 35 | 5 | Low Stock |  |  |
| — | i luv stars | 35 | 3 | Restock |  |  |
| — | gay af | 35 | 2 | Restock |  |  |
| — | doggo | 35 | 2 | Restock |  |  |
| — | nerdz | 35 | 1 | Restock |  |  |
| — | evil eye | 35 | 1 | Restock |  |  |
| — | star | 35 | 4 | Restock |  |  |
| — | phm | 35 | 3 | Restock |  |  |

## KEYCHAINS

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| — | Goby | 150 | 4 | Low Stock |  |  |
| — | Pigeon | 150 | 1 | Restock |  |  |
| — | Bread tag | 150 | 4 | Low Stock |  |  |
| — | Maral | 150 | 4 | Low Stock |  |  |
| — | Tamaraw | 150 | 5 | Low Stock |  |  |
| — | Phyton | 150 | 0 | Out of Stock |  |  |
| — | santan | 80 | 4 | Low Stock |  |  |
| — | jade | 80 | 3 | Low Stock |  |  |
| — | Webbing keychain | 120 | 21 | In Stock |  |  |

## TEMP TATTOOS (₱70.00 each)

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| — | pigeon | 70 | 3 | Low Stock |  |  |
| — | phyton | 70 | 3 | Low Stock |  |  |
| — | leopard | 70 | 3 | Low Stock |  |  |
| — | fish | 70 | 3 | Low Stock |  |  |
| — | tamaraw | 70 | 3 | Low Stock |  |  |

## CLAY DESKBUDDIES

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| — | Desk buddies (Pokemon) | unknown | unknown | Out of Stock |  |  |
| — | Desk buddies (Dinosaurs) | unknown | unknown | Out of Stock |  |  |

## CLAY PINS

| ID | Name | Price | Stock | Status | Notes | Col1 |
|---|---|---|---|---|---|---|
| — | Pins (big) | unknown | unknown | Out of Stock |  |  |
| — | Pins (small) | unknown | unknown | Out of Stock |  |  |
