// scripts/compare-export.js — compare a freshly generated export with the
// existing one BEFORE anything is replaced.
//
//   node scripts/compare-export.js <oldDir> <newDir>
//
// Two different criteria, because the two kinds of file mean different things:
//
//   JSON  — SEMANTIC equality. Parse both sides, compare key-order independently,
//           and compare numbers by DECIMAL VALUE, so the old file's `30.0` and a
//           new `"30.00"` (money cast to ::text) both read as 30.00. Byte
//           differences (CRLF vs LF, 30.0 vs 30) are reported as INFO, not
//           failures — semantic equality is the correct criterion for data.
//
//   PNG   — BYTE equality. The QR images must be byte-identical (sha256); any
//           difference is a hard STOP.
//
// Exit 1 if any JSON is not deep-equal, or any QR sha256 differs. Never writes.
'use strict';

const fs = require('fs');
const path = require('path');
const manifest = require('./manifest');

/** Canonical decimal key: "30.0" -> "30", "-0.50" -> "-0.5", "0012" -> "12". */
function decKey(v) {
  const m = /^([+-]?)(\d+)(?:\.(\d+))?$/.exec(String(v).trim());
  if (!m) return null;
  const sign = m[1] === '-' ? '-' : '';
  const int = m[2].replace(/^0+(?=\d)/, '');
  const frac = (m[3] || '').replace(/0+$/, '');
  const key = frac ? `${int}.${frac}` : int;
  return sign && key !== '0' ? '-' + key : key;
}

/**
 * Semantic equality:
 *  - number vs numeric string -> equal when the decimal values are equal
 *    (this is the money case: old JSON number 30.0 == new text "30.00");
 *  - string vs string         -> exact (a SKU "0012" is NOT "12");
 *  - objects                  -> key order irrelevant, same key set required.
 */
function eq(a, b) {
  if (a === b) return true;
  const aNum = typeof a === 'number';
  const bNum = typeof b === 'number';
  const aStr = typeof a === 'string';
  const bStr = typeof b === 'string';
  if ((aNum && bStr) || (aStr && bNum)) {
    const k = decKey(a);
    const j = decKey(b);
    return k !== null && k === j;
  }
  if (aNum && bNum) return decKey(a) === decKey(b);
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((x, i) => eq(x, b[i]));
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    return ka.every((k) => Object.prototype.hasOwnProperty.call(b, k) && eq(a[k], b[k]));
  }
  return false;
}

function rowsDeepEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (!eq(a[i], b[i])) return false;
  }
  return true;
}

function main() {
  const [oldDir, newDir] = process.argv.slice(2);
  if (!oldDir || !newDir) {
    console.error('usage: node scripts/compare-export.js <oldDir> <newDir>');
    process.exit(2);
  }
  const problems = [];
  console.log(`old: ${path.resolve(oldDir)}`);
  console.log(`new: ${path.resolve(newDir)}\n`);

  console.log('name                  rows  DEEP-EQUAL  bytes(old/new)  sha256');
  for (const name of manifest.JSON_FILES) {
    const a = path.join(oldDir, `${name}.json`);
    const b = path.join(newDir, `${name}.json`);
    if (!fs.existsSync(a) || !fs.existsSync(b)) {
      problems.push(`missing file: ${!fs.existsSync(a) ? a : b}`);
      continue;
    }
    const rowsA = JSON.parse(fs.readFileSync(a, 'utf8'));
    const rowsB = JSON.parse(fs.readFileSync(b, 'utf8'));
    const deep = rowsDeepEqual(rowsA, rowsB);
    if (!deep) problems.push(`${name}.json: NOT deep-equal`);
    const sa = fs.statSync(a).size;
    const sb = fs.statSync(b).size;
    const ha = manifest.sha256(a);
    const hb = manifest.sha256(b);
    console.log(
      `${`${name}.json`.padEnd(21)} ${String(rowsB.length).padStart(4)}  ${(deep ? 'y' : 'n').padEnd(10)}  ` +
        `${sa}/${sb}  old=${ha.slice(0, 12)}… new=${hb.slice(0, 12)}…${ha === hb ? ' (bytes identical)' : ' (bytes differ)'}`,
    );
    // Report what a money field actually arrived as.
    if (name === 'products' && rowsB.length) {
      console.log(`  baseprice in new file: ${typeof rowsB[0].baseprice} ${JSON.stringify(rowsB[0].baseprice)} (old: ${typeof rowsA[0].baseprice} ${JSON.stringify(rowsA[0].baseprice)})`);
    }
  }

  console.log('\nQR images (byte equality required):');
  for (const name of manifest.QR_FILES) {
    const a = path.join(oldDir, name);
    const b = path.join(newDir, name);
    if (!fs.existsSync(a) || !fs.existsSync(b)) {
      problems.push(`missing QR: ${!fs.existsSync(a) ? a : b}`);
      continue;
    }
    const ha = manifest.sha256(a);
    const hb = manifest.sha256(b);
    const ok = ha === hb;
    if (!ok) problems.push(`${name}: sha256 differs`);
    console.log(
      `  ${name.padEnd(15)} ${ok ? 'IDENTICAL' : 'DIFFERS'}  ${fs.statSync(b).size} bytes  sha256=${hb}`,
    );
  }

  console.log('\nrow counts (new):');
  for (const [k, want] of Object.entries(manifest.EXPECTED_COUNTS)) {
    const n = JSON.parse(fs.readFileSync(path.join(newDir, `${k}.json`), 'utf8')).length;
    const ok = n === want;
    if (!ok) problems.push(`new ${k} row count ${n} != expected ${want}`);
    console.log(`  ${k.padEnd(16)} ${n} (expected ${want}) ${ok ? 'OK' : 'MISMATCH'}`);
  }

  const mv = manifest.verify(newDir);
  console.log('\nnew manifest verify:', mv.ok ? 'OK' : 'REFUSED');
  if (!mv.ok) for (const p of mv.problems) problems.push(`new manifest: ${p}`);

  if (problems.length) {
    console.log('\nNOT EQUAL — DO NOT SWAP:');
    for (const p of problems) console.log('  - ' + p);
    process.exit(1);
  }
  console.log('\nDEEP-EQUAL on every JSON file and byte-identical QRs — safe to swap.');
}

main();
