// 普段の Inspector をそのまま録画して、その上に「雑な動画編集」風の文字と矢印を後付けする。
// 合成ページは使わない。本物の画面を全画面で映し、DENIED の行・ON AIR・復帰の行などを矢印で指す。
// 発火 (草・攻撃・暴走) も注釈もこのスクリプトの 1 本の時計で進める。
import { chromium } from 'playwright-core';

const inspectorUrl = process.argv[2];
const outDir = process.argv[3];
const W = 1440, H = 810;

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium', args: ['--no-sandbox', '--force-color-profile=srgb'] });
const context = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 1, recordVideo: { dir: outDir, size: { width: W, height: H } } });
const page = await context.newPage();
await page.goto(inspectorUrl);
await page.waitForSelector('.panel', { timeout: 15000 });
await page.waitForTimeout(1500);

// 注釈レイヤー (画面の上に重ねる。手書き風の文字箱と矢印)
await page.evaluate(() => {
  const NS = 'http://www.w3.org/2000/svg';
  const layer = document.createElement('div');
  layer.id = 'anno';
  layer.style.cssText = 'position:fixed;inset:0;z-index:99999;pointer-events:none;font-family:system-ui,sans-serif;';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('width', '100%'); svg.setAttribute('height', '100%');
  svg.style.cssText = 'position:absolute;inset:0;overflow:visible;';
  svg.innerHTML = '<defs><marker id="ah" markerWidth="12" markerHeight="12" refX="8" refY="4" orient="auto"><path d="M0,0 L9,4 L0,8 z" fill="#e01414"/></marker></defs>';
  layer.appendChild(svg);
  document.body.appendChild(layer);
  window.__svg = svg;
  window.__rect = (substr) => {
    // テキストを含む「いちばん小さい要素」= 実際の行/セルを選ぶ (大きな親を掴まない)
    const els = [...document.querySelectorAll('td,th,span,div,button,strong,b')]
      .filter((e) => e.offsetParent !== null && (e.textContent || '').includes(substr) && e.getClientRects().length);
    if (!els.length) return null;
    els.sort((a, b) => { const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect(); return ra.width * ra.height - rb.width * rb.height; });
    const r = els[0].getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height, cx: r.left + r.width / 2, cy: r.top + r.height / 2 };
  };
  // 文字箱を出す。x,y は箱の左上、rot は傾き(度)、color は枠色
  window.__note = (id, x, y, text, color, rot) => {
    let n = document.getElementById(id);
    if (!n) { n = document.createElement('div'); n.id = id; n.className = 'note'; document.getElementById('anno').appendChild(n); }
    n.style.cssText = `position:absolute;left:${x}px;top:${y}px;max-width:340px;transform:rotate(${rot||0}deg);background:#fffce8;border:2.5px solid ${color};color:#111;font-weight:800;font-size:16px;line-height:1.35;padding:7px 11px;box-shadow:2px 3px 0 rgba(0,0,0,.15);`;
    n.textContent = text;
  };
  // 矢印: 箱の点(fx,fy)からターゲット(tx,ty)へ、少し曲げて引く
  window.__arrow = (id, fx, fy, tx, ty, color) => {
    let p = document.getElementById(id);
    if (!p) { p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.id = id; window.__svg.appendChild(p); }
    const mx = (fx + tx) / 2 + (ty - fy) * 0.18, my = (fy + ty) / 2 - (tx - fx) * 0.18;
    p.setAttribute('d', `M${fx},${fy} Q${mx},${my} ${tx},${ty}`);
    p.setAttribute('fill', 'none'); p.setAttribute('stroke', color || '#e01414');
    p.setAttribute('stroke-width', '3.5'); p.setAttribute('stroke-linecap', 'round');
    p.setAttribute('marker-end', 'url(#ah)');
  };
  window.__clear = () => { document.querySelectorAll('#anno .note').forEach((n) => n.remove()); window.__svg.querySelectorAll('path[id]').forEach((p) => p.remove()); };
  // 画面下の帯 (今のシーンの一言)
  const band = document.createElement('div');
  band.id = 'band';
  band.style.cssText = 'position:absolute;left:0;right:0;bottom:0;padding:12px 20px;background:#111;color:#fff;font-weight:800;font-size:20px;opacity:0;transition:opacity .3s;';
  layer.appendChild(band);
  window.__band = (t) => { band.textContent = t || ''; band.style.opacity = t ? '1' : '0'; };
});

