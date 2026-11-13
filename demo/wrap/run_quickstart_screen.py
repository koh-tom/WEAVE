#!/usr/bin/env python3
"""demo/wrap/run_quickstart_screen.py — 「入れてから使うまで」を、手元の画面に WezTerm (左) と OBS (右) を並べてそのまま録画する

  空のワークスペース (weave-demo) に切り替えて WezTerm と本物の OBS を左右に並べ、WezTerm の中でコマンドを実際に打って実行する (tmux send-keys で 1 文字ずつ)。
  画面は wf-recorder でそのまま録る。合成や作り直しはしない
    weave setup → weave wrap add hype_bot (y で承認) → weave up (下のペイン) → hype_bot を 4456 で起動
    → チャットの !party (普段どおり) → weave wrap lock hype_bot (y) → !party を 2 回 (バグ) → WEAVE が hype_bot だけ止める
  録画中は通知を止める (mako の do-not-disturb)。終わったら元のワークスペースに戻す。録画中は PC を触らないこと
  作業フォルダは /tmp/weave-demo (画面に自分のホームの場所が出ないように)。チャットはローカルのファイルに書く偽データ

  出力: demo/output/wrap_demo/raw-<日時>/quickstart_raw.mp4
"""
import json, os, shutil, signal, subprocess, sys, time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "demo", "stream_sim"))
from obsws import OBS  # noqa: E402

STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT = os.path.join(ROOT, "demo", "output", "wrap_demo", f"screen-{STAMP}")
WD = "/tmp/weave-demo"
MON = "eDP-1"
USERINI = os.path.expanduser("~/.config/obs-studio/user.ini")
T = ["tmux", "-L", "weavedemo"]
WS = "name:weave-demo"
DEFAULTS = {"OverlayText": "草 草 草 ！ チャットが盛り上がってます", "Scoreboard": "A 0 - 0 B", "SubGoal": "サブ  8 / 50",
            "Timer": "", "番組名": "WEAVE 杯 決勝 ― 実況配信"}
procs = {}


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def clients():
    return json.loads(run(["hyprctl", "clients", "-j"]).stdout)


