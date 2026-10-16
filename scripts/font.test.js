// scripts/font.test.js — the ₱ (U+20B1) must exist in at least one bundled
// font, and the theme must declare that font as the other's fallback (W-rule).
//
//   node --test scripts/font.test.js
//
// This is a real regression test, not a formality: Sora.ttf as bundled is a
// Latin-1 subset WITHOUT the peso sign, so a screen that draws a price in Sora
// shows a blank box unless PlusJakartaSans is declared as its fallback.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const { hasGlyph, PESO } = require('./font-check');

const ROOT = path.resolve(__dirname, '..');
const SORA = path.join(ROOT, 'assets', 'fonts', 'Sora.ttf');
const JAKARTA = path.join(ROOT, 'assets', 'fonts', 'PlusJakartaSans.ttf');
const THEME = path.join(ROOT, 'lib', 'core', 'theme.dart');

test('the bundled PlusJakartaSans carries ₱ (U+20B1)', () => {
  assert.ok(fs.existsSync(JAKARTA), `${JAKARTA} must be bundled`);
  const r = hasGlyph(JAKARTA, PESO);
  assert.ok(r.found, 'U+20B1 must map to a real glyph, not a blank box');
});

test('every bundled font that lacks ₱ has one that has it declared as fallback', () => {
  const fonts = [SORA, JAKARTA].filter((f) => fs.existsSync(f));
  assert.ok(fonts.length > 0, 'at least one bundled font is required');

  const missing = fonts.filter((f) => !hasGlyph(f, PESO).found);
  const have = fonts.filter((f) => hasGlyph(f, PESO).found);
  assert.ok(have.length > 0, 'no bundled font has the peso sign');

  const theme = fs.readFileSync(THEME, 'utf8');
  for (const f of missing) {
    const family = path.basename(f, path.extname(f)).includes('Sora')
      ? 'Sora'
      : 'PlusJakartaSans';
    if (family !== 'Sora') continue; // only Sora styles are known to lack it
    assert.match(
      theme,
      /soraFallback\s*=\s*\['PlusJakartaSans'\]/,
      'a Sora style without a fallback would draw a blank box for ₱',
    );
    assert.match(theme, /fontFamilyFallback:\s*soraFallback/);
  }
});

test('the receipt PDF is set in the font that has ₱', () => {
  const printing = fs.readFileSync(
    path.join(ROOT, 'lib', 'data', 'printing.dart'),
    'utf8',
  );
  assert.match(
    printing,
    /assets\/fonts\/PlusJakartaSans\.ttf/,
    'the PDF must load the peso-capable font',
  );
});

test('no peso figure is hard-coded through a font that lacks it (grep of format.dart)', () => {
  const fmt = fs.readFileSync(path.join(ROOT, 'lib', 'core', 'format.dart'), 'utf8');
  assert.match(fmt, /₱/, 'Fmt.peso is the single peso formatter');
});
