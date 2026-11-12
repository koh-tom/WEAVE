#!/usr/bin/env python3
"""demo/wrap/run.py — 既存ツールを WEAVE の下に置く前と後を、本物の OBS の配信画面で見比べて記録する

  既存ツール: demo/wrap/hype_bot.py (チャットのコマンドで画面を盛り上げる小さな Bot。WEAVE のことは知らない)
  BEFORE  Bot が OBS に直接つながっている
          1. !party            … 正常に動く
          2. !party をもう一度 … バグで止まらなくなり、画面の文字 (スコア・サブ目標・タイマー・帯) が壊れ続ける
          3. !takeover         … 更新に悪意あるコードが混ざった想定。番組名を書き換え、ゲーム画面を消し、配信を止めようとする
  ラップ  weave wrap add hype_bot (学習モード) → 普段どおり 1 回使う → weave wrap lock hype_bot
          Bot 側で変えるのは「接続先のポートとパスワード」だけ
  AFTER   同じ 1〜3 を、WEAVE (ObsGate :4456) 経由で
          2. 上限を超えた時点で Bot からの操作だけを止め、壊された表示を暴走前に戻す
          3. 宣言にない対象・操作は OBS に届かない

  記録 (demo/output/wrap_demo/run-<日時>/): shots/ (配信画面・OBS アプリ・Inspector・/status・ターミナル)、
  timeline.jsonl、audit.log、weave_*.log、bot_*.log。OBS の録画は demo/output/stream_sim/obs/
  すべてローカルの偽データ。外部のサービスにはつながない

  使い方: python3 demo/wrap/run.py   (前提: zig build、dashboard/dist、OBS 32、obs-websocket 有効、
                                      demo/stream_sim/make_media.sh と make_collection.py を実行済み)
"""
import json, os, re, shutil, signal, subprocess, sys, time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "demo", "stream_sim"))
from obsws import OBS  # noqa: E402

BIN = os.path.join(ROOT, "zig-out", "bin")
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT = os.path.join(ROOT, "demo", "output", "wrap_demo", f"run-{STAMP}")
SHOTS = os.path.join(OUT, "shots")
TOOLS = os.path.join(ROOT, "demo", "output", "stream_sim", "tools")
CHAT = os.path.join(OUT, "chat.jsonl")
WRAPDIR = os.path.join(OUT, ".weave", "wrap")
os.makedirs(SHOTS, exist_ok=True)
DASH, NODE, TOKEN, VIEW = 3034, 8084, "wrap-dash", "wrap-view"
MON = "WEAVE-SIM"
USERINI = os.path.expanduser("~/.config/obs-studio/user.ini")
PLUGINS = ["subgoal", "shoutout", "sfx"]
procs = {}
t0 = time.time()
tl = open(os.path.join(OUT, "timeline.jsonl"), "w")

DEFAULTS = {"OverlayText": "草 草 草 ！ チャットが盛り上がってます", "Scoreboard": "A 0 - 0 B", "SubGoal": "サブ  8 / 50",
            "Timer": "", "番組名": "WEAVE 杯 決勝 ― 実況配信"}


def now():
    return round(time.time() - t0, 2)


def mark(kind, text, **kw):
    e = {"t": now(), "kind": kind, "text": text, **kw}
    tl.write(json.dumps(e, ensure_ascii=False) + "\n")
    tl.flush()
    print(f"[{e['t']:7.2f}] {kind:9} {text}", flush=True)


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def chat(user, msg):
    with open(CHAT, "a", encoding="utf-8") as f:
        f.write(json.dumps({"user": user, "message": msg}, ensure_ascii=False) + "\n")
    mark("chat", f"{user}: {msg}")


def wait_log(path, pattern, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path) and re.search(pattern, open(path, errors="replace").read()):
            return True
        time.sleep(0.1)
    return False


# ------------------------------------------------------------------ 画面の記録
def shot_obs(name, label):
    try:
        OBS().shot("Overlay", os.path.join(SHOTS, f"{name}_program.png"), 1280)
    except Exception as e:
        mark("warn", f"OBS のスクショに失敗: {e}")
    app = os.path.join(SHOTS, f"{name}_obsapp.png")
    subprocess.run(["grim", "-o", MON, app], capture_output=True)
    try:
        from PIL import Image
        im = Image.open(app)
        im.crop((0, 48, im.width, im.height)).save(app)  # デスクトップのバーを切り落とす
    except Exception:
        pass
    mark("shot", label, file=f"{name}_program.png")


