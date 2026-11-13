#!/usr/bin/env python3
"""demo/booth/compose.py — run.py の素材を、展示用のデモ動画 1 本にする (第 3 回と同じ横長 + 下に字幕帯)

  python3 demo/booth/compose.py demo/output/booth/run-<日時>
  出力: <記録>/weave_booth_demo.mp4 (2560x900, 30fps, 無音・ループ再生向け)
    0〜4 秒        タイトル
    本編          左 = OBS が描いた配信画面 (OBS 自身の録画) / 右 = BEFORE は説明カード、AFTER は Inspector / 下 = 字幕
    最後 8 秒      入れてから使うまで (コマンド) と GitHub
"""
import glob, json, os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

RUN = os.path.abspath(sys.argv[1])
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
W, H, VH, FPS = 2560, 900, 720, 30
WORK = os.path.join(RUN, "compose"); os.makedirs(WORK, exist_ok=True)
BOLD = "/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc"
REG = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc"
QR = "/home/koh/selection/WEAVE_docs/poster_offline3/assets/qr_github.png"


def font(path, size, mono=False):
    want = "Noto Sans Mono CJK JP" if mono else "Noto Sans CJK JP"
    for i in range(10):
        f = ImageFont.truetype(path, size, index=i)
        if f.getname()[0] == want:
            return f
    return ImageFont.truetype(path, size)


