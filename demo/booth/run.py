#!/usr/bin/env python3
"""demo/booth/run.py — 展示用のデモ動画の素材を録る (手元の画面には触らない)

  左: OBS が描いた配信画面 (OBS 自身の録画。OBS はトレイに最小化して起動する)
  右: Inspector (見えないブラウザで、一定間隔のスクショ)
  BEFORE  既存ツール hype_bot が OBS に直接つながっている → バグで画面が壊れる / 乗っ取りで番組名とゲーム画面が消える
  AFTER   同じツールを WEAVE (4456) の下へ → バグはそのツールだけ止めて表示を戻す / 宣言にない操作は届かない
          WEAVE の中のプラグインも: 無限ループは上限で止めて作り直す・悪意ある操作は拒否
  字幕・切り替えの時刻は events.jsonl (壁時計 ms) に残し、compose.py で 1 本の動画にする。すべてローカルの偽データ

  使い方: python3 demo/booth/run.py && python3 demo/booth/compose.py demo/output/booth/run-<日時>
"""
import json, os, re, shutil, signal, subprocess, sys, time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "demo", "stream_sim"))
from obsws import OBS  # noqa: E402

BIN = os.path.join(ROOT, "zig-out", "bin")
OUT = os.path.join(ROOT, "demo", "output", "booth", "run-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
WD = os.path.join(OUT, "work")
TOOLS = os.path.join(ROOT, "demo", "output", "stream_sim", "tools")  # playwright-core がある
USERINI = os.path.expanduser("~/.config/obs-studio/user.ini")
DEFAULTS = {"OverlayText": "草 草 草 ！ チャットが盛り上がってます", "Scoreboard": "A 0 - 0 B", "SubGoal": "サブ  8 / 50",
            "Timer": "", "番組名": "WEAVE 杯 決勝 ― 実況配信"}
DASH, TOKEN = 3036, "booth-dash"
procs = {}
evf = None


def ev(kind, **kw):
    e = {"ms": int(time.time() * 1000), "kind": kind, **kw}
    evf.write(json.dumps(e, ensure_ascii=False) + "\n")
    evf.flush()
    print(kind, kw, flush=True)


def cap(text):
    ev("cap", text=text)


def chat_bot(user, msg):
    with open(os.path.join(WD, "chat.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"user": user, "message": msg}, ensure_ascii=False) + "\n")


def chat_weave(user, msg):
    subprocess.run([f"{BIN}/weave", "topic", "pub", "ext.twitch.chat.message", json.dumps({"user": user, "message": msg}, ensure_ascii=False),
                    "--url", f"ws://127.0.0.1:{DASH}/ws", "--token", TOKEN], capture_output=True)


def tag(which):
    o = OBS()
    o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 20, "sceneItemEnabled": which == "before"})
    o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 21, "sceneItemEnabled": which == "after"})


def reset_screen():
    o = OBS()
    for name, text in DEFAULTS.items():
        o.call("SetInputSettings", {"inputName": name, "inputSettings": {"text": text}})
    for iid, on in [(1, False), (3, True)]:
        o.call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": iid, "sceneItemEnabled": on})


