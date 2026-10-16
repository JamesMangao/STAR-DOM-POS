// scripts/reset.js — retire the STAR:DOM WEBSITE objects.
//
// DEFAULT IS A DRY RUN. Nothing is dropped unless BOTH are given:
//     --execute  AND  --ref pykhzrpgdszcwvpydebt
// and, for --execute only, the process must run in a REAL TERMINAL (A7): the
// ref and the phrase CONFIRM RESET are typed by the human, exact match, no
// defaults. Piped stdio exits 1 before a single line of DB work.
//
// There is exactly ONE drop list: supabase/reset/reset.sql. This script reads
// that file and executes it verbatim; the plan it prints is PARSED from the
// same file, so the two can never disagree.
//
// Order of operations for --execute:
//   1. TTY check + typed ref + typed CONFIRM RESET (before any connection)
//   2. the DSN host must contain the project ref
//   3. reset.sql runs (its own transaction; its precheck refuses on POS data)
//   4. AFTER the commit, the retired storage bucket is removed through the
//      Storage API (Supabase blocks `delete from storage.objects`, and an
//      orphaned file would be worse than an orphaned row)
//   5. SELECT confirms the bucket and its objects are gone
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const manifest = require('./manifest');
const env = require('./env');
const pg = require('./pg');

const PROJECT_REF = 'pykhzrpgdszcwvpydebt';
const RESET_SQL_PATH = path.resolve(__dirname, '..', 'supabase', 'reset', 'reset.sql');

// A6: there is NO assets backup step. This is the only bucket this script will
// ever touch, and it is hard-coded to be exactly the retired website bucket.
const RETIRED_BUCKET = 'assets';

function argValue(argv, flag) {
  const i = argv.indexOf(flag);
  return i >= 0 ? argv[i + 1] : null;
}

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