def run(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def center(d, y, text, f, fill, w=W):
    d.text(((w - d.textlength(text, font=f)) / 2, y), text, font=f, fill=fill)


# ---------------------------------------------------------------- カード
def card_title(path):
    im = Image.new("RGB", (W, H), "#ffffff"); d = ImageDraw.Draw(im)
    center(d, 230, "WEAVE", font(BOLD, 190), "#1f3a5f")
    center(d, 470, "ライブ配信・イベントをセキュアに統合するミドルウェア", font(BOLD, 64), "#222222")
    center(d, 600, "壊れても・乗っ取られても、影響範囲がすぐ分かる", font(REG, 52), "#222222")
    im.save(path)


def card_before(path):
    im = Image.new("RGB", (1280, VH), "#f3f4f6"); d = ImageDraw.Draw(im)
    d.rectangle((0, 0, 1280, 120), fill="#c62828")
    center(d, 20, "WEAVE なし", font(BOLD, 64), "#ffffff", 1280)
    y = 210
    for t in ["ツールが OBS に直接つながっている", "", "何が起きているか、外からは見えない", "", "壊れても、どこが原因か分からない"]:
        if t:
            center(d, y, t, font(BOLD, 48), "#222222", 1280)
        y += 80
    im.save(path)


def card_end(path):
    im = Image.new("RGB", (W, H), "#ffffff"); d = ImageDraw.Draw(im)
    d.text((140, 80), "コマンド 3 つで動かせる　＋　既存ツールもそのまま", font=font(BOLD, 72), fill="#1f3a5f")
    mono, lab = font(REG, 54, True), font(REG, 44)
    rows = [("$ weave add subgoal.wasm", "権限を見て承認"),
            ("$ weave audit subgoal", "乗っ取られたら・止まったら、届く範囲を確かめる"),
            ("$ weave up --real-obs", "起動 (落ちてもすぐ起動し直す)"),
            ("$ weave wrap add <ツール>", "いま使っているツールは、接続先を変えるだけ")]
    y = 250
    for c, t in rows:
        d.rounded_rectangle((140, y - 10, 1080, y + 76), radius=10, fill="#f6f6f6", outline="#cccccc")
        d.text((170, y), c, font=mono, fill="#222222")
        d.text((1130, y + 8), t, font=lab, fill="#222222")
        y += 120
    q = Image.open(QR).convert("RGB").resize((200, 200), Image.NEAREST)
    im.paste(q, (W - 380, H - 290))
    d.text((W - 1060, H - 210), "github.com/koh-tom/WEAVE", font=font(REG, 50, True), fill="#222222")
    im.save(path)


title, before, end = os.path.join(WORK, "title.png"), os.path.join(WORK, "before.png"), os.path.join(WORK, "end.png")
card_title(title); card_before(before); card_end(end)

# ---------------------------------------------------------------- 時刻
evs = [json.loads(l) for l in open(os.path.join(RUN, "events.jsonl"), encoding="utf-8")]
rec0 = next(e["ms"] for e in evs if e["kind"] == "rec_start")
t_end = (next(e["ms"] for e in evs if e["kind"] == "end") - rec0) / 1000 + 1.0
t_insp = (next(e["ms"] for e in evs if e["kind"] == "right" and e["mode"] == "inspector") - rec0) / 1000
caps = [((e["ms"] - rec0) / 1000, e["text"]) for e in evs if e["kind"] == "cap"]

# Inspector のスクショ列 → 動画 (撮った時刻どおりの長さで並べる)
frames = sorted(glob.glob(os.path.join(RUN, "insp", "*.png")), key=lambda p: int(os.path.basename(p)[:-4]))
lst = os.path.join(WORK, "insp.txt")
with open(lst, "w") as f:
    for a, b in zip(frames, frames[1:] + [None]):
        ta = int(os.path.basename(a)[:-4])
        dur = ((int(os.path.basename(b)[:-4]) if b else ta + 200) - ta) / 1000
        f.write(f"file '{a}'\nduration {dur:.3f}\n")
    f.write(f"file '{frames[-1]}'\n")
insp0 = (int(os.path.basename(frames[0])[:-4]) - rec0) / 1000
insp_mp4 = os.path.join(WORK, "insp.mp4")
run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-vf", f"scale=1280:720,fps={FPS}", "-c:v", "libx264", "-pix_fmt", "yuv420p", insp_mp4])


# 字幕 (ASS、下の帯に全幅で)
def ts(x):
    h, r = divmod(max(x, 0), 3600); m, s = divmod(r, 60)
    return f"{int(h)}:{int(m):02d}:{s:05.2f}"


ass = os.path.join(WORK, "cap.ass")
with open(ass, "w", encoding="utf-8") as f:
    f.write("[Script Info]\nScriptType: v4.00+\nPlayResX: 2560\nPlayResY: 900\nWrapStyle: 0\n\n[V4+ Styles]\n"
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
            "Style: Default,Noto Sans CJK JP,58,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,0,0,2,80,80,58,1\n\n"
            "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
    for (a, t), nxt in zip(caps, caps[1:] + [(t_end, "")]):
        f.write(f"Dialogue: 0,{ts(a)},{ts(nxt[0])},Default,,0,0,0,,{t}\n")

# ---------------------------------------------------------------- 本編
main = os.path.join(WORK, "main.mp4")
fc = (f"color=c=black:s={W}x{H}:r={FPS}:d={t_end:.2f}[bg];"
      f"[0:v]fps={FPS},scale=1280:720,setpts=PTS-STARTPTS[obs];"
      f"[1:v]scale=1280:720[bc];"
      f"[2:v]setpts=PTS-STARTPTS+{insp0:.3f}/TB[ins];"
      f"[bg][obs]overlay=0:0:eof_action=repeat[a];"
      f"[a][bc]overlay=1280:0:enable='lt(t,{t_insp:.2f})'[b];"
      f"[b][ins]overlay=1280:0:enable='gte(t,{t_insp:.2f})':eof_action=repeat[c];"
      f"[c]ass={ass}")
run(["ffmpeg", "-y", "-i", os.path.join(RUN, "obs.mp4"), "-loop", "1", "-i", before, "-i", insp_mp4,
     "-filter_complex", fc, "-t", f"{t_end:.2f}", "-r", str(FPS), "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", main])


def still(png, sec, out):
    run(["ffmpeg", "-y", "-loop", "1", "-i", png, "-t", str(sec), "-r", str(FPS), "-vf", f"scale={W}:{H}",
         "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", out])


still(title, 4, os.path.join(WORK, "title.mp4"))
still(end, 8, os.path.join(WORK, "end.mp4"))
cl = os.path.join(WORK, "all.txt")
open(cl, "w").write("".join(f"file '{os.path.join(WORK, n)}'\n" for n in ["title.mp4", "main.mp4", "end.mp4"]))
out = os.path.join(RUN, "weave_booth_demo.mp4")
run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", cl, "-c", "copy", "-movflags", "+faststart", out])
print("wrote", out)
