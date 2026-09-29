// Render App Store screenshots from AppStoreAssets/Screenshots/en-US/source.
// Output: AppStoreAssets/Screenshots/en-US/final, 1320 x 2868 JPEG, no alpha.
// Run from the repo root: npm i --no-save playwright && node scripts/app_store_screenshots/render.js
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.resolve(__dirname, '../..');
const source = path.join(root, 'AppStoreAssets/Screenshots/en-US/source');
const out = path.join(root, 'AppStoreAssets/Screenshots/en-US/final');
const names = ['01-before-after', '02-photo', '03-video', '04-looks', '05-private'];

// Chromium cannot read HEIC, so stage every source as PNG or JPEG next to the page.
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'underblue-shots-'));
const assets = path.join(work, 'assets');
fs.mkdirSync(assets);
fs.copyFileSync(path.join(__dirname, 'screens.html'), path.join(work, 'screens.html'));
for (const n of ['home', 'photo_before', 'photo_after', 'video_before', 'video_after']) {
  fs.copyFileSync(path.join(source, n + '.PNG'), path.join(assets, n + '.png'));
}
for (const n of ['video_frame_before', 'video_frame_after']) {
  execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '95',
    path.join(source, n + '.HEIC'), '--out', path.join(assets, n + '.jpg')], { stdio: 'ignore' });
}

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1320, height: 2868 }, deviceScaleFactor: 1 });
  await page.goto('file://' + path.join(work, 'screens.html'));
  await page.waitForLoadState('networkidle');
  await page.evaluate(() => Promise.all([...document.images].map(i => i.decode())));
  const sections = await page.locator('section').all();
  if (sections.length !== names.length) throw new Error(`expected ${names.length} sections, got ${sections.length}`);
  for (let i = 0; i < sections.length; i++) {
    const file = path.join(out, names[i] + '.jpg');
    await sections[i].screenshot({ path: file, type: 'jpeg', quality: 95 });
    console.log('wrote', path.relative(root, file));
  }
  await browser.close();
  fs.rmSync(work, { recursive: true, force: true });
})().catch(e => { console.error(e); process.exit(1); });