/** Pull the plan out of reset.sql so JS never keeps a second copy of the lists. */
function parseResetPlan(sql) {
  const arrayFor = (name) => {
    const m = sql.match(
      new RegExp(`${name}\\s+text\\[\\]\\s*:=\\s*array\\[([\\s\\S]*?)\\]`, 'i'),
    );
    if (!m) return [];
    return (m[1].match(/'[^']+'/g) || []).map((s) => s.slice(1, -1));
  };
  const functions = [
    ...sql.matchAll(/drop function if exists public\.([a-z0-9_]+)\s*\(/gi),
  ].map((m) => m[1]);
  return {
    website: arrayFor('website'),
    posOnly: arrayFor('pos_only'),
    sequences: arrayFor('seqs'),
    functions,
  };
}

async function listAll(supabase, bucket, prefix = '', acc = []) {
  const page = 100;
  let offset = 0;
  for (;;) {
    const res = await supabase.storage.from(bucket).list(prefix, {
      limit: page,
      offset,
    });
    if (res.error) throw new Error(`list ${prefix || '/'}: ${res.error.message}`);
    const entries = res.data || [];
    for (const e of entries) {
      const full = prefix ? `${prefix}/${e.name}` : e.name;
      if (e.metadata == null && e.id == null) {
        await listAll(supabase, bucket, full, acc); // folder
      } else {
        acc.push({ path: full, size: Number(e.metadata?.size || 0) });
      }
    }
    if (entries.length < page) break;
    offset += page;
  }
  return acc;
}

function ttyConfirm(argv) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.error(
      '--execute requires a real terminal (stdin and stdout must be TTYs).\n' +
        'An agent or a pipe cannot confirm this. Run it yourself.',
    );
    process.exit(1);
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ask = (q) => new Promise((resolve) => rl.question(q, resolve));

  return (async () => {
    const typedRef = (await ask(`Type the project ref (${PROJECT_REF}) to continue: `)).trim();
    if (typedRef !== PROJECT_REF) {
      rl.close();
      console.error('Ref mismatch — nothing was done.');
      process.exit(1);
    }
    const typed = (await ask('Type CONFIRM RESET (exactly) to drop the website objects: ')).trim();
    rl.close();
    if (typed !== 'CONFIRM RESET') {
      console.error('Confirmation phrase mismatch — nothing was done.');
      process.exit(1);
    }
  })();
}

async function main() {
  const argv = process.argv.slice(2);
  const execute = argv.includes('--execute');
  const ref = argValue(argv, '--ref');

  const sql = fs.readFileSync(RESET_SQL_PATH, 'utf8');
  const plan = parseResetPlan(sql);

  console.log('=== reset.js — ' + (execute ? 'EXECUTE' : 'DRY RUN') + ' ===');
  console.log(`reset.sql: ${RESET_SQL_PATH}`);
  console.log(`reset.sql sha256: ${sha256(sql)}`);
  console.log(`reset.sql is the ONLY drop list (${plan.website.length} website tables, ` +
    `${plan.sequences.length} sequences, ${plan.functions.length} functions).\n`);

  // A7: the human gate comes before anything else — no connection yet.
  if (execute) {
    if (ref !== PROJECT_REF) {
      console.log(`Refusing to execute: pass --ref ${PROJECT_REF}.`);
      process.exit(1);
    }
    await ttyConfirm(argv);
  }

  // The export manifest is what proves the data was saved before the site is
  // dropped.
  const v = manifest.verify();
  console.log('export manifest preflight:', v.ok ? 'OK' : 'REFUSED');
  if (!v.ok) {
    for (const p of v.problems) console.log('  - ' + p);
    console.log('\nRefusing: the export does not match its manifest. Nothing changed.');
    process.exit(1);
  }
  console.log('  counts:', JSON.stringify(manifest.EXPECTED_COUNTS));

  const missing = env.REQUIRED_KEYS.filter((k) => !env.load()[k]);
  if (missing.length) {
    console.log('\nDB phase needs ' + env.ENV_PATH + '. Missing key NAMES:');
    for (const k of missing) console.log('  - ' + k);
    console.log('\nStopping before touching the database.');
    process.exit(2);
  }

  const { client, close } = execute ? await pg.writeClient() : await pg.readOnlyClient();
  try {
    // ---- website signature -------------------------------------------------
    const sig = await client.query(
      `select exists (
         select 1 from information_schema.columns
          where table_schema='public' and table_name='products'
            and column_name='baseprice') as website_signature`,
    );
    const isWebsite = sig.rows[0].website_signature;
    console.log(`website signature: ${isWebsite ? 'OK' : 'MISSING'}`);
    if (!isWebsite) {
      console.log('Refusing: public.products.baseprice not found. Nothing changed.');
      process.exit(1);
    }

    // ---- what is actually present -----------------------------------------
    const tables = await client.query(
      `select table_name from information_schema.tables
        where table_schema='public' and table_type='BASE TABLE' order by table_name`,
    );
    const present = tables.rows.map((r) => r.table_name);
    const website = present.filter((t) => plan.website.includes(t));
    const posPresent = present.filter((t) => plan.posOnly.includes(t));
    const unknown = present.filter(
      (t) => !plan.website.includes(t) && !plan.posOnly.includes(t),
    );
    if (posPresent.length) {
      console.log('REFUSED: POS tables present:', posPresent.join(', '));
      process.exit(1);
    }
    if (unknown.length) {
      console.log('REFUSED: unexpected public objects:', unknown.join(', '));
      process.exit(1);
    }

    console.log(`\nwebsite tables present: ${website.length} of ${plan.website.length}`);
    console.log('row counts:');
    let totalRows = 0;
    for (const t of website) {
      const r = await client.query(`select count(*)::int n from "${t}"`);
      totalRows += r.rows[0].n;
      console.log(`  ${t.padEnd(28)} ${r.rows[0].n}`);
    }
    console.log(`  TOTAL ${totalRows} rows exported and about to be dropped`);

    // ---- storage (the bucket is removed through the API, after commit) -----
    if (RETIRED_BUCKET !== 'assets') {
      console.log('REFUSED: only the assets bucket may ever be removed.');
      process.exit(1);
    }
    const buckets = await client.query(
      `select id, name, public from storage.buckets order by id`,
    );
    console.log('\nstorage buckets present:', buckets.rows.map((b) => b.id).join(', ') || '(none)');
    const retired = buckets.rows.find((b) => b.id === RETIRED_BUCKET);
    let objects = 0;
    let bytes = 0;
    if (retired) {
      const agg = await client.query(
        `select count(*)::int objects,
                coalesce(sum((metadata->>'size')::bigint), 0)::bigint bytes
           from storage.objects where bucket_id = $1`,
        [RETIRED_BUCKET],
      );
      objects = agg.rows[0].objects;
      bytes = Number(agg.rows[0].bytes);
      console.log(`will delete ${objects} objects, ${bytes} bytes from bucket '${RETIRED_BUCKET}'`);
    } else {
      console.log(`bucket '${RETIRED_BUCKET}' is already gone`);
    }

    // ---- cron jobs that reference a dropped object -------------------------
    try {
      const cron = await client.query(
        `select jobid, jobname, schedule,
                (regexp_replace(command, 'auth\\.[a-z_]+', '', 'gi')
                   ~* '\\m(${plan.website.join('|')}|${plan.functions.join('|')})\\M')
                  as references_dropped_object
           from cron.job order by jobid`,
      );
      console.log('\ncron jobs (command text never printed):');
      for (const j of cron.rows) {
        console.log(
          `  ${String(j.jobid).padEnd(4)} ${String(j.jobname).padEnd(24)} ${j.schedule}` +
            `  references dropped object: ${j.references_dropped_object ? 'YES (will unschedule)' : 'no'}`,
        );
      }
    } catch (e) {
      console.log(`\ncron: not available (${e.code || e.message}) — nothing to unschedule`);
    }

    if (!execute) {
      console.log('\nDRY RUN complete — nothing changed.');
      return;
    }

    // ---- execute -----------------------------------------------------------
    const host = pg.assertProjectRef(PROJECT_REF);
    console.log(`\nproject ref present in host: OK (${host})`);

    // 1. the SQL (its own transaction; single source of truth)
    await client.query(sql);
    console.log('reset.sql committed: website tables + named objects dropped.');

    // 2. storage, via the Storage API, AFTER the commit
    console.log('\nstorage: removing bucket through the Storage API …');
    const { createClient } = require('@supabase/supabase-js');
    const e = env.load();
    const supabase = createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const all = await listAll(supabase, RETIRED_BUCKET);
    console.log(
      `  listed ${all.length} objects (${all.reduce((a, o) => a + o.size, 0)} bytes)`,
    );
    for (let i = 0; i < all.length; i += 100) {
      const batch = all.slice(i, i + 100).map((o) => o.path);
      const res = await supabase.storage.from(RETIRED_BUCKET).remove(batch);
      if (res.error) throw new Error(`remove batch ${i}: ${res.error.message}`);
      console.log(`  removed ${batch.length} objects (${i + batch.length}/${all.length})`);
    }
    const del = await supabase.storage.deleteBucket(RETIRED_BUCKET);
    if (del.error) throw new Error(`deleteBucket: ${del.error.message}`);
    console.log(`  bucket '${RETIRED_BUCKET}' deleted`);

    // 3. confirm
    const after = await client.query(
      `select (select count(*)::int from storage.buckets where id = $1) as buckets,
              (select count(*)::int from storage.objects where bucket_id = $1) as objects`,
      [RETIRED_BUCKET],
    );
    console.log(
      `\nconfirmed: buckets='${RETIRED_BUCKET}' -> ${after.rows[0].buckets}, ` +
        `objects -> ${after.rows[0].objects}`,
    );
    if (after.rows[0].buckets !== 0 || after.rows[0].objects !== 0) {
      throw new Error('storage cleanup did not complete');
    }
    console.log('done. public schema and its grants untouched.');
  } finally {
    await close();
  }
}

main().catch((e) => {
  console.error('reset failed:', e.message);
  process.exit(1);
});