def start_bot(port=None, password=None):
    args = [sys.executable, os.path.join(ROOT, "demo", "wrap", "hype_bot.py"), "--chat", os.path.join(WD, "chat.jsonl"), "--max-seconds", "8"]
    if port:
        args += ["--port", str(port), "--password", password]
    log = os.path.join(OUT, f"bot_{port or 'direct'}.log")
    procs["bot"] = subprocess.Popen(args, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    for _ in range(100):
        if os.path.exists(log) and "connected" in open(log).read():
            return
        time.sleep(0.1)


def stop(name, sig=signal.SIGINT, timeout=10):
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
    global evf
    os.makedirs(WD, exist_ok=True)
    evf = open(os.path.join(OUT, "events.jsonl"), "w")
    open(os.path.join(WD, "chat.jsonl"), "w").close()
    shutil.copy(USERINI, USERINI + ".booth-bak")
    try:
        s = open(USERINI).read()
        s = re.sub(r"^(ConfirmOnExit|WarnBeforeStoppingRecord|WarnBeforeStartingRecord)=.*\n?", "", s, flags=re.M)
        open(USERINI, "w").write(s.replace("[General]\n", "[General]\nConfirmOnExit=false\nWarnBeforeStoppingRecord=false\n", 1))
        procs["obs"] = subprocess.Popen(["obs", "--collection", "WEAVE-stream", "--profile", "WEAVE-stream", "--scene", "Overlay",
                                         "--disable-shutdown-check", "--minimize-to-tray"], stdout=open(os.path.join(OUT, "obs.log"), "w"), stderr=subprocess.STDOUT)
        for _ in range(150):
            try:
                OBS().call("GetVersion")
                break
            except Exception:
                time.sleep(0.2)
        time.sleep(2)
        reset_screen()
        tag("before")
        OBS().call("StartRecord")
        ev("rec_start")
        time.sleep(0.5)

        # ---------------------------------------------------------- BEFORE
        ev("right", mode="before")
        cap("BEFORE：よくある既存ツール (hype_bot) が、OBS に直接つながっている")
        start_bot()
        time.sleep(3.0)
        chat_bot("kumo_23", "!party")
        cap("チャットの !party で、画面を盛り上げるツール")
        time.sleep(3.0)
        chat_bot("kumo_23", "!party")
        time.sleep(1.2)
        chat_bot("nyanta", "!party")
        cap("パーティー中にもう一度 !party → バグで止まらなくなり、画面の文字を壊し続ける")
        time.sleep(8.5)
        cap("ツールが止まっても、壊れた表示は残ったまま。どこで何が起きたかも分からない")
        time.sleep(3.5)
        reset_screen()
        time.sleep(0.5)
        chat_bot("mallory", "!takeover")
        cap("更新に悪意あるコードが混ざったら → 番組名を書き換え、ゲーム画面を消し、配信まで止めようとする")
        time.sleep(4.5)
        stop("bot")
        reset_screen()

        # ---------------------------------------------------------- AFTER
        tag("after")
        cap("AFTER：同じツールを WEAVE の下へ。変えたのは接続先 (4456) とパスワードだけ")
        os.makedirs(os.path.join(WD, ".weave", "wrap"), exist_ok=True)
        # 学習モードで記録した宣言 (weave wrap add → 普段どおり使う → weave wrap lock) と同じもの
        json.dump({"name": "hype_bot", "password": "booth-demo-pw", "mode": "enforce",
                   "allow": ["SetInputSettings:OverlayText", "SetSceneItemEnabled:Overlay#1"],
                   "rate_per_sec": 10, "burst": 20, "quarantine_secs": 10},
                  open(os.path.join(WD, ".weave", "wrap", "hype_bot.json"), "w"))
        cfg = json.load(open(os.path.expanduser("~/.config/obs-studio/plugin_config/obs-websocket/config.json")))
        json.dump({"no_twitch": True, "obs_port": cfg.get("server_port", 4455), "obs_password": cfg.get("server_password", ""),
                   "dashboard_dist": os.path.join(ROOT, "dashboard", "dist"), "dashboard_token": TOKEN,
                   "audit_log_path": os.path.join(OUT, "audit.log"),
                   "plugins": [os.path.join(ROOT, "wasm-apps", f"{p}.wasm") for p in ["subgoal", "shoutout", "loop_node", "malicious_plugin"]]},
                  open(os.path.join(WD, "weave.json"), "w"))
        log = os.path.join(OUT, "weave.log")
        procs["weave"] = subprocess.Popen([f"{BIN}/weave", "up", "--dash-port", str(DASH), "--node-port", "8086", "--dashboard-token", TOKEN,
                                           "--dashboard-dist", os.path.join(ROOT, "dashboard", "dist")], cwd=WD,
                                          stdout=open(log, "w"), stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(150):
            if os.path.exists(log) and "ObsGate: listening" in open(log, errors="replace").read():
                break
            time.sleep(0.1)
        shutil.copy(os.path.join(HERE, "inspector.mjs"), os.path.join(TOOLS, "booth_inspector.mjs"))  # playwright-core を解決できる場所に置く
        procs["insp"] = subprocess.Popen(["node", os.path.join(TOOLS, "booth_inspector.mjs"), f"http://127.0.0.1:{DASH}/?token={TOKEN}", os.path.join(OUT, "insp")],
                                         cwd=TOOLS, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        procs["insp"].stdout.readline()  # READY
        time.sleep(1.0)
        ev("right", mode="inspector")
        start_bot(4456, "booth-demo-pw")
        time.sleep(2.5)
        chat_bot("kumo_23", "!party")
        cap("普段どおりの操作は、そのまま OBS に届く")
        time.sleep(5.5)
        chat_bot("kumo_23", "!party")
        time.sleep(1.2)
        chat_bot("nyanta", "!party")
        cap("同じバグ → 操作が多すぎた時点で、このツールだけを止めて、表示を暴走の前に戻す")
        time.sleep(7.0)
        cap("止めた理由は Inspector に。配信とほかのツールは動いたまま")
        time.sleep(4.0)
        chat_bot("mallory", "!takeover")
        cap("乗っ取られても、宣言にない対象 (番組名・ゲーム画面) と配信停止は OBS に届かない")
        time.sleep(6.0)
        stop("bot")

        cap("WEAVE の中のプラグインも同じ：無限ループは上限で止めて作り直し、悪意ある操作は拒否")
        chat_weave("troll", "!freeze")
        time.sleep(1.5)
        for u in ["viewer1", "viewer2", "viewer3"]:
            chat_weave(u, "草")
            time.sleep(0.6)
        time.sleep(5.0)
        ev("end")
        OBS().call("StopRecord")
        time.sleep(1.5)
    finally:
        if "insp" in procs:
            try:
                procs["insp"].stdin.close()
                procs["insp"].wait(timeout=20)
            except Exception:
                procs["insp"].kill()
            procs.pop("insp", None)
        stop("bot")
        stop("weave")
        stop("obs", signal.SIGINT, 20)
        if os.path.exists(USERINI + ".booth-bak"):
            shutil.move(USERINI + ".booth-bak", USERINI)
        recs = sorted(f for f in os.listdir(os.path.join(ROOT, "demo", "output", "stream_sim", "obs")) if f.endswith(".mp4"))
        if recs:
            shutil.copy(os.path.join(ROOT, "demo", "output", "stream_sim", "obs", recs[-1]), os.path.join(OUT, "obs.mp4"))
        print("記録:", OUT)


if __name__ == "__main__":
    main()
