// scripts/storage-audit.js — READ-ONLY storage facts before any reset.
//
//   node scripts/storage-audit.js
//
// Answers, without downloading or changing anything:
//   * the buckets and, per bucket, count / total bytes / objects per top folder
//     / first+last created_at;
//   * whether any exported products/productimages row references a bucket object;
//   * which objects are NOT recoverable from the website source tree or the
//     export (reported as folder names + counts only);
//   * the exact storage statements reset.sql / reset.js would run.
//
// Uses the read-only connection from scripts/pg.js (default_transaction_read_only
// = on + BEGIN READ ONLY). No storage download, no write.
'use strict';

const fs = require('fs');
const path = require('path');
const { readOnlyClient } = require('./pg');
const manifest = require('./manifest');

// Website source trees that may still hold the original asset files.
const DISK_ROOTS = ['D:\\STARDOM\\STAR-DOM-Web'];
const SKIP_DIRS = new Set(['.git', 'node_modules', '.vs', '_preview']);

function walkFiles(root, acc = [], depth = 0) {
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of entries) {
    const p = path.join(root, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name) || depth > 8) continue;
      walkFiles(p, acc, depth + 1);
    } else if (e.isFile()) {
      acc.push(p);
    }
  }
  return acc;
}

function topFolder(name) {
  const i = name.indexOf('/');
  return i < 0 ? '(root)' : name.slice(0, i);
}

async function main() {
  // ---- 1. export references -------------------------------------------------
  const exported = new Set();
  const exportedRefs = [];
  for (const f of ['products', 'productimages', 'paymentsettings']) {
    const p = path.join(manifest.EXPORT_DIR, `${f}.json`);
    if (!fs.existsSync(p)) continue;
    for (const row of JSON.parse(fs.readFileSync(p, 'utf8'))) {
      for (const key of ['imagefile', 'qrimagefile', 'image_path']) {
        if (typeof row[key] === 'string' && row[key]) {
          exported.add(row[key]);
          exported.add(path.basename(row[key]));
          exportedRefs.push({ file: f, key, value: row[key] });
        }
      }
    }
  }

  // ---- 2. DB: buckets + per-bucket aggregates (read-only) -------------------
  const { client, close } = await readOnlyClient();
  try {
    const buckets = await client.query(
      `select id, name, public from storage.buckets order by id`,
    );
    console.log('===== storage.buckets =====');
    console.log(JSON.stringify(buckets.rows, null, 2));

    for (const b of buckets.rows) {
      const agg = await client.query(
        `select count(*)::int objects,
                coalesce(sum((metadata->>'size')::bigint), 0)::bigint bytes,
                min(created_at) as first_created,
                max(created_at) as last_created
           from storage.objects where bucket_id = $1`,
        [b.id],
      );
      console.log(`\n===== bucket ${b.id}: aggregates =====`);
      console.log(JSON.stringify(agg.rows, null, 2));

      const folders = await client.query(
        `select split_part(name, '/', 1) as folder, count(*)::int objects,
                coalesce(sum((metadata->>'size')::bigint), 0)::bigint bytes
           from storage.objects where bucket_id = $1
          group by 1 order by 1`,
        [b.id],
      );
      console.log(`===== bucket ${b.id}: per top-level folder =====`);
      console.log(JSON.stringify(folders.rows, null, 2));
    }

    const objects = await client.query(
      `select bucket_id, name, (metadata->>'size')::bigint as size, created_at
         from storage.objects order by bucket_id, name`,
    );
    const rows = objects.rows;

    // ---- 3. do exported rows reference bucket objects? ---------------------
    let referenced = 0;
    for (const o of rows) {
      if (exported.has(o.name) || exported.has(path.basename(o.name))) referenced++;
    }
    console.log('\n===== export -> bucket references =====');
    console.log(`exported path strings collected: ${exported.size} unique (${exportedRefs.length} references)`);
    console.log(`bucket objects referenced by the export: ${referenced} of ${rows.length}`);
    console.log(`answer: ${referenced > 0 ? 'Y' : 'N'} (${referenced})`);

    // ---- 4. recoverability -------------------------------------------------
    const disk = [];
    for (const root of DISK_ROOTS) disk.push(...walkFiles(root));
    const byBase = new Map();
    for (const f of disk) {
      const b = path.basename(f);
      if (!byBase.has(b)) byBase.set(b, []);
      byBase.get(b).push(f);
    }
    console.log('\n===== disk index =====');
    console.log(`roots: ${DISK_ROOTS.join(', ')}`);
    console.log(`files indexed: ${disk.length}`);

    const missing = [];
    for (const o of rows) {
      const base = path.basename(o.name);
      const onDisk = byBase.has(base);
      const inExport = exported.has(o.name) || exported.has(base);
      if (!onDisk && !inExport) missing.push(o);
    }
    console.log('\n===== NOT recoverable (not on disk, not in the export) =====');
    console.log(`count: ${missing.length} of ${rows.length}`);
    const byFolder = new Map();
    for (const o of missing) {
      const k = topFolder(o.name);
      byFolder.set(k, (byFolder.get(k) || 0) + 1);
    }
    if (byFolder.size === 0) console.log('(none)');
    for (const [folder, n] of [...byFolder.entries()].sort()) {
      console.log(`  ${folder.padEnd(24)} ${n}`);
    }

    console.log('\n===== objects present on disk by basename (spot check) =====');
    let onDiskCount = 0;
    for (const o of rows) if (byBase.has(path.basename(o.name))) onDiskCount++;
    console.log(`objects whose basename exists in the website tree: ${onDiskCount} of ${rows.length}`);
  } finally {
    await close();
  }

  // ---- 5. the statements a reset would run --------------------------------
  const resetSql = fs.readFileSync(
    path.resolve(__dirname, '..', 'supabase', 'reset', 'reset.sql'),
    'utf8',
  );
  console.log('\n===== reset.sql storage statements =====');
  const lines = resetSql.split(/\r?\n/);
  lines.forEach((l, i) => {
    if (/storage\.(objects|buckets)/.test(l)) {
      console.log(`  reset.sql:${i + 1}: ${l.trim()}`);
    }
  });
  const resetJs = fs.readFileSync(path.resolve(__dirname, 'reset.js'), 'utf8');
  console.log('===== reset.js storage statements =====');
  resetJs.split(/\r?\n/).forEach((l, i) => {
    if (/storage\.(objects|buckets)|RETIRED_BUCKETS/.test(l)) {
      console.log(`  reset.js:${i + 1}: ${l.trim()}`);
    }
  });
}

main().catch((e) => {
  console.error('storage audit failed:', e.message);
  process.exit(1);
});
