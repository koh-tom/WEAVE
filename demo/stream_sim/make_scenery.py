#!/usr/bin/env python3
"""demo/stream_sim/make_scenery.py — 配信画面の背景 (風景) と、今どきの配信らしい表示パネルの画像を作る

  python3 demo/stream_sim/make_scenery.py            夕暮れの山の風景を描いて scenery.mp4 にする (外部の素材は使わない。雲がゆっくり流れる 20 秒のループ)
  python3 demo/stream_sim/make_scenery.py <写真か動画>  自分の写真・動画を背景にする (1280x720 に合わせて scenery.mp4 にする)
  どちらの場合も panels/*.png (角丸・半透明・影つきのパネル) を作る。出力: demo/output/stream_sim/media/
"""
import math, os, random, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MEDIA = os.path.join(ROOT, "demo", "output", "stream_sim", "media")
PANELS = os.path.join(MEDIA, "panels")
os.makedirs(PANELS, exist_ok=True)
W, H, FPS, SEC = 1280, 720, 30, 20
OUT = os.path.join(MEDIA, "scenery.mp4")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def landscape():
    """空 (夕暮れのグラデーション)・太陽・山 4 層・手前の丘と木"""
    stops = [(0.0, (22, 30, 66)), (0.45, (88, 74, 140)), (0.7, (214, 128, 122)), (0.86, (250, 190, 130)), (1.0, (252, 214, 160))]
    sky = Image.new("RGB", (W, H))
    px = sky.load()
    hy = int(H * 0.72)
    for y in range(H):
        t = min(y / hy, 1.0)
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                c = lerp(c0, c1, (t - t0) / (t1 - t0))
                break
        for x in range(W):
            px[x, y] = c
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    sx, sy = int(W * 0.68), int(H * 0.60)
    for r, a in [(260, 26), (170, 40), (100, 70)]:
        g.ellipse((sx - r, sy - r, sx + r, sy + r), fill=(255, 220, 170, a))
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    g = ImageDraw.Draw(glow)
    g.ellipse((sx - 46, sy - 46, sx + 46, sy + 46), fill=(255, 244, 214, 255))
    sky = Image.alpha_composite(sky.convert("RGBA"), glow)
    rnd = random.Random(7)
    d = ImageDraw.Draw(sky)
    layers = [(0.60, 70, (150, 120, 160)), (0.66, 90, (104, 88, 138)), (0.74, 80, (62, 58, 104)), (0.84, 60, (34, 36, 72))]
    for base, amp, col in layers:
        ph = [rnd.uniform(0, 6.28) for _ in range(4)]
        fr = [rnd.uniform(0.003, 0.006), rnd.uniform(0.008, 0.014), rnd.uniform(0.02, 0.03), rnd.uniform(0.05, 0.07)]
        pts = [(0, H)]
        for x in range(0, W + 8, 8):
            y = H * base - amp * (0.55 * math.sin(fr[0] * x + ph[0]) + 0.28 * math.sin(fr[1] * x + ph[1]) + 0.12 * math.sin(fr[2] * x + ph[2]) + 0.05 * math.sin(fr[3] * x + ph[3]))
            pts.append((x, y))
        pts.append((W, H))
        d.polygon(pts, fill=col)
    # 手前の丘と針葉樹
    pts = [(0, H)] + [(x, H * 0.93 - 26 * math.sin(0.004 * x + 1.0)) for x in range(0, W + 8, 8)] + [(W, H)]
    d.polygon(pts, fill=(16, 18, 40))
    for _ in range(46):
        x = rnd.randint(0, W)
        y0 = H * 0.93 - 26 * math.sin(0.004 * x + 1.0) + 6
        h = rnd.randint(38, 92)
        w = h * 0.36
        for k in range(3):
            ty = y0 - h + k * h * 0.26
            d.polygon([(x, ty), (x - w * (0.45 + 0.25 * k), ty + h * 0.48), (x + w * (0.45 + 0.25 * k), ty + h * 0.48)], fill=(12, 14, 32))
    return sky.convert("RGB")


