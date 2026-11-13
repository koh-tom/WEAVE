#!/usr/bin/env python3
"""demo/wrap/run_quickstart.py — 配信者が「入れてから使うまで」をコマンドだけで行う様子を、本物の OBS で記録する

  1. weave setup                OBS の WebSocket 設定を読み取り、つながるか確かめる
  2. weave wrap add hype_bot    いま使っている既存ツール (hype_bot) を WEAVE の下に置く (学習モード)
  3. (hype_bot の接続先を 4456 に変える)
  4. weave up                   WEAVE を起動
  5. hype_bot を起動 → !party   普段どおりに使う (使った操作を学習)
  6. weave wrap lock hype_bot   使った操作だけを許す宣言にする (起動し直さずに効く)
  7. !party を 2 回             hype_bot のバグで止まらなくなる → WEAVE が hype_bot だけを止め、表示を戻す

  記録: demo/output/wrap_demo/quick-<日時>/ (session.jsonl = 端末に出たもの・ログ・チャットの時刻つき記録、
        OBS の録画 = demo/output/stream_sim/obs/)。続けて compose_quickstart.py で 1 本の動画にする
  すべてローカルの偽データ。外部のサービスにはつながない (Twitch も切る)
"""
import json, os, re, shutil, signal, subprocess, sys, threading, time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "demo", "stream_sim"))
from obsws import OBS  # noqa: E402

BIN = os.path.join(ROOT, "zig-out", "bin")
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT = os.path.join(ROOT, "demo", "output", "wrap_demo", f"quick-{STAMP}")
os.makedirs(OUT, exist_ok=True)
CHAT = os.path.join(OUT, "chat.jsonl")
MON = "WEAVE-SIM"
USERINI = os.path.expanduser("~/.config/obs-studio/user.ini")
DEFAULTS = {"OverlayText": "草 草 草 ！ チャットが盛り上がってます", "Scoreboard": "A 0 - 0 B", "SubGoal": "サブ  8 / 50",
            "Timer": "", "番組名": "WEAVE 杯 決勝 ― 実況配信"}
procs = {}
t0 = time.time()
sess = open(os.path.join(OUT, "session.jsonl"), "w")
lock = threading.Lock()
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def ev(pane, text, **kw):
    with lock:
        sess.write(json.dumps({"t": round(time.time() - t0, 3), "pane": pane, "text": text, **kw}, ensure_ascii=False) + "\n")
        sess.flush()
    print(f"[{time.time() - t0:6.2f}] {pane:5} {text}", flush=True)


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def mask(s):
    s = s.replace(os.path.expanduser("~"), "~")
    return re.sub(r"(パスワード\s+)\S+", r"\1••••••••••", s)


def cmd(shown, args, pause=1.2):
    """端末に打ったように見せる。shown が画面に出すコマンド、args が実際に実行するもの"""
    time.sleep(pause)
    ev("cmd", shown)
    r = run(args, cwd=OUT)
    for line in (r.stdout + r.stderr).rstrip("\n").splitlines():
        ev("out", mask(line))
    return r


def note(text, pause=1.0):
    time.sleep(pause)
    ev("note", text)


def chat(user, msg):
    with open(CHAT, "a", encoding="utf-8") as f:
        f.write(json.dumps({"user": user, "message": msg}, ensure_ascii=False) + "\n")
    ev("chat", f"{user}: {msg}")


def tail_log(path, keep):
    """weave up のログから、見せたい行だけを流す"""
    pos = 0
    while procs.get("weave"):
        try:
            with open(path, errors="replace") as f:
                f.seek(pos)
                for line in f:
                    pos += len(line.encode("utf-8", "replace"))
                    s = ANSI.sub("", line).strip()
                    if any(k in s for k in keep):
                        s = re.sub(r"^\[(INFO|WARN|ERROR)\]\s*", "", s)
                        ev("log", s)
        except FileNotFoundError:
            pass
        time.sleep(0.05)


def start_obs():
    shutil.copy(USERINI, USERINI + ".quick-bak")
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
                                     "--disable-shutdown-check"], stdout=open(os.path.join(OUT, "obs.log"), "w"), stderr=subprocess.STDOUT)
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


