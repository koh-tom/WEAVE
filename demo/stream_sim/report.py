#!/usr/bin/env python3
"""demo/stream_sim/report.py — 模擬配信の記録から「配信レポート」(report.html) と、配信画面の一覧 (sheet.png) を作る

  python3 demo/stream_sim/report.py demo/output/stream_sim/run-<日時>
"""
import glob, html, json, os, re, sys
from collections import Counter

from PIL import Image, ImageDraw, ImageFont

RUN = os.path.abspath(sys.argv[1])
SHOTS = os.path.join(RUN, "shots")
tl = [json.loads(l) for l in open(os.path.join(RUN, "timeline.jsonl"), encoding="utf-8")]
stats = json.load(open(os.path.join(RUN, "stats.json"), encoding="utf-8"))

# ---------------------------------------------------------------- 件数
topics = Counter()
for f in glob.glob(os.path.join(RUN, "events_*.jsonl")):
    for line in open(f, encoding="utf-8", errors="replace"):
        m = re.search(r'"topic":"([^"]+)"', line)
        if m:
            topics[m.group(1)] += 1
obs_req = {k.split(".")[-1]: v for k, v in topics.items() if k.startswith("core.obs.request.")}
alerts = sum(v for k, v in topics.items() if k.startswith(("ext.streamelements.", "ext.streamlabs.")))
denied = Counter()
for line in open(os.path.join(RUN, "audit.log"), encoding="utf-8"):
    m = re.search(r'"topic":"core\.security\.([a-z_]+)"', line)
    if m:
        denied[m.group(1)] += 1
recov = {e["text"]: e for e in tl if e["kind"] == "recovery"}
plugin_rec = next((e["ms"] for e in tl if e["kind"] == "recovery" and "loop_node" in e["text"]), None)
core_rec = next((e for e in tl if e["kind"] == "recovery" and "Supervisor" in e["text"]), {})
lat = stats.get("latency") or {}
obs = stats.get("obs") or {}
dur = tl[-1]["t"] if tl else 0
live_start = next((e["t"] for e in tl if e["kind"] == "op"), 0)
chats = [e for e in tl if e["kind"] == "chat"]
viewers = len({e["text"].split(":")[0] for e in chats})
rec_files = sorted(glob.glob(os.path.join(RUN, "..", "obs", "weave_stream_*.mp4")))
rec_name = os.path.basename(rec_files[-1]) if rec_files else "(なし)"


def us_ms(v):
    return f"{v / 1000:.2f}" if v is not None else "?"


tiles = [
    ("チャット → OBS への指示", f"{us_ms(lat.get('p50_us'))} ms", f"p50 / p99 {us_ms(lat.get('p99_us'))} ms ({lat.get('samples', 0)} 件)"),
    ("暴走したプラグインの復帰", f"{plugin_rec} ms", "無限ループ → 命令数上限で停止 → 予備に切替"),
    ("Core を kill -9 → 復帰", f"{core_rec.get('ms', '?')} ms", f"うち Core の起動 {core_rec.get('core_ready_ms', '?')} ms (Supervisor)"),
    ("拒否した攻撃", f"{denied.get('acl_denied', 0)} 件", "悪意プラグインの core.system.shutdown 発行。通ったのは 0 件"),
    ("OBS への指示", f"{sum(obs_req.values())} 件", " / ".join(f"{k} {v}" for k, v in sorted(obs_req.items(), key=lambda x: -x[1]))),
    ("OBS の落ちたフレーム", f"{obs.get('outputSkippedFrames', '?')} / {obs.get('outputTotalFrames', '?')}", f"描画 {obs.get('renderSkippedFrames', '?')} / {obs.get('renderTotalFrames', '?')}・CPU {obs.get('cpuUsage', 0):.1f} %"),
    ("チャット", f"{len(chats)} 件", f"視聴者 {viewers} 人 (すべて架空)"),
    ("アラート", f"{alerts} 件", "StreamElements / Streamlabs (モック) のフォロー・サブ・投げ銭"),
]

KIND = {"system": "進行", "health": "稼働状態", "op": "操作", "incident": "事故", "recovery": "復帰", "shot": "記録", "warn": "注意"}
rows = []
for e in tl:
    if e["kind"] == "chat":
        continue
    extra = ""
    if e["kind"] == "health" and e.get("obs_problems"):
        p = e["obs_problems"][0]
        extra = f'<div class="sub">{html.escape(p.get("action") or "")}</div>'
    if e["kind"] == "health" and e.get("problems"):
        extra = '<div class="sub">' + html.escape("、".join(f'{p["node"]} ({p["status"]})' for p in e["problems"])) + "</div>"
    rows.append(f'<tr class="k-{e["kind"]}"><td class="t">{e["t"]:.2f}</td><td class="kind">{KIND.get(e["kind"], e["kind"])}</td>'
                f'<td>{html.escape(e["text"])}{extra}</td></tr>')

