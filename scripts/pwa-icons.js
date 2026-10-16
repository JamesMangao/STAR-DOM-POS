'use strict';

// scripts/pwa-icons.js — generate the PWA icon set from the brand logo (W4).
//
//   node scripts/pwa-icons.js
//
// Source: assets/images/stardom-logo.webp (copied from the website's own asset,
// read-only). Output: web/icons/Icon-192, Icon-512, Icon-maskable-192,
// Icon-maskable-512, Icon-180 (apple-touch-icon) and web/favicon.png.
//
// `any` icons keep transparency and letterbox the logo; `maskable` icons are
// the logo on a full brand-red square with the safe zone (the centre 80% that
// iOS/Android may crop to a circle) respected, which is why they are padded to
// 60% instead of filling the canvas.

const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const ROOT = path.resolve(__dirname, '..');
const SOURCE = path.join(ROOT, 'assets', 'images', 'stardom-logo.webp');
const OUT = path.join(ROOT, 'web', 'icons');
const BRAND = { r: 0xb7, g: 0x00, b: 0x11, alpha: 1 };

async function main() {
  if (!fs.existsSync(SOURCE)) {
    console.error(`missing brand logo: ${SOURCE}`);
    process.exit(1);
  }
  fs.mkdirSync(OUT, { recursive: true });
  const logo = fs.readFileSync(SOURCE);
  const meta = await sharp(logo).metadata();
  console.log(`source: ${path.relative(ROOT, SOURCE)} ${meta.width}x${meta.height} ${meta.format}`);

  // --- "any" icons: transparent background, logo fits inside with a margin.
  for (const size of [192, 512]) {
    const inner = Math.round(size * 0.86);
    const buf = await sharp(logo)
      .resize(inner, inner, { fit: 'contain', withoutEnlargement: false, background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .png()
      .toBuffer();
    await sharp({ create: { width: size, height: size, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
      .composite([{ input: buf, gravity: 'centre' }])
      .png()
      .toFile(path.join(OUT, `Icon-${size}.png`));
    console.log(`wrote web/icons/Icon-${size}.png`);
  }

  // --- maskable icons: brand square, logo inside the 60% safe zone.
  for (const size of [192, 512]) {
    const inner = Math.round(size * 0.6);
    const buf = await sharp(logo)
      .resize(inner, inner, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .png()
      .toBuffer();
    await sharp({ create: { width: size, height: size, channels: 4, background: BRAND } })
      .composite([{ input: buf, gravity: 'centre' }])
      .png()
      .toFile(path.join(OUT, `Icon-maskable-${size}.png`));
    console.log(`wrote web/icons/Icon-maskable-${size}.png`);
  }

  // --- apple-touch-icon: opaque (iOS ignores alpha), 180x180.
  const appleInner = Math.round(180 * 0.8);
  const appleBuf = await sharp(logo)
    .resize(appleInner, appleInner, { fit: 'contain', background: { r: 0xff, g: 0xf8, b: 0xf5, alpha: 1 } })
    .png()
    .toBuffer();
  await sharp({ create: { width: 180, height: 180, channels: 4, background: { r: 0xff, g: 0xf8, b: 0xf5, alpha: 1 } } })
    .composite([{ input: appleBuf, gravity: 'centre' }])
    .png()
    .toFile(path.join(OUT, 'Icon-180.png'));
  console.log('wrote web/icons/Icon-180.png');

  const favicon = await sharp(logo)
    .resize(32, 32, { fit: 'contain', background: { r: 0xff, g: 0xf8, b: 0xf5, alpha: 1 } })
    .png()
    .toBuffer();
  await sharp({ create: { width: 32, height: 32, channels: 4, background: { r: 0xff, g: 0xf8, b: 0xf5, alpha: 1 } } })
    .composite([{ input: favicon, gravity: 'centre' }])
    .png()
    .toFile(path.join(ROOT, 'web', 'favicon.png'));
  console.log('wrote web/favicon.png');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