def shot_page(name, path, w, h, wait=2500):
    subprocess.run(["node", "page.mjs", f"http://127.0.0.1:{DASH}{path}", os.path.join(SHOTS, name), str(w), str(h), str(wait)],
                   cwd=TOOLS, capture_output=True)


def shot_inspector(name, label):
    shot_page(f"{name}_inspector.png", f"/?token={TOKEN}", 1440, 900, 3000)
    mark("shot", label, file=f"{name}_inspector.png")


def shot_status(name, label):
    shot_page(f"{name}_status.png", f"/status?token={VIEW}", 420, 860)
    mark("shot", label, file=f"{name}_status.png")


def term_png(name, lines, title="terminal"):
    """コマンドの出力を、ターミナル風の画像にする (スライド用)"""
    from PIL import Image, ImageDraw, ImageFont
    path = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc"
    font = None
    for idx in range(10):
        try:
            f = ImageFont.truetype(path, 30, index=idx)
        except Exception:
            break
        if f.getname()[0] == "Noto Sans Mono CJK JP":
            font = f
            break
    font = font or ImageFont.truetype(path, 30)
    W = 1680
    H = 90 + 46 * len(lines) + 40
    im = Image.new("RGB", (W, H), "#1e2227")
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, W, 64), fill="#2c313a")
    for i, c in enumerate(["#e5534b", "#c69026", "#57ab5a"]):
        d.ellipse((24 + i * 40, 20, 48 + i * 40, 44), fill=c)
    d.text((150, 14), title, font=font, fill="#adbac7")
    y = 90
    for ln in lines:
        color = "#8ddb8c" if ln.startswith("$") else ("#f69d50" if "(要注意)" in ln or "(強い権限)" in ln else "#e6edf3")
        d.text((40, y), ln, font=font, fill=color)
        y += 46
    im.save(os.path.join(SHOTS, name))
    mark("shot", f"ターミナル: {lines[0]}", file=name)


def cli(args, label_file=None):
    """weave CLI を OUT で実行する (.weave/wrap は OUT の下にできる)。出力をターミナル画像にもする"""
    r = run([f"{BIN}/weave", *args], cwd=OUT)
    out = (r.stdout + r.stderr).rstrip("\n")
    shown = re.sub(r"(パスワード\s+)\S+", r"\1(ツールごとに自動で作られます)", out)
    if label_file:
        term_png(label_file, ["$ weave " + " ".join(a for a in args if a != "--yes")] + shown.splitlines())
    return out


# ------------------------------------------------------------------ 起動と片付け
def start_obs():
    shutil.copy(USERINI, USERINI + ".wrap-bak")
    s = open(USERINI).read()
    s = re.sub(r"^(ConfirmOnExit|WarnBeforeStoppingRecord|WarnBeforeStartingRecord)=.*\n?", "", s, flags=re.M)
    s = s.replace("[General]\n", "[General]\nConfirmOnExit=false\nWarnBeforeStoppingRecord=false\nWarnBeforeStartingRecord=false\n", 1)
    open(USERINI, "w").write(s)
    subprocess.run(["hyprctl", "output", "remove", MON], capture_output=True)
    subprocess.run(["hyprctl", "output", "create", "headless", MON], capture_output=True)
    subprocess.run(["hyprctl", "keyword", "monitor", f"{MON},1920x1080@30,22000x0,1.5"], capture_output=True)
    time.sleep(0.8)
    ws = next(m["activeWorkspace"]["id"] for m in json.loads(run(["hyprctl", "monitors", "all", "-j"]).stdout) if m["name"] == MON)
    procs["obs"] = subprocess.Popen(["obs", "--collection", "WEAVE-stream", "--profile", "WEAVE-stream", "--scene", "Overlay",
                                     "--disable-shutdown-check", "--startrecording"],
                                    stdout=open(os.path.join(OUT, "obs.log"), "w"), stderr=subprocess.STDOUT)
    addr = None
    for _ in range(100):
        for c in json.loads(run(["hyprctl", "clients", "-j"]).stdout):
            if c.get("class") == "com.obsproject.Studio" and c.get("title", "").startswith("OBS"):
                addr = c["address"]
        if addr:
            break
        time.sleep(0.2)
    subprocess.run(["hyprctl", "dispatch", "movetoworkspacesilent", f"{ws},address:{addr}"], capture_output=True)
    for _ in range(100):
        try:
            OBS().call("GetVersion")
            break
        except Exception:
            time.sleep(0.2)
    time.sleep(2)
    mark("system", "本物の OBS を起動 (録画開始)", version=OBS().call("GetVersion").get("obsVersion"))


