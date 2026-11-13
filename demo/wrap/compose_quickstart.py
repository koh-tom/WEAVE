#!/usr/bin/env python3
"""demo/wrap/compose_quickstart.py — run_quickstart.py の記録 (端末・ログ・チャット + OBS の録画) を 1 本の動画にする

  python3 demo/wrap/compose_quickstart.py demo/output/wrap_demo/quick-<日時>
  出力: <記録>/quickstart.mp4 (1920x1080, 30fps, 無音)
  端末の表示は、実際に出た文字を記録した時刻どおりに並べ直したもの (コマンドは打っているように 1 文字ずつ出す)
"""
import json, os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

RUN = os.path.abspath(sys.argv[1])
FPS = 30
W, H = 1920, 1080
BG, PANE, HEAD = "#15181c", "#1e2227", "#2c313a"
COL = {"cmd": "#8ddb8c", "out": "#e6edf3", "note": "#9aa4af", "log": "#cdd9e5", "chat": "#e6edf3"}
TTC = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc"
BOLD = "/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc"


def font(path, size, name):
    for i in range(10):
        try:
            f = ImageFont.truetype(path, size, index=i)
        except Exception:
            break
        if f.getname()[0] == name:
            return f
    return ImageFont.truetype(path, size)


MONO = font(TTC, 23, "Noto Sans Mono CJK JP")
MONO_S = font(TTC, 22, "Noto Sans Mono CJK JP")
TITLE = font(BOLD, 26, "Noto Sans CJK JP")

evs = [json.loads(l) for l in open(os.path.join(RUN, "session.jsonl"), encoding="utf-8")]
t_rec = next(e["t"] for e in evs if e.get("rec_start"))
t_end = next(e["t"] for e in evs if e["text"] == "おわり") + 0.5
DUR = t_end - t_rec
TYPE = 0.8  # コマンドを打つのにかける秒数

# 区画: 左 = 端末、右上 = OBS、右中 = WEAVE のログ、右下 = チャット
TERM = (24, 24, 906, 1056)
OBSBOX = (930, 24, 1896, 24 + 44 + 540)
LOGBOX = (930, 620, 1896, 900)
CHATBOX = (930, 920, 1896, 1056)


def wrap(text, f, width):
    out, cur = [], ""
    for ch in text:
        if f.getlength(cur + ch) > width:
            out.append(cur)
            cur = "  " + ch if cur.startswith("  ") else ch
        else:
            cur += ch
    out.append(cur)
    return out


def pane(d, box, title):
    x0, y0, x1, y1 = box
    d.rectangle(box, fill=PANE)
    d.rectangle((x0, y0, x1, y0 + 44), fill=HEAD)
    d.text((x0 + 16, y0 + 6), title, font=TITLE, fill="#e6edf3")


def lines_until(t, panes):
    """時刻 t までに出た行 (端末のコマンドは打ちかけの途中まで)"""
    out = []
    for e in evs:
        if e["pane"] not in panes:
            continue
        rel = e["t"] - t_rec
        if e["pane"] == "cmd":
            start = rel - TYPE
            if t < start:
                break
            n = len(e["text"]) if t >= rel else int(len(e["text"]) * (t - start) / TYPE)
            out.append(("cmd", "$ " + e["text"][:n] + ("▌" if t < rel else "")))
        else:
            if rel > t:
                break
            out.append((e["pane"], e["text"]))
    return out


def render(t):
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    pane(d, TERM, "ターミナル (配信者が打つのはこれだけ)")
    pane(d, OBSBOX, "配信画面 (本物の OBS)")
    pane(d, LOGBOX, "WEAVE のログ")
    pane(d, CHATBOX, "チャット")

    # 端末: 下から詰めて、はみ出たら上に流す
    x0, y0, x1, y1 = TERM
    rows = []
    for kind, text in lines_until(t, ("cmd", "out", "note")):
        for r in wrap(text, MONO, x1 - x0 - 40):
            rows.append((kind, r))
        if kind == "cmd":
            pass
    lh = 31
    cap = (y1 - y0 - 64) // lh
    rows = rows[-cap:]
    y = y0 + 58
    for kind, r in rows:
        d.text((x0 + 20, y), r, font=MONO, fill=COL[kind])
        y += lh

    # ログ
    x0, y0, x1, y1 = LOGBOX
    rows = []
    for kind, text in lines_until(t, ("log",)):
        hot = "quarantined" in text or "restored" in text
        for r in wrap(text, MONO_S, x1 - x0 - 36):
            rows.append(("#f69d50" if hot else COL["log"], r))
    rows = rows[-((y1 - y0 - 60) // 29):]
    y = y0 + 56
    for c, r in rows:
        d.text((x0 + 18, y), r, font=MONO_S, fill=c)
        y += 29

    # チャット
    x0, y0, x1, y1 = CHATBOX
    msgs = [text for _, text in lines_until(t, ("chat",))][-2:]
    y = y0 + 54
    for m in msgs:
        d.text((x0 + 18, y), m, font=MONO, fill=COL["chat"])
        y += 36
    return im


frames_cmd = ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
              "-i", os.path.join(RUN, "obs_recording.mp4"),
              "-filter_complex", f"[1:v]fps={FPS},scale=960:540,trim=duration={DUR:.2f},setpts=PTS-STARTPTS[o];[0:v][o]overlay={OBSBOX[0] + 3}:{OBSBOX[1] + 44}:eof_action=repeat",
              "-t", f"{DUR:.2f}", "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-preset", "medium", "-movflags", "+faststart",
              os.path.join(RUN, "quickstart.mp4")]
p = subprocess.Popen(frames_cmd, stdin=subprocess.PIPE)
last_key, last_bytes = None, None
n = int(DUR * FPS)
for i in range(n):
    t = i / FPS
    key = tuple(lines_until(t, ("cmd", "out", "note", "log", "chat")))
    if key != last_key:
        last_bytes = render(t).tobytes()
        last_key = key
    p.stdin.write(last_bytes)
p.stdin.close()
p.wait()
print("wrote", os.path.join(RUN, "quickstart.mp4"), f"{DUR:.1f}s")
