const fs = require('fs');
const log = (msg) => { fs.appendFileSync('sw-test.log', msg + '\n'); console.log(msg); };

log('Start debug script');
const { chromium } = require('playwright');
(async () => {
  log('Launching browser');
  const browser = await chromium.launch();
  log('Browser launched');
  await browser.close();
  log('Browser closed');
})();