def obs_cfg():
    return json.load(open(os.path.expanduser("~/.config/obs-studio/plugin_config/obs-websocket/config.json")))


def start_weave(tag):
    cfg = obs_cfg()
    args = [f"{BIN}/weave", "up", "--real-obs", "--obs-port", str(cfg.get("server_port", 4455)), "--obs-pass", cfg.get("server_password", ""),
            "--no-twitch", "--dash-port", str(DASH), "--node-port", str(NODE), "--dashboard-token", TOKEN, "--observer-token", VIEW,
            "--audit-log", os.path.join(OUT, "audit.log"), "--state-dir", os.path.join(OUT, "state"),
            "--wrap-dir", WRAPDIR] + [f"wasm-apps/{p}.wasm" for p in PLUGINS]
    log = os.path.join(OUT, f"weave_{tag}.log")
    procs["weave"] = subprocess.Popen(args, cwd=ROOT, stdout=open(log, "w"), stderr=subprocess.STDOUT, start_new_session=True)
    wait_log(log, r"Ready in \d+ ms", 20)
    wait_log(log, "identified with OBS", 10)
    mark("system", f"WEAVE を起動 ({tag})")
    return log


def start_bot(tag, via_weave):
    args = [sys.executable, os.path.join(HERE, "hype_bot.py"), "--chat", CHAT, "--max-seconds", "8"]
    if via_weave:
        spec = json.load(open(os.path.join(WRAPDIR, "hype_bot.json")))
        args += ["--port", "4456", "--password", spec["password"]]
    log = os.path.join(OUT, f"bot_{tag}.log")
    procs["bot"] = subprocess.Popen(args, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    wait_log(log, "connected to OBS", 10)
    mark("system", f"hype_bot を起動 ({'WEAVE 経由 :4456' if via_weave else 'OBS に直接 :4455'})")


def stop(name, sig=signal.SIGINT, timeout=8):
    p = procs.pop(name, None)
    if not p:
        return
    try:
        os.killpg(p.pid, sig) if name == "weave" else p.send_signal(sig)
        p.wait(timeout=timeout)
    except Exception:
        try:
            os.killpg(p.pid, signal.SIGKILL) if name == "weave" else p.kill()
        except Exception:
            pass


def cleanup():
    for n in ["bot", "weave"]:
        stop(n)
    stop("obs", signal.SIGINT, 20)
    if os.path.exists(USERINI + ".wrap-bak"):
        shutil.move(USERINI + ".wrap-bak", USERINI)
    subprocess.run(["hyprctl", "output", "remove", MON], capture_output=True)


def tag(which):
    o = OBS()
    o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 20, "sceneItemEnabled": which == "before"})
    o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 21, "sceneItemEnabled": which == "after"})


def reset_screen():
    """BEFORE で壊れた画面を、手で元に戻す (WEAVE が無いと人がやるしかない)"""
    o = OBS()
    for name, text in DEFAULTS.items():
        o.call("SetInputSettings", {"inputName": name, "inputSettings": {"text": text}})
    o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 1, "sceneItemEnabled": False})
    o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 3, "sceneItemEnabled": True})
    mark("op", "壊れた画面を手で元に戻す")


def screen_texts():
    o = OBS()
    return {n: o.call("GetInputSettings", {"inputName": n})["inputSettings"].get("text", "") for n in DEFAULTS}


