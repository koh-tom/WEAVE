// 展示用デモ: Inspector を見えないブラウザで開き、一定間隔でスクショを撮り続ける (画面には出さない)。
// ファイル名は撮った時刻 (epoch ms)。標準入力が閉じられたら終える。compose.py がつないで動画にする
import { chromium } from 'playwright-core';
import fs from 'fs';
const [url, outDir] = process.argv.slice(2);
const W = 1440, H = 810;
fs.mkdirSync(outDir, { recursive: true });
const b = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium', args: ['--no-sandbox', '--force-color-profile=srgb'] });
const page = await b.newPage({ viewport: { width: W, height: H } });
await page.goto(url);
await page.waitForSelector('.panel', { timeout: 15000 }).catch(() => {});
console.log('READY', Date.now());
let done = false;
process.stdin.resume();
process.stdin.on('end', () => { done = true; });
while (!done) {
  const t = Date.now();
  await page.screenshot({ path: `${outDir}/${t}.png` });
  const wait = 160 - (Date.now() - t);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
}
await b.close();
console.log('DONE');
