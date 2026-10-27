// scripts/reseed.js — reset the POS database to a fresh-booth state.
//
//   node scripts/reseed.js                                  DRY RUN (read-only)
//   node scripts/reseed.js --execute --ref pykhzrpgdszcwvpydebt
//       ^ a REAL terminal only: the ref and CONFIRM RESEED are TYPED by the
//         human, exact match. Piped stdio exits 1 before any connection.
//
// RESETS (operational history): orders (+ order_items, payments, order_voids),
//   stock_events, day_closes, devices, sync_outbox, product stock.
// KEEPS (the owner's catalogue): stores, categories, product rows (names,
//   prices, images, links, soft deletes), payment_methods, settings (receipt
//   data, bundle_rules, ...), and is_active flags — except the photo-less
//   mirror inside reseed.sql (see why there).
//
// STOCKS go back to the catalogue's opening counts (assets/catalogue/
// catalogue.json); a product the catalogue does not know goes to 0. The join
// tries product id FIRST, then normalized NAME: the server's ids come from a
// different scheme than the catalogue's, and 006 makes the normalized name
// unique per store, so name is the join that actually holds. The opening
// stock event is rewritten with the SAME stable id the seed and the import
// use (uuid v5 of "stock_import:{product_id}"), so the column and the event
// sum agree and no later seed double-counts.
//
// ORDER OF OPERATIONS — THE BOOTH COMES AFTER THIS SCRIPT:
//   1. Booth signed in, Sync GREEN (0 pending): queued sales would otherwise
//      re-push right after the reset.
//   2. This script --execute.
//   3. EVERY booth clears its site data, reopens, signs in. Clearing is what
//      retires the old device code; a booth that keeps its data holds a code
//      the server no longer has, and the server could hand the SAME 2-char
//      code to another device — permanently colliding order numbers (B7).
//   4. Green Sync again before the first sale.
//
// supabase/reseed/reseed.sql is the ONLY reset list: parsed for the plan and
// executed verbatim, so the printed plan and the executed SQL cannot disagree.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const env = require('./env');
const pg = require('./pg');
const { stockImportId } = require('./import-lib');

const PROJECT_REF = 'pykhzrpgdszcwvpydebt';
const RESQL_PATH = path.resolve(
  __dirname,
  '..',
  'supabase',
  'reseed',
  'reseed.sql',
);
const CATALOGUE_PATH = path.resolve(
  __dirname,
  '..',
  'assets',
  'catalogue',
  'catalogue.json',
);

/** Tables reseed.sql empties — the single source for the printed plan. */
function parseResetList(sql) {
  return [...sql.matchAll(/delete\s+from\s+([a-z_]+)/gi)].map((m) => m[1]);
}

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

function argValue(argv, flag) {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : null;
}

/** One name-normalisation rule — mirrors NameNorm in lib/data/norm.dart. */
function normalizeName(name) {
  return String(name).trim().replace(/\s+/g, ' ').toLowerCase();
}

/**
 * Last-resort join key: the same as [normalizeName] but with NO spaces at all.
 * The catalogue writes `Trees (4x6")` and the database holds `Trees(4x6")` —
 * a space the sheet lost somewhere. Used only after id and normalized name
 * both missed, so it can only RESCUE a match, never steal one (006 already
 * guarantees the normalized name itself is unique per store).
 */
function looseName(name) {
  return normalizeName(name).replace(/\s+/g, '');
}

/** The catalogue's opening stock, validated. Fails loudly, never silently. */
function loadCatalogue(filePath) {
  const cat = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  if (!Array.isArray(cat.products) || cat.products.length === 0) {
    throw new Error('catalogue.json has no products');
  }
  const byId = new Map();
  const byName = new Map();
  const byLoose = new Map();
  for (const p of cat.products) {
    const stock = Number(p.stock);
    if (!Number.isInteger(stock) || stock < 0) {
      throw new Error(
        `catalogue product ${JSON.stringify(p.name)} has invalid stock ${p.stock}`,
      );
    }
    if (typeof p.id === 'string') byId.set(p.id, stock);
    if (typeof p.name === 'string') {
      byName.set(normalizeName(p.name), stock);
      byLoose.set(looseName(p.name), stock);
    }
  }
  return { raw: cat, byId, byName, byLoose };
}

/**
 * The target stock for every live product row.
 *
 * matched=true  -> the catalogue owns this row (id or normalized-name hit).
 * matched=false -> unknown to the catalogue: reset to 0, listed for review.
 */