def main():
    open(CHAT, "w").close()
    try:
        start_obs()
        reset_screen()

        # ---------------------------------------------------------- BEFORE
        tag("before")
        mark("system", "BEFORE: hype_bot が OBS に直接つながっている")
        start_bot("before", via_weave=False)
        time.sleep(2)
        chat("kumo_23", "!party")
        time.sleep(1.2)
        shot_obs("b1_party", "BEFORE: !party は正常に動く")
        chat("nyanta", "!party")
        mark("incident", "BEFORE: パーティー中の 2 回目の !party → Bot がバグで止まらなくなる")
        time.sleep(1.8)
        shot_obs("b2_runaway", "BEFORE: スコア・サブ目標・タイマー・帯の文字が壊れ続ける")
        time.sleep(7.5)
        texts = screen_texts()
        mark("observe", "BEFORE: Bot が止まった後も画面は壊れたまま", texts=texts)
        shot_obs("b3_left_broken", "BEFORE: Bot が止まっても、壊れた表示はそのまま残る")
        time.sleep(1)
        reset_screen()
        time.sleep(1.5)
        chat("mallory", "!takeover")
        mark("incident", "BEFORE: 悪意ある更新 → 番組名の書き換え・ゲーム画面を消す・配信停止を試みる")
        time.sleep(1.5)
        shot_obs("b4_takeover", "BEFORE: 番組名が書き換えられ、ゲーム画面が消える")
        time.sleep(2)
        stop("bot")
        reset_screen()

        # ---------------------------------------------------------- ラップ (学習 → 宣言)
        mark("system", "ラップ: weave wrap add hype_bot (学習モード)")
        cli(["wrap", "add", "hype_bot", "--yes"], "term_wrap_add.png")
        start_weave("learn")
        start_bot("learn", via_weave=True)
        time.sleep(1.5)
        chat("kumo_23", "!party")
        time.sleep(4.5)
        stop("bot")
        cli(["wrap", "lock", "hype_bot", "--yes"], "term_wrap_lock.png")
        mark("system", "学習した操作だけを許す宣言にした", spec=json.load(open(os.path.join(WRAPDIR, "hype_bot.json")))["allow"])
        stop("weave")
        time.sleep(1)

        # ---------------------------------------------------------- AFTER
        start_weave("after")
        tag("after")
        mark("system", "AFTER: hype_bot は WEAVE (:4456) 経由。Bot で変えたのは接続先のポートとパスワードだけ")
        start_bot("after", via_weave=True)
        time.sleep(2)
        chat("kumo_23", "!party")
        time.sleep(1.2)
        shot_obs("a1_party", "AFTER: !party は WEAVE 経由でも普段どおり動く")
        chat("nyanta", "!party")
        mark("incident", "AFTER: 同じバグで Bot が止まらなくなる")
        time.sleep(1.8)
        shot_obs("a2_runaway", "AFTER: 上限を超えた時点で Bot だけを止め、表示を暴走前に戻した")
        texts = screen_texts()
        mark("observe", "AFTER: 配信画面の文字", texts=texts)
        shot_inspector("a2", "AFTER: Inspector — hype_bot を止めた理由と、止めた操作")
        shot_status("a2", "AFTER: /status — 止めている理由")
        time.sleep(9)
        chat("mallory", "!takeover")
        mark("incident", "AFTER: 同じ悪意ある更新")
        time.sleep(1.5)
        shot_obs("a3_takeover", "AFTER: 宣言にない対象・操作は OBS に届かず、画面はそのまま")
        shot_inspector("a3", "AFTER: Inspector — 止めた操作 (番組名・ゲーム画面・配信停止)")
        time.sleep(1)
        stop("bot")
        cli(["wrap", "show", "hype_bot"], "term_wrap_show.png")
        st = OBS().call("GetStats")
        json.dump({"obs": st, "record": OBS().call("GetRecordStatus")}, open(os.path.join(OUT, "stats.json"), "w"), ensure_ascii=False, indent=1)
        mark("system", "おわり")
    finally:
        try:
            shutil.copy(os.path.join(WRAPDIR, "hype_bot.json"), os.path.join(OUT, "hype_bot.wrap.json"))
            # パスワードは記録に残さない
            j = json.load(open(os.path.join(OUT, "hype_bot.wrap.json")))
            j["password"] = "(redacted)"
            json.dump(j, open(os.path.join(OUT, "hype_bot.wrap.json"), "w"), ensure_ascii=False, indent=1)
        except Exception:
            pass
        cleanup()
        time.sleep(1)
        recs = sorted([f for f in os.listdir(os.path.join(ROOT, "demo", "output", "stream_sim", "obs")) if f.endswith((".mp4", ".mkv"))])
        print("OBS の録画:", recs[-1] if recs else "(なし)")
        print("記録:", OUT)


if __name__ == "__main__":
    main()