const band = (t) => page.evaluate((t) => window.__band(t), t);
const clear = () => page.evaluate(() => window.__clear());
const note = (id, x, y, text, color, rot) => page.evaluate((a) => window.__note(...a), [id, x, y, text, color, rot || 0]);
const rect = (s) => page.evaluate((s) => window.__rect(s), s);
const arrow = (id, fx, fy, tx, ty, color) => page.evaluate((a) => window.__arrow(...a), [id, fx, fy, tx, ty, color]);
const wait = (ms) => page.waitForTimeout(ms);

async function grass() { await page.getByText('10 件送る', { exact: false }).click().catch(()=>{}); }
async function chat(text) {
  const input = page.locator('input').nth(1);
  await input.fill(text).catch(()=>{});
  await input.press('Enter').catch(()=>{});
}
// テキストを指す矢印つきの注釈を出す
async function point(id, targetText, boxXY, text, color) {
  const r = await rect(targetText); if (!r) { await note(id+'n', boxXY[0], boxXY[1], text, color); return; }
  await note(id+'n', boxXY[0], boxXY[1], text, color, -1.5);
  const fromX = boxXY[0] + 150, fromY = boxXY[1] + (boxXY[1] < r.y ? 44 : -6);
  await arrow(id+'a', fromX, fromY, r.cx, r.cy, color);
}

// ---- 導入 ----
await band('WEAVE Inspector — 配信ソフトのプラグインを安全に動かす基盤');
await wait(3200); await band('');

// ---- ふだんの配信 (実用ツール) ----
await band('まず、ふだんの配信。配信でよく使うツールがそのまま動く');
await chat('!sub'); await wait(900); await chat('!sub'); await wait(900);
await point('bar', 'サブ', [300, 560], 'サブ目標バー：新しいサブで数が増える（実際の配信ウィジェット）', '#1a7f37');
await wait(3000); await clear();
await chat('!so StreamerTaro'); await wait(1200);
await point('so', 'チェック', [300, 560], '「!so 名前」で配信者を紹介するコマンド（Nightbot 等でおなじみ）', '#1a7f37');
await wait(3200); await clear(); await band('');

// ---- 悪意あるプラグイン ----
await band('ここで、悪意あるプラグインが 1 個混じっていたら？');
await wait(2600);
for (let i=0;i<6;i++){ await chat('go'); await wait(350); }
await wait(600);
await point('den', 'core.system.shutdown', [300, 590], '今までの世界なら、ここでトークンを盗んで外部送信できてた', '#e01414');
await wait(3600);
await note('den2', 300, 660, 'WEAVE は「宣言した権限」の外を全部拒否 → 1 バイトも出られない', '#1a7f37', -1);
await wait(3800); await clear(); await band('');

// ---- 暴走 ----
await band('プラグインが暴走 (無限ループ) したら？');
await wait(2200);
await chat('!freeze'); await wait(1400); await chat('また草');
await wait(900);
await point('flt', '処理が終わらない', [300, 580], '今までの世界なら、配信ソフトごとフリーズ', '#e01414');
await wait(3200); await clear();
await point('rec', '止まっていた時間', [300, 580], 'WEAVE は、そのプラグインだけ止めて数 ms で復帰。配信は止まらない', '#1a7f37');
await wait(1200);
await point('air2', '配信中', [300, 660], '時計は止まっていない（配信は 1 度も途切れていない）', '#1a7f37');
await wait(4200); await clear(); await band('');

// ---- 締め ----
await band('侵害されてもここまで / 落ちてもここまで — 起動前に計算でき、実行時に強制され、事後に監査できる');
await wait(4200); await band('');
await wait(700);