function stockTargets(catalogue, rows) {
  const out = [];
  for (const r of rows) {
    const byId = catalogue.byId.get(r.id);
    const byName = byId === undefined
      ? catalogue.byName.get(normalizeName(r.name))
      : undefined;
    const byLoose = byId === undefined && byName === undefined
      ? catalogue.byLoose.get(looseName(r.name))
      : undefined;
    const target = byId ?? byName ?? byLoose ?? 0;
    out.push({
      id: r.id,
      storeId: r.store_id,
      name: r.name,
      current: Number(r.stock_quantity ?? 0),
      target,
      matched:
        byId !== undefined || byName !== undefined || byLoose !== undefined,
      changed: Number(r.stock_quantity ?? 0) !== target,
    });
  }
  return out;
}

function ttyConfirm(argv) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.error(
      '--execute requires a real terminal (stdin and stdout must be TTYs).\n' +
        'An agent or a pipe cannot confirm this. Run it yourself.',
    );
    process.exit(1);
  }
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  const ask = (q) => new Promise((resolve) => rl.question(q, resolve));

  return (async () => {
    const typedRef = (
      await ask(`Type the project ref (${PROJECT_REF}) to continue: `)
    ).trim();
    if (typedRef !== PROJECT_REF) {
      rl.close();
      console.error('Ref mismatch — nothing was done.');
      process.exit(1);
    }
    const typed = await ask(
      'Type CONFIRM RESEED (exactly) to reset orders, devices and stocks: ',
    );
    rl.close();
    if (typed.trim() !== 'CONFIRM RESEED') {
      console.error('Confirmation phrase mismatch — nothing was done.');
      process.exit(1);
    }
  })();
}

const RUNBOOK = `
BOOTH SIDE — after this script, in this exact order:
  1. On EVERY booth: clear the site data for stardom-pos.pages.dev
     (cookies + storage), reopen the app and sign in.
       - Expected: the booth registers as a NEW device (code A0 again) —
         this reset just emptied the devices table, so that is correct.
       - A booth that SKIPS this keeps a device code the server no longer
         knows, and the server may hand the SAME code to another device:
         order numbers would collide. Do not skip it.
  2. Wait for the green Sync before the first sale.
  The promo bundle rules and payment methods live in settings — they survive
  this reset untouched.`;