shot_caps = {e["file"]: e["text"] for e in tl if e["kind"] == "shot" and e.get("file")}
gallery = []
for f in sorted(os.listdir(SHOTS)):
    if not f.endswith(".png"):
        continue
    cap = shot_caps.get(f) or shot_caps.get(f.replace("_obsapp", "_program"), "")
    if f.endswith("_obsapp.png"):
        cap = "OBS アプリの画面 — " + cap
    elif f.endswith("_program.png"):
        cap = "OBS が描いた配信画面 — " + cap
    cls = "tall" if f.endswith("_status.png") else ""
    gallery.append(f'<figure class="{cls}"><img src="shots/{f}" loading="lazy"><figcaption>{html.escape(cap)}</figcaption></figure>')

page = f"""<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>模擬配信レポート</title><style>
:root {{ --ink:#1b1b1b; --sub:#5f6368; --line:#d9dce0; --acc:#1f3a5f; --bad:#c62828; --bg:#fff; --soft:#f3f4f6; }}
body {{ margin:0; background:var(--bg); color:var(--ink); font-family:"Noto Sans JP","Noto Sans CJK JP",system-ui,sans-serif; }}
.wrap {{ max-width:1180px; margin:0 auto; padding:28px 20px 60px; }}
h1 {{ font-size:28px; margin:0 0 4px; }} h2 {{ font-size:20px; margin:34px 0 12px; border-bottom:2px solid var(--acc); padding-bottom:4px; }}
.meta {{ color:var(--sub); font-size:14px; line-height:1.7; }}
.tiles {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(250px,1fr)); gap:12px; margin-top:18px; }}
.tile {{ border:1px solid var(--line); border-radius:8px; padding:12px 14px; background:var(--soft); }}
.tile .l {{ font-size:13px; color:var(--sub); }} .tile .v {{ font-size:30px; font-weight:800; color:var(--acc); margin:2px 0; }}
.tile .s {{ font-size:12px; color:var(--sub); line-height:1.5; }}
table {{ border-collapse:collapse; width:100%; font-size:14px; }} td {{ border-bottom:1px solid var(--line); padding:6px 8px; vertical-align:top; }}
td.t {{ width:60px; text-align:right; color:var(--sub); font-variant-numeric:tabular-nums; }} td.kind {{ width:70px; color:var(--sub); }}
tr.k-incident td {{ color:var(--bad); font-weight:700; }} tr.k-recovery td {{ color:var(--acc); font-weight:700; }}
.sub {{ font-size:12px; color:var(--sub); font-weight:400; margin-top:2px; }}
.gallery {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(360px,1fr)); gap:16px; }}
figure {{ margin:0; border:1px solid var(--line); border-radius:8px; overflow:hidden; background:#fff; }}
figure img {{ width:100%; display:block; }} figure.tall img {{ max-height:560px; object-fit:contain; background:#fafafa; }}
figcaption {{ font-size:13px; padding:8px 10px; color:var(--ink); line-height:1.5; }}
code {{ background:var(--soft); padding:1px 4px; border-radius:4px; }}
</style></head><body><div class="wrap">
<h1>模擬配信レポート — WEAVE 杯 決勝 ― 実況配信</h1>
<div class="meta">本物の OBS Studio {html.escape(str(next((e.get("version") for e in tl if e.get("version")), "")))} に、プラグイン 9 個・アラート 2 系統 (モック)・チャットをつないで約 {dur - live_start:.0f} 秒の番組を流し、
途中で事故を 4 つ起こした記録です。視聴者・チャット・アラートはすべてローカルの偽データで、外部のサービスには接続していません。<br>
計測環境: Ryzen 7 7840U / 32 GB / Linux、WEAVE は ReleaseFast ビルド。OBS の録画: <code>demo/output/stream_sim/obs/{html.escape(rec_name)}</code></div>
<div class="tiles">{"".join(f'<div class="tile"><div class="l">{html.escape(l)}</div><div class="v">{html.escape(v)}</div><div class="s">{html.escape(s)}</div></div>' for l, v, s in tiles)}</div>
<h2>何が起きたか (経過秒)</h2><table>{"".join(rows)}</table>
<h2>記録した画面</h2><div class="gallery">{"".join(gallery)}</div>
</div></body></html>"""
open(os.path.join(RUN, "report.html"), "w", encoding="utf-8").write(page)

# ---------------------------------------------------------------- 配信画面の一覧 (1 枚絵)
progs = [f for f in sorted(os.listdir(SHOTS)) if f.endswith("_program.png")]
font = ImageFont.truetype("/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc", 24, index=0)
W, H, CAP, COLS = 640, 360, 44, 3
rows_n = (len(progs) + COLS - 1) // COLS
sheet = Image.new("RGB", (COLS * W + (COLS + 1) * 12, rows_n * (H + CAP) + (rows_n + 1) * 12), "white")
d = ImageDraw.Draw(sheet)
for i, f in enumerate(progs):
    x, y = 12 + (i % COLS) * (W + 12), 12 + (i // COLS) * (H + CAP + 12)
    sheet.paste(Image.open(os.path.join(SHOTS, f)).convert("RGB").resize((W, H)), (x, y))
    cap = shot_caps.get(f, f)
    while d.textlength(cap, font=font) > W and len(cap) > 4:
        cap = cap[:-2] + "…" if not cap.endswith("…") else cap[:-3] + "…"
    d.text((x, y + H + 8), cap, font=font, fill="#1b1b1b")
sheet.save(os.path.join(RUN, "sheet.png"))
print("wrote", os.path.join(RUN, "report.html"), "and sheet.png")
