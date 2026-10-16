'use strict';

// scripts/font-check.js — prove the ₱ (U+20B1) actually exists in the fonts we
// bundle, instead of assuming it.
//
// Every peso figure in the app and on the receipt is rendered with U+20B1. A
// font without that glyph draws a blank box (or nothing) and the receipt is
// wrong, so this parses the TrueType `cmap` table straight out of the file: no
// font library, no network, nothing to install.
//
// Supported subtable formats: 0 (byte), 4 (BMP segments), 6 (trimmed), 12
// (segmented coverage, used by modern fonts for astral planes). Format 4 alone
// is enough for U+20B1, but a font that switched to format 12 must still be
// read correctly — a "not found" from an unparsed subtable would be a false
// alarm in the other direction.

const fs = require('fs');

const PESO = 0x20b1;

function readSubtable(buf, offset, format) {
  if (format === 0) {
    // 256-byte glyph id map.
    const table = new Map();
    for (let i = 0; i < 256; i++) table.set(i, buf.readUInt8(offset + 6 + i));
    return table;
  }

  if (format === 4) {
    const segCountX2 = buf.readUInt16BE(offset + 6);
    const segCount = segCountX2 / 2;
    const endBase = offset + 14;
    const startBase = endBase + segCountX2 + 2;
    const deltaBase = startBase + segCountX2;
    const rangeBase = deltaBase + segCountX2;
    const table = new Map();
    for (let s = 0; s < segCount; s++) {
      const end = buf.readUInt16BE(endBase + s * 2);
      const start = buf.readUInt16BE(startBase + s * 2);
      const delta = buf.readInt16BE(deltaBase + s * 2);
      const rangeOffset = buf.readUInt16BE(rangeBase + s * 2);
      if (end === 0xffff && start === 0xffff) continue;
      for (let c = start; c <= end && c !== 0x10000; c++) {
        let gid;
        if (rangeOffset === 0) {
          gid = (c + delta) & 0xffff;
        } else {
          const addr = rangeBase + s * 2 + rangeOffset + (c - start) * 2;
          if (addr + 2 > buf.length) continue;
          gid = buf.readUInt16BE(addr);
          if (gid !== 0) gid = (gid + delta) & 0xffff;
        }
        if (gid !== 0) table.set(c, gid);
        if (table.size > 70000) return table; // guard against a corrupt table
      }
    }
    return table;
  }

  if (format === 6) {
    const first = buf.readUInt16BE(offset + 6);
    const count = buf.readUInt16BE(offset + 8);
    const table = new Map();
    for (let i = 0; i < count; i++) {
      const gid = buf.readUInt16BE(offset + 10 + i * 2);
      if (gid !== 0) table.set(first + i, gid);
    }
    return table;
  }

  if (format === 12) {
    const nGroups = buf.readUInt32BE(offset + 12);
    const table = new Map();
    for (let g = 0; g < nGroups; g++) {
      const base = offset + 16 + g * 12;
      const start = buf.readUInt32BE(base);
      const end = buf.readUInt32BE(base + 4);
      const startGid = buf.readUInt32BE(base + 8);
      // Only the peso's neighbourhood is expanded: the full range can be
      // 100k+ code points and we only ever ask about one of them.
      if (start <= PESO && PESO <= end) {
        table.set(PESO, startGid + (PESO - start));
      }
    }
    return table;
  }

  return new Map(); // unknown format: no claims either way
}

/**
 * Parse a TTF/OTF and return every code point it maps to a non-zero glyph.
 * @returns {Map<number, number>} code point -> glyph id
 */
function cmapTable(file) {
  const buf = fs.readFileSync(file);
  if (buf.length < 12) throw new Error(`${file}: too short to be a font`);

  const numTables = buf.readUInt16BE(4);
  let cmapOffset = 0;
  for (let i = 0; i < numTables; i++) {
    const rec = 12 + i * 16;
    const tag = buf.toString('ascii', rec, rec + 4);
    if (tag === 'cmap') {
      cmapOffset = buf.readUInt32BE(rec + 8);
      break;
    }
  }
  if (!cmapOffset) throw new Error(`${file}: no cmap table`);

  const numSubtables = buf.readUInt16BE(cmapOffset + 2);
  const merged = new Map();
  let parsed = 0;
  for (let i = 0; i < numSubtables; i++) {
    const rec = cmapOffset + 4 + i * 8;
    const platformId = buf.readUInt16BE(rec);
    const encodingId = buf.readUInt16BE(rec + 2);
    const subOffset = cmapOffset + buf.readUInt32BE(rec + 4);
    const format = buf.readUInt16BE(subOffset);
    // Unicode subtables only: (0,x) Unicode platform, (3,0) symbol, (3,1) BMP,
    // (3,10) full. The (1,0) Mac subtable would give a different answer.
    const isUnicode =
      platformId === 0 ||
      (platformId === 3 && (encodingId === 0 || encodingId === 1 || encodingId === 10));
    if (!isUnicode) continue;
    const table = readSubtable(buf, subOffset, format);
    if (table.size === 0) continue;
    parsed++;
    for (const [cp, gid] of table) if (!merged.has(cp)) merged.set(cp, gid);
  }
  if (parsed === 0) throw new Error(`${file}: no parsable Unicode cmap subtable`);
  return merged;
}

/** Does [file] have a real glyph for [codePoint]? */
function hasGlyph(file, codePoint = PESO) {
  const table = cmapTable(file);
  const gid = table.get(codePoint);
  return { found: gid !== undefined && gid !== 0, glyphId: gid ?? null, mapped: table.size };
}

module.exports = { cmapTable, hasGlyph, PESO };

if (require.main === module) {
  const files = process.argv.slice(2);
  if (files.length === 0) {
    console.error('usage: node scripts/font-check.js <font.ttf> [...]');
    process.exit(2);
  }
  let bad = 0;
  for (const f of files) {
    try {
      const r = hasGlyph(f, PESO);
      console.log(
        `${f}: U+20B1 ₱ ${r.found ? 'PRESENT' : 'MISSING'} ` +
          `(glyph ${r.glyphId ?? '-'}, ${r.mapped} mapped code points)`,
      );
      if (!r.found) bad++;
    } catch (e) {
      console.log(`${f}: ERROR ${e.message}`);
      bad++;
    }
  }
  process.exit(bad === 0 ? 0 : 1);
}