async function main() {
  const argv = process.argv.slice(2);
  const execute = argv.includes('--execute');
  const ref = argValue(argv, '--ref');

  const sql = fs.readFileSync(RESQL_PATH, 'utf8');
  const resetList = parseResetList(sql);
  const catalogue = loadCatalogue(CATALOGUE_PATH);

  console.log(`=== reseed.js — ${execute ? 'EXECUTE' : 'DRY RUN'} ===`);
  console.log(`reseed.sql:      ${RESQL_PATH}`);
  console.log(`reseed.sql sha256: ${sha256(sql)}`);
  console.log(`catalogue sha256:  ${sha256(fs.readFileSync(CATALOGUE_PATH))}`);
  console.log(
    `reseed.sql is the ONLY reset list (${resetList.length} tables): ${resetList.join(', ')}`,
  );
  console.log(
    `catalogue opening stock: ${catalogue.raw.products.length} products, ` +
      `${[...catalogue.byId.values()].filter((s) => s > 0).length} with stock > 0`,
  );
  console.log(
    `\nTo run it: node scripts/reseed.js --execute --ref ${PROJECT_REF}\n` +
      '  (real terminal; you type the ref and CONFIRM RESEED)',
  );

  // The human gate comes before anything else — no connection yet.
  if (execute) {
    if (ref !== PROJECT_REF) {
      console.log(`Refusing to execute: pass --ref ${PROJECT_REF}.`);
      process.exit(1);
    }
    await ttyConfirm(argv);
  }

  const missing = env.REQUIRED_KEYS.filter((k) => !env.load()[k]);
  if (missing.length) {
    console.log(`\nDB phase needs ${env.ENV_PATH}. Missing key NAMES:`);
    for (const k of missing) console.log(`  - ${k}`);
    console.log('\nStopping before touching the database.');
    process.exit(2);
  }

  const { client, close } = execute
    ? await pg.writeClient()
    : await pg.readOnlyClient();
  try {
    // ---- schema guards: website refuses, POS must be migrated -------------
    const sig = await client.query(
      `select exists (
         select 1 from information_schema.columns
          where table_schema='public' and table_name='products'
            and column_name='baseprice') as website,
       exists (
         select 1 from information_schema.columns
          where table_schema='public' and table_name='products'
            and column_name='stock_quantity') as pos`,
    );
    if (sig.rows[0].website) {
      console.error(
        'Refusing: the WEBSITE schema is still present (products.baseprice). ' +
          'Run scripts/reset.js first. Nothing changed.',
      );
      process.exit(1);
    }
    if (!sig.rows[0].pos) {
      console.error(
        'Refusing: the POS schema is missing (products.stock_quantity). ' +
          'Run the supabase migrations first. Nothing changed.',
      );
      process.exit(1);
    }

    // ---- stores: exactly one ----------------------------------------------
    const stores = await client.query(
      `select id, name from stores order by id`,
    );
    const storeCount = stores.rows.length;
    console.log(`\nstores: ${storeCount}`);
    for (const s of stores.rows) console.log(`  ${s.id}  ${s.name}`);
    if (storeCount !== 1) {
      const why = storeCount === 0 ? 'no store to keep' : 'multi-store not supported';
      if (execute) {
        console.error(`Refusing to execute: ${why}. Nothing changed.`);
        process.exit(1);
      }
      console.log(`  WARNING (dry run): execute would refuse — ${why}`);
    }

    // ---- what the reset would remove ---------------------------------------
    const counts = await client.query(
      resetList
        .map((t) => `select '${t}' k, count(*)::int n from "${t}"`)
        .join(' union all '),
    );
    console.log('\nreset plan — rows removed:');
    let total = 0;
    for (const row of counts.rows) {
      total += row.n;
      console.log(`  ${row.k.padEnd(24)} ${row.n}`);
    }
    console.log(`  ${'TOTAL'.padEnd(24)} ${total}`);

    // ---- what the stock reset would change ---------------------------------
    const products = await client.query(
      `select id, store_id, name, stock_quantity from products
        where deleted_at is null order by name, id`,
    );
    const plan = stockTargets(catalogue, products.rows);
    const toCatalogue = plan.filter((p) => p.changed && p.matched);
    const toZero = plan.filter((p) => p.changed && !p.matched);
    const atCatalogue = plan.filter((p) => !p.changed && p.matched).length;
    const catalogueMissing = catalogue.raw.products.filter(
      (c) =>
        !plan.some(
          (p) =>
            p.id === c.id ||
            normalizeName(p.name) === normalizeName(c.name) ||
            looseName(p.name) === looseName(c.name),
        ),
    );
    console.log(`\nstock reset — live products: ${plan.length}`);
    console.log(
      `  -> catalogue opening stock: ${toCatalogue.length} changed, ` +
        `${atCatalogue} already there`,
    );
    console.log(`  -> 0 (not in the catalogue): ${toZero.length}`);
    if (toZero.length) {
      console.log('     products going to 0 (review before you confirm):');
      for (const p of toZero.slice(0, 40)) console.log(`       ${p.name} (${p.current} -> 0)`);
      if (toZero.length > 40) console.log(`       ... and ${toZero.length - 40} more`);
    }
    if (catalogueMissing.length) {
      console.log(
        `  note: ${catalogueMissing.length} catalogue product(s) not found in the DB ` +
          '(they get no row and no event)',
      );
    }
    const photoless = await client.query(
      `select count(*)::int n from products
        where deleted_at is null and is_active
          and coalesce(btrim(image_path), '') = ''`,
    );
    console.log(
      `photo-less mirror: ${photoless.rows[0].n} active product(s) without art ` +
        '-> INACTIVE (same rule the app applies at launch)',
    );

    console.log(
      '\nKEPT: stores, categories, product rows (names, prices, images, ' +
        'is_active), payment_methods, settings (receipt data, bundle_rules).',
    );
    console.log(RUNBOOK);

    if (!execute) {
      console.log('\nDRY RUN complete — nothing changed.');
      return;
    }

    // ---- execute: one transaction, all-or-nothing --------------------------
    const storeId = storeCount === 1 ? stores.rows[0].id : null;
    const changed = plan.filter((p) => p.changed);
    const events = plan.filter((p) => p.matched && p.target > 0);

    await client.query('BEGIN');
    try {
      await client.query(sql);
      for (const p of changed) {
        await client.query(
          'update products set stock_quantity = $1, updated_at = now() where id = $2',
          [p.target, p.id],
        );
      }
      for (const p of events) {
        await client.query(
          `insert into stock_events
             (id, store_id, product_id, delta, reason, order_id, device_id)
           values ($1, $2, $3, $4, 'import', null, null)
           on conflict (id) do nothing`,
          [stockImportId(p.id), storeId, p.id, p.target],
        );
      }
      await client.query('COMMIT');
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    }
    console.log(
      `reseed committed: ${resetList.length} table(s) emptied, ` +
        `${changed.length} stock value(s) set, ${events.length} opening event(s) written.`,
    );

    // ---- confirm ------------------------------------------------------------
    const after = await client.query(
      resetList
        .map((t) => `select '${t}' k, count(*)::int n from "${t}"`)
        .join(' union all '),
    );
    console.log('\nconfirmed row counts after the reseed:');
    for (const row of after.rows) console.log(`  ${row.k.padEnd(24)} ${row.n}`);
    console.log('\nreseed done. NOW follow the BOOTH SIDE steps above.');
  } finally {
    await close();
  }
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`reseed failed: ${e.message}`);
    process.exit(1);
  });
}

module.exports = {
  PROJECT_REF,
  parseResetList,
  normalizeName,
  looseName,
  loadCatalogue,
  stockTargets,
  sha256,
};