// ---- 開発者向け: プラグインはこれだけ ----
// 本物の Inspector を暗く落として、その上に「作り方」のカードを重ねる。
// コードは weave init が生成する雛形に沿った内容、コマンドは実在するものだけ。
await page.evaluate(() => {
  const dim = document.createElement('div');
  dim.id = 'devdim';
  dim.style.cssText = 'position:fixed;inset:0;z-index:99998;background:rgba(0,0,0,.62);';
  const card = document.createElement('div');
  card.style.cssText = 'position:absolute;left:50%;top:52%;transform:translate(-50%,-50%);width:1040px;background:#fff;border:2.5px solid #111;box-shadow:3px 4px 0 rgba(0,0,0,.25);padding:20px 26px;font-family:system-ui,sans-serif;';
  const g = '#1a7f37', r = '#c81616', c = '#6b7280';
  card.innerHTML = `
    <div style="font-size:22px;font-weight:900;margin-bottom:4px;">プラグインを作るのは、これだけ</div>
    <div style="font-size:14px;color:${c};margin-bottom:14px;">できることを宣言する json と、ロジックの zig。書いていない操作は、実行時に全部止まる。</div>

    <div style="font-size:13px;font-weight:800;color:${c};margin:2px 0 4px;">① hello.json — できることの宣言</div>
    <pre style="margin:0 0 14px;padding:12px 14px;background:#f6f7f8;border:1px solid #dcdfe3;font-size:15px;line-height:1.55;font-family:ui-monospace,Menlo,Consolas,monospace;color:#111;overflow:hidden;">{
  "name": "hello",
  "permissions": {
    "subscribe": ["ext.twitch.chat.message"],   <span style="color:${g};font-weight:700;">// 受け取るイベント</span>
    "publish":   ["ext.hello.greeting"]          <span style="color:${g};font-weight:700;">// 出せるイベント</span> <span style="color:${r};font-weight:800;">← これ以外は全部拒否</span>
  },
  "rate_limit_eps": 20                           <span style="color:${g};font-weight:700;">// 1 秒あたりの上限</span>
}</pre>

    <div style="font-size:13px;font-weight:800;color:${c};margin:2px 0 4px;">② hello.zig — ロジック</div>
    <pre style="margin:0 0 14px;padding:12px 14px;background:#f6f7f8;border:1px solid #dcdfe3;font-size:15px;line-height:1.55;font-family:ui-monospace,Menlo,Consolas,monospace;color:#111;overflow:hidden;">export fn on_message(topic, payload) void {
    if (topic != "ext.twitch.chat.message") return;
    const chat = parseJson(Chat, payload);
    if (startsWith(chat.message, "!hello"))
        publish("ext.hello.greeting", .{ .to = chat.user });   <span style="color:${g};font-weight:800;">← 書くのはここだけ</span>
}</pre>

    <pre style="margin:0;padding:12px 14px;background:#111;color:#eaeaea;font-size:14px;line-height:1.6;font-family:ui-monospace,Menlo,Consolas,monospace;overflow:hidden;">$ weave init hello                          <span style="color:#8a8f98;"># 雛形 (.zig + .json) を作る</span>
$ zig build                                 <span style="color:#8a8f98;"># → wasm-apps/hello.wasm</span>
$ weave audit hello                         <span style="color:#8a8f98;"># 乗っ取られたら何ができるかを起動前に確認</span>
$ weave run --mock-obs wasm-apps/hello.wasm <span style="color:#8a8f98;"># 起動して Inspector で確認</span></pre>

    <div style="font-size:12px;color:${c};margin-top:10px;">※ 上のコードは表示用に簡略化。実体は <b>weave init hello</b> が生成する雛形そのまま。</div>
  `;
  dim.appendChild(card);
  document.body.appendChild(dim);
});
await wait(800);
await band('開発者へ — プラグインは「宣言 (json)」と「ロジック (zig)」だけ。乗っ取られても、宣言の外には 1 バイトも出られない');
await wait(6500);
await band('weave init で雛形 → zig build → weave run。今ある Bot も、この安全な枠の中で動かせる');
await wait(6000);
await band('');
await wait(700);

await context.close();
await browser.close();
console.log('done');