def reset_screen():
    o = OBS()
    for name, text in DEFAULTS.items():
        o.call("SetInputSettings", {"inputName": name, "inputSettings": {"text": text}})
    for iid, on in [(1, False), (3, True), (20, False), (21, False)]:
        o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": iid, "sceneItemEnabled": on})


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


def main():
    open(CHAT, "w").close()
    # 配信者の手元にある設定 (画面には出さない): Twitch は使わない・プラグイン 3 つ・Inspector の場所
    json.dump({"no_twitch": True, "dashboard_dist": os.path.join(ROOT, "dashboard", "dist"),
               "audit_log_path": os.path.join(OUT, "audit.log"),
               "plugins": [os.path.join(ROOT, "wasm-apps", f"{p}.wasm") for p in ["subgoal", "shoutout", "sfx"]]},
              open(os.path.join(OUT, "weave.json"), "w"), ensure_ascii=False, indent=2)
    try:
        start_obs()
        reset_screen()
        OBS().call("StartRecord")
        ev("system", "録画開始", rec_start=True)
        W = f"{BIN}/weave"

        cmd("weave setup", [W, "setup"], pause=1.5)
        cmd("weave wrap add hype_bot", [W, "wrap", "add", "hype_bot", "--yes"], pause=2.5)
        note("# hype_bot (既存ツール) の OBS 接続先を 4456 と表示されたパスワードに変える", pause=2.5)

        time.sleep(1.5)
        ev("cmd", "weave up &")
        log = os.path.join(OUT, "weave.log")
        procs["weave"] = subprocess.Popen([W, "up"], cwd=OUT, stdout=open(log, "w"), stderr=subprocess.STDOUT, start_new_session=True)
        threading.Thread(target=tail_log, args=(log, ["Ready in", "identified with OBS", "ObsGate", "Loaded plugin"]), daemon=True).start()
        for _ in range(100):
            if os.path.exists(log) and "ObsGate: listening" in open(log, errors="replace").read():
                break
            time.sleep(0.1)
        time.sleep(1.0)

        spec = json.load(open(os.path.join(OUT, ".weave", "wrap", "hype_bot.json")))
        time.sleep(1.2)
        ev("cmd", "python3 hype_bot.py --port 4456 --password ••••••••••")
        blog = os.path.join(OUT, "bot.log")
        procs["bot"] = subprocess.Popen([sys.executable, os.path.join(HERE, "hype_bot.py"), "--chat", CHAT, "--max-seconds", "8",
                                         "--port", "4456", "--password", spec["password"]], stdout=open(blog, "w"), stderr=subprocess.STDOUT)
        for _ in range(100):
            if os.path.exists(blog) and "connected" in open(blog).read():
                break
            time.sleep(0.1)
        ev("out", "[hype_bot] connected to OBS on port 4456")

        time.sleep(2.0)
        note("# 普段どおりに使う (WEAVE が使った操作を覚える)", pause=0.3)
        time.sleep(1.0)
        chat("kumo_23", "!party")
        time.sleep(4.5)

        cmd("weave wrap lock hype_bot", [W, "wrap", "lock", "hype_bot", "--yes"], pause=0.8)
        time.sleep(2.5)
        note("# ここで hype_bot のバグを踏む (パーティー中にもう一度 !party)", pause=0.3)
        time.sleep(1.0)
        chat("kumo_23", "!party")
        time.sleep(1.5)
        chat("nyanta", "!party")
        time.sleep(9.0)
        ev("system", "おわり")
        OBS().call("StopRecord")
        time.sleep(1.5)
    finally:
        stop("bot")
        stop("weave")
        stop("obs", signal.SIGINT, 20)
        if os.path.exists(USERINI + ".quick-bak"):
            shutil.move(USERINI + ".quick-bak", USERINI)
        subprocess.run(["hyprctl", "output", "remove", MON], capture_output=True)
        recs = sorted([f for f in os.listdir(os.path.join(ROOT, "demo", "output", "stream_sim", "obs")) if f.endswith((".mp4", ".mkv"))])
        if recs:
            shutil.copy(os.path.join(ROOT, "demo", "output", "stream_sim", "obs", recs[-1]), os.path.join(OUT, "obs_recording.mp4"))
        print("記録:", OUT)


if __name__ == "__main__":
    main()