def wait_window(pred, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        for c in clients():
            if pred(c):
                return c["address"]
        time.sleep(0.2)
    raise RuntimeError("window did not appear")


def type_(target, text, cps=22, enter=True):
    for ch in text:
        run(T + ["send-keys", "-t", target, "-l", ch])
        time.sleep(1 / cps)
    if enter:
        time.sleep(0.25)
        run(T + ["send-keys", "-t", target, "Enter"])


def chat(user, msg):
    with open(os.path.join(WD, "chat.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"user": user, "message": msg}, ensure_ascii=False) + "\n")


def pane_text(target):
    return run(T + ["capture-pane", "-p", "-t", target, "-S", "-200"]).stdout


def main():
    os.makedirs(OUT, exist_ok=True)
    shutil.rmtree(WD, ignore_errors=True)
    os.makedirs(os.path.join(WD, "xdg", "obs-studio", "plugin_config", "obs-websocket"))
    shutil.copy(os.path.expanduser("~/.config/obs-studio/plugin_config/obs-websocket/config.json"),
                os.path.join(WD, "xdg", "obs-studio", "plugin_config", "obs-websocket", "config.json"))
    for f in ["hype_bot.py"]:
        shutil.copy(os.path.join(HERE, f), WD)
    shutil.copy(os.path.join(ROOT, "demo", "stream_sim", "obsws.py"), WD)
    open(os.path.join(WD, "chat.jsonl"), "w").close()
    # 配信者の手元の設定 (画面には出さない): Twitch は使わない・プラグイン 3 つ・Inspector の場所
    json.dump({"no_twitch": True, "dashboard_dist": os.path.join(ROOT, "dashboard", "dist"),
               "plugins": [os.path.join(ROOT, "wasm-apps", f"{p}.wasm") for p in ["subgoal", "shoutout", "sfx"]]},
              open(os.path.join(WD, "weave.json"), "w"), indent=2)
    rc = os.path.join(WD, ".bashrc")
    open(rc, "w").write(f"set +H\nPS1='$ '\nexport PATH={ROOT}/zig-out/bin:$PATH\nexport XDG_CONFIG_HOME={WD}/xdg\nclear\n")

    shutil.copy(USERINI, USERINI + ".raw-bak")
    try:
        s = open(USERINI).read()
        import re
        s = re.sub(r"^(ConfirmOnExit|WarnBeforeStoppingRecord|WarnBeforeStartingRecord)=.*\n?", "", s, flags=re.M)
        open(USERINI, "w").write(s.replace("[General]\n", "[General]\nConfirmOnExit=false\n", 1))
        orig_ws = json.loads(run(["hyprctl", "activeworkspace", "-j"]).stdout)["id"]
        procs["orig_ws"] = orig_ws
        run(["makoctl", "mode", "-a", "do-not-disturb"])
        run(["hyprctl", "dispatch", "workspace", WS])
        time.sleep(0.5)
        ws = WS
        # 左: WezTerm (中は tmux。コマンドは send-keys で実際に打つ)
        run(T + ["kill-server"])
        run(T + ["-f", "/dev/null", "new-session", "-d", "-s", "demo", "-x", "100", "-y", "40", "-c", WD,
                 f"bash --rcfile {rc} -i"])
        run(T + ["set", "-g", "status", "off"])
        run(T + ["set", "-g", "pane-border-style", "fg=colour240"])
        run(T + ["set", "-g", "pane-active-border-style", "fg=colour240"])
        procs["wez"] = subprocess.Popen(["wezterm", "-n", "--config", "font_size=11", "--config", "enable_tab_bar=false",
                                         "--config", "window_close_confirmation='NeverPrompt'",
                                         "start", "--always-new-process", "--class", "weave-demo", "--",
                                         *T, "attach", "-t", "demo"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wez = wait_window(lambda c: c.get("class") == "weave-demo")
        run(["hyprctl", "dispatch", "movetoworkspacesilent", f"{ws},address:{wez}"])
        procs["wez_addr"] = wez
        time.sleep(0.5)
        # 右: 本物の OBS
        procs["obs"] = subprocess.Popen(["obs", "--collection", "WEAVE-stream", "--profile", "WEAVE-stream", "--scene", "Overlay",
                                         "--disable-shutdown-check"], stdout=open(os.path.join(OUT, "obs.log"), "w"), stderr=subprocess.STDOUT)
        obs = wait_window(lambda c: c.get("class") == "com.obsproject.Studio" and c.get("title", "").startswith("OBS"), 40)
        run(["hyprctl", "dispatch", "movetoworkspacesilent", f"{ws},address:{obs}"])
        time.sleep(0.5)
        run(["hyprctl", "dispatch", "focuswindow", f"address:{wez}"])
        run(["hyprctl", "dispatch", "splitratio", "exact", "0.9"])  # 左 (端末) 45% : 右 (OBS) 55%
        for _ in range(100):
            try:
                OBS().call("GetVersion")
                break
            except Exception:
                time.sleep(0.2)
        o = OBS()
        for name, text in DEFAULTS.items():
            o.call("SetInputSettings", {"inputName": name, "inputSettings": {"text": text}})
        for iid, on in [(1, False), (3, True), (20, False), (21, False)]:
            o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": iid, "sceneItemEnabled": on})
        time.sleep(2.5)

        # 録る前に確かめる: いま画面に出ているのがデモ用ワークスペースで、窓が WezTerm と OBS の 2 つだけか
        aw = json.loads(run(["hyprctl", "activeworkspace", "-j"]).stdout)
        on = [c for c in clients() if c["workspace"]["name"] == aw["name"]]
        if aw["name"] != "weave-demo" or sorted(c["class"] for c in on) != ["com.obsproject.Studio", "weave-demo"]:
            raise RuntimeError(f"screen is not clean: ws={aw['name']} windows={[c['class'] for c in on]}")
        rec = os.path.join(OUT, "screen_raw.mp4")
        procs["rec"] = subprocess.Popen(["wf-recorder", "-o", MON, "-f", rec, "-r", "30", "-y"],
                                        stdout=subprocess.DEVNULL, stderr=open(os.path.join(OUT, "wf.log"), "w"))
        time.sleep(1.5)

        top = "demo:0.0"
        type_(top, "weave setup")
        time.sleep(3.5)
        type_(top, "weave wrap add hype_bot")
        time.sleep(2.5)
        type_(top, "y")
        time.sleep(4.0)
        type_(top, "# hype_bot の接続先を 4456 と上のパスワードに変えて起動する")
        time.sleep(1.0)
        # 下のペインで WEAVE を起動
        run(T + ["split-window", "-v", "-l", "35%", "-t", "demo:0", "-c", WD, f"bash --rcfile {rc} -i"])
        time.sleep(0.8)
        bottom = "demo:0.1"
        type_(bottom, "weave up")
        for _ in range(100):
            if "ObsGate: listening" in pane_text(bottom):
                break
            time.sleep(0.1)
        time.sleep(1.5)
        pw = json.load(open(os.path.join(WD, ".weave", "wrap", "hype_bot.json")))["password"]
        type_(top, f"python3 hype_bot.py --chat chat.jsonl --port 4456 --password {pw} &")
        time.sleep(3.0)
        type_(top, "# 普段どおりに使う (視聴者: !party)")
        time.sleep(0.5)
        chat("kumo_23", "!party")
        time.sleep(5.0)
        type_(top, "weave wrap lock hype_bot")
        time.sleep(2.0)
        type_(top, "y")
        time.sleep(3.0)
        type_(top, "# パーティー中にもう一度 !party (hype_bot のバグ)")
        time.sleep(0.5)
        chat("kumo_23", "!party")
        time.sleep(1.5)
        chat("nyanta", "!party")
        time.sleep(9.0)

        procs["rec"].send_signal(signal.SIGINT)
        procs["rec"].wait(timeout=20)
        procs.pop("rec")
        # 上のバー (日時・予定など) を切り落とす
        bar = int(os.environ.get("BAR_PX", "42"))  # 上のバー 27pt × 1.5
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", rec, "-vf", f"crop=1920:{1080 - bar}:0:{bar},pad=1920:1080:0:{bar // 2}:color=0x1e1e2e",
                        "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", os.path.join(OUT, "quickstart_raw.mp4")], check=True)
        os.remove(rec)
        open(os.path.join(OUT, "top_pane.txt"), "w").write(pane_text(top))
        open(os.path.join(OUT, "bottom_pane.txt"), "w").write(pane_text(bottom))
    finally:
        if "rec" in procs:
            procs["rec"].send_signal(signal.SIGINT)
        run(T + ["send-keys", "-t", "demo:0.1", "C-c"])
        time.sleep(1.5)
        run(T + ["kill-server"])
        subprocess.run(["pkill", "-f", f"{WD}/hype_bot.py"])
        for n in ["wez", "obs"]:
            p = procs.pop(n, None)
            if p:
                p.send_signal(signal.SIGINT)
                try:
                    p.wait(timeout=20)
                except Exception:
                    p.kill()
        if os.path.exists(USERINI + ".raw-bak"):
            shutil.move(USERINI + ".raw-bak", USERINI)
        if "orig_ws" in procs:
            run(["hyprctl", "dispatch", "workspace", str(procs["orig_ws"])])
        run(["makoctl", "mode", "-r", "do-not-disturb"])
        print("記録:", OUT)


if __name__ == "__main__":
    main()
