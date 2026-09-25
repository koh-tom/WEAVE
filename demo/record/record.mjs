import { chromium } from 'playwright-core';

const url = process.argv[2];
const outDir = process.argv[3];
// (発火は run.sh が weave CLI で行う)
const W = 1440, H = 810;

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium', args: ['--no-sandbox', '--force-color-profile=srgb'] });
const context = await browser.newContext({
  viewport: { width: W, height: H },
  deviceScaleFactor: 1,
  recordVideo: { dir: outDir, size: { width: W, height: H } },
});
const page = await context.newPage();
await page.goto(url);
await page.waitForSelector('.card', { timeout: 15000 });
await page.waitForTimeout(1500);

// 画面上に字幕を出す仕組み (録画に焼き込まれる)
await page.addStyleTag({ content: `
  #cap { position: fixed; left: 0; right: 0; bottom: 0; z-index: 9999; padding: 18px 28px;
    background: linear-gradient(0deg, rgba(8,10,14,.96), rgba(8,10,14,.72) 70%, transparent);
    font-family: 'Space Grotesk', system-ui, sans-serif; transition: opacity .4s; opacity: 0; }
  #cap .k { font-size: 12px; letter-spacing: .2em; text-transform: uppercase; font-weight: 700; }
  #cap .t { font-size: 24px; font-weight: 700; color: #eef1f6; margin-top: 4px; line-height: 1.3; }
  #cap.be .k { color: #ff5d73; } #cap.af .k { color: #34e2a4; }
  #chip { position: fixed; top: 14px; left: 50%; transform: translateX(-50%); z-index: 9999;
    font-family: 'JetBrains Mono', monospace; font-size: 12px; padding: 6px 14px; border-radius: 999px;
    background: rgba(18,21,29,.9); border: 1px solid #262c3a; color: #9aa4b6; opacity: 0; transition: opacity .3s; }
`});
await page.evaluate(() => {
  const cap = document.createElement('div'); cap.id = 'cap';
  cap.innerHTML = '<div class="k"></div><div class="t"></div>'; document.body.appendChild(cap);
  const chip = document.createElement('div'); chip.id = 'chip'; document.body.appendChild(chip);
  window.__cap = (kind, k, t) => { cap.className = kind; cap.querySelector('.k').textContent = k; cap.querySelector('.t').textContent = t; cap.style.opacity = t ? '1' : '0'; };
  window.__chip = (s) => { chip.textContent = s || ''; chip.style.opacity = s ? '1' : '0'; };
});

const cap = (kind, k, t) => page.evaluate(([kind,k,t]) => window.__cap(kind,k,t), [kind,k,t]);
const chip = (s) => page.evaluate((s) => window.__chip(s), s);
const wait = (ms) => page.waitForTimeout(ms);

// クリックで草ラッシュを送るヘルパー (Inspector のボタン)
async function grass() { await page.getByText('草ラッシュ', { exact: false }).click().catch(()=>{}); }

// シーン進行。外部の weave CLI 発火はドライバ (record_demo.sh) が別プロセスで行い、ここは字幕と時間管理
await wait(800);
await cap('af', 'WEAVE Inspector', '左が配信画面、右が WEAVE の内部。すべて実際に動いています');
await wait(3500);

await cap('af', 'ふだんの配信', 'チャットが盛り上がると、配信画面のオーバーレイが自動で出る');
await chip('ext.twitch.chat.message → kusa_node → OBS');
for (let i=0;i<2;i++){ await grass(); await wait(1500); }
await wait(2500); await chip('');

await cap('be', '今までの世界なら', 'プラグイン1個が悪意を持つだけで、トークンもアカウントも外に流出する');
await wait(4000);

await cap('af', 'WEAVE では', '同じ悪意あるコードも、宣言した権限の外へは1バイトも出られない');
await chip('malicious_plugin: fopen✗ socket✗ 権限外publish → DENIED');
// マルウェアの攻撃はドライバが weave topic pub で発火。DENIED フィードが光る
await wait(5000); await chip('');

await cap('be', '暴走・クラッシュも', '普通なら、1個のプラグインの暴走で配信ソフトごとフリーズする');
await wait(3500);

await cap('af', 'WEAVE では', 'そのプラグインだけが隔離され、数ミリ秒で自動復帰。配信は1msも止まらない');
await chip('loop_node: 無限ループ → 命令数上限で遮断 → 予備インスタンスで復帰');
// ドライバが !freeze を送る
await wait(5500); await chip('');

await cap('af', '侵害されてもここまで / 落ちてもここまで', '起動前に計算でき、実行時に強制され、事後に監査できる');
await wait(4500);
await cap('af', '', '');
await wait(1200);

await context.close(); // ここで webm が書き出される
await browser.close();
console.log('video written to', outDir);