def clouds(seed, n, y0, y1, alpha):
    """横にそのままつながる (幅 W でタイルできる) 雲の層"""
    rnd = random.Random(seed)
    im = Image.new("RGBA", (W * 3, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for _ in range(n):
        cx, cy = rnd.randint(0, W), rnd.randint(y0, y1)
        for _ in range(rnd.randint(4, 7)):
            ox, oy, rx, ry = rnd.randint(-110, 110), rnd.randint(-14, 14), rnd.randint(50, 130), rnd.randint(12, 26)
            for k in (0, 1, 2):
                d.ellipse((cx + ox - rx + k * W, cy + oy - ry, cx + ox + rx + k * W, cy + oy + ry), fill=(255, 226, 214, alpha))
    im = im.filter(ImageFilter.GaussianBlur(14))
    return im.crop((W, 0, 2 * W, H))


def render_generated():
    bg = landscape()
    layers = [(clouds(3, 7, 90, 300, 150), 1), (clouds(11, 5, 200, 400, 110), 2)]
    wide = [Image.new("RGBA", (W * 2, H), (0, 0, 0, 0)) for _ in layers]
    for wimg, (c, _) in zip(wide, layers):
        wimg.paste(c, (0, 0)); wimg.paste(c, (W, 0))
    p = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                          "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "medium", OUT], stdin=subprocess.PIPE)
    n = FPS * SEC
    for i in range(n):
        f = bg.convert("RGBA")
        for wimg, (_, laps) in zip(wide, layers):
            off = int(W * laps * i / n) % W
            f.alpha_composite(wimg.crop((off, 0, off + W, H)))
        p.stdin.write(np.asarray(f.convert("RGB")).tobytes())
    p.stdin.close(); p.wait()


def render_from(src):
    still = src.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))
    vf = f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},fps={FPS}"
    args = ["ffmpeg", "-loglevel", "error", "-y"] + (["-loop", "1", "-t", str(SEC)] if still else []) + ["-i", src, "-an", "-vf", vf,
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", OUT]
    subprocess.run(args, check=True)


# ---------------------------------------------------------------- パネル (角丸・半透明・影)
def font(size):
    for i in range(10):
        f = ImageFont.truetype("/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc", size, index=i)
        if f.getname()[0] == "Noto Sans CJK JP":
            return f


M = 28  # 影のぶんの余白


def panel(name, w, h, fill=(14, 17, 28, 190), accent=None, radius=None, bar="left"):
    r = radius if radius is not None else 20
    im = Image.new("RGBA", (w + 2 * M, h + 2 * M), (0, 0, 0, 0))
    sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((M, M + 6, M + w, M + h + 6), radius=r, fill=(0, 0, 0, 120))
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(12)))
    body = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((M, M, M + w, M + h), radius=r, fill=fill)
    if accent:
        a, b = accent
        grad = Image.new("RGBA", im.size, (0, 0, 0, 0))
        gp = grad.load()
        if bar == "left":
            for y in range(M, M + h):
                c = lerp(a, b, (y - M) / h)
                for x in range(M, M + 12):
                    gp[x, y] = (*c, 255)
        else:  # bottom
            for x in range(M, M + w):
                c = lerp(a, b, (x - M) / w)
                for y in range(M + h - 6, M + h):
                    gp[x, y] = (*c, 255)
        mask = Image.new("L", im.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((M, M, M + w, M + h), radius=r, fill=255)
        body.paste(grad, (0, 0), Image.composite(grad.split()[3], Image.new("L", im.size, 0), mask))
    im.alpha_composite(body)
    ImageDraw.Draw(im).rounded_rectangle((M, M, M + w, M + h), radius=r, outline=(255, 255, 255, 46), width=2)
    im.save(os.path.join(PANELS, name + ".png"))


def pill(name, w, h, col, text, dot=False):
    panel(name, w, h, fill=(*col, 235), radius=h // 2)
    p = os.path.join(PANELS, name + ".png")
    im = Image.open(p); d = ImageDraw.Draw(im)
    f = font(int(h * 0.52))
    tw = d.textlength(text, font=f)
    x = M + (w - tw) / 2 + (h * 0.22 if dot else 0)
    if dot:
        r = h * 0.17
        d.ellipse((x - h * 0.5 - r, M + h / 2 - r, x - h * 0.5 + r, M + h / 2 + r), fill=(255, 255, 255, 255))
    d.text((x, M + h / 2), text, font=f, fill=(255, 255, 255, 255), anchor="lm")
    im.save(p)


def panels():
    pill("live", 170, 56, (226, 40, 60), "LIVE", dot=True)
    panel("title", 500, 56, radius=28)
    panel("score", 440, 92, accent=((90, 200, 250), (160, 120, 255)), bar="bottom")
    panel("subgoal", 440, 72, accent=((255, 170, 90), (255, 90, 140)), bar="bottom")
    panel("card1", 1500, 112, accent=((60, 220, 150), (60, 180, 250)))
    panel("card2", 1200, 112, accent=((190, 120, 255), (255, 110, 170)))
    pill("tag_before", 560, 68, (198, 40, 40), "BEFORE：WEAVE なし")
    pill("tag_after", 560, 68, (40, 110, 220), "AFTER：WEAVE あり")


if __name__ == "__main__":
    render_from(sys.argv[1]) if len(sys.argv) > 1 else render_generated()
    panels()
    print("wrote", OUT, "and", PANELS)
