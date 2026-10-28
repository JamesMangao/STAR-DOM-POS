// scripts/screenshots.js — capture the README screenshots of the PWA.
//
// The app is a pure PWA (no APK), so both shots are the SAME deployed build
// rendered by headless Chromium: a desktop window (sidebar layout) and a real
// Android phone profile (Pixel 7 UA, touch, mobile viewport → bottom bar).
//
//   node scripts/screenshots.js                 # live site
//   POS_URL=http://127.0.0.1:8899/ node scripts/screenshots.js
'use strict';

const fs = require('fs');
const path = require('path');
const { chromium, devices } = require('playwright');
const sharp = require('sharp');

const URL = process.env.POS_URL || 'https://stardom-pos.pages.dev/';

// `outWidth` is the pixel width written to disk: the phone shot keeps ~2x
// pixels (crisp at README size), the desktop one is downscaled to 1x.
const SHOTS = [
  {
    name: 'web-desktop.png',
    label: 'desktop web 1440x900',
    outWidth: 1440,
    context: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 },
  },
  {
    name: 'android-phone.png',
    label: 'Android phone (Pixel 7)',
    outWidth: 780,
    // A Playwright device profile: Android UA, touch, 412x915 CSS viewport.
    context: { ...devices['Pixel 7'] },
  },
];

/** System Chrome first (already installed), then Playwright's bundle. */
function chromePath() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    '/usr/bin/google-chrome',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p));
}

(async () => {
  const outDir = path.join(__dirname, '..', 'docs', 'screenshots');
  fs.mkdirSync(outDir, { recursive: true });

  const executablePath = chromePath();
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    args: ['--hide-scrollbars'],
  });

  for (const shot of SHOTS) {
    const context = await browser.newContext(shot.context);
    const page = await context.newPage();
    await page.goto(URL, { waitUntil: 'load', timeout: 90_000 });
    await page.waitForSelector('flutter-view, flt-glass-pane', { timeout: 90_000 });

    // main.dart removes the HTML splash (#loading) on Flutter's first frame,
    // so its absence means the real UI is up and not the boot card.
    await page
      .waitForFunction(() => !document.getElementById('loading'), { timeout: 90_000 })
      .catch(() => console.warn('splash never cleared; capturing anyway'));
    // Product photos decode asynchronously after the first frame.
    await page.waitForTimeout(6000);

    const raw = await page.screenshot();
    // Palette PNG: flat UI colours quantise to 256 without visible banding and
    // the file is ~4x smaller than a truecolour capture.
    const png = await sharp(raw)
      .resize({ width: shot.outWidth })
      .png({ compressionLevel: 9, palette: true, colours: 256, quality: 95 })
      .toBuffer();
    fs.writeFileSync(path.join(outDir, shot.name), png);
    console.log(`saved ${shot.name} (${shot.label}, ${Math.round(png.length / 1024)} KB)`);
    await context.close();
  }

  await browser.close();
})().catch((err) => {
  console.error('screenshot run failed:', err.message);
  process.exit(1);
});
