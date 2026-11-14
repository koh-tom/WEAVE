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
DEFAULTS = {"OverlayText": "草 草 草 ！ チャットが盛り上がってます", "SubGoal": "サブ  8 / 50", "番組名": "まったり雑談配信"}
# 展示では出さない部品 (模擬配信用のスコアボードとタイマー): シーンの item 番号
HIDE = [8, 23, 9]
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
    for iid, on in [(1, False), (3, True)] + [(i, False) for i in HIDE]:
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
        cap("パーティー中にもう一度 !party → バグで止まらなくなり、サブ数のカウントがでたらめに")
        time.sleep(8.5)
        cap("ツールが止まっても、壊れたカウントは残ったまま。どこで何が起きたかも分からない")
        time.sleep(3.5)
        reset_screen()
        time.sleep(0.5)
        chat_bot("mallory", "!takeover")
        cap("更新に悪意あるコードが混ざったら → 番組名を書き換え、背景を消し、配信まで止めようとする")
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
        # プラグインは作業フォルダに写して承認する。subgoal だけ「前の版 (権限が 1 つ少ない) を承認済み → 更新で権限が増えた」状態にする
        PD = os.path.join(WD, "plugins"); os.makedirs(PD, exist_ok=True)
        names = ["subgoal", "shoutout", "scoreboard", "score_tool", "loop_node", "malicious_plugin"]
        for n in names:
            for ext in (".wasm", ".json"):
                shutil.copy(os.path.join(ROOT, "wasm-apps", n + ext), PD)
        sg = os.path.join(PD, "subgoal.json")
        full = json.load(open(sg))
        old = json.loads(json.dumps(full)); old["permissions"]["publish"] = ["core.obs.request.SetInputSettings"]
        json.dump(old, open(sg, "w"))
        for n in names:
            subprocess.run([f"{BIN}/weave", "add", f"plugins/{n}.wasm", "--yes", "--approvals", "approved.json"], cwd=WD, capture_output=True)
        json.dump(full, open(sg, "w"), ensure_ascii=False, indent=4)  # 更新: 配信画面の表示を変える権限が増えた
        cfg = json.load(open(os.path.expanduser("~/.config/obs-studio/plugin_config/obs-websocket/config.json")))

        def start_weave(tag_, plugins, extra):
            json.dump({"no_twitch": True, "obs_port": cfg.get("server_port", 4455), "obs_password": cfg.get("server_password", ""),
                       "audit_log_path": os.path.join(OUT, "audit.log"), "plugins": [f"plugins/{p}.wasm" for p in plugins]},
                      open(os.path.join(WD, "weave.json"), "w"))
            log = os.path.join(OUT, f"weave_{tag_}.log")
            procs["weave"] = subprocess.Popen([f"{BIN}/weave", "up", "--dash-port", str(DASH), "--node-port", "8086", "--dashboard-token", TOKEN,
                                               "--dashboard-dist", os.path.join(ROOT, "dashboard", "dist"), "--state-dir", os.path.join(WD, "state_" + tag_),
                                               "--approval-mode", "strict", "--approvals", "approved.json"] + extra, cwd=WD,
                                              stdout=open(log, "w"), stderr=subprocess.STDOUT, start_new_session=True)
            for _ in range(150):
                if os.path.exists(log) and "Ready in" in open(log, errors="replace").read():
                    break
                time.sleep(0.1)

        def start_insp(w, h, scale):
            shutil.copy(os.path.join(HERE, "inspector.mjs"), os.path.join(TOOLS, "booth_inspector.mjs"))  # playwright-core を解決できる場所に置く
            procs["insp"] = subprocess.Popen(["node", os.path.join(TOOLS, "booth_inspector.mjs"), f"http://127.0.0.1:{DASH}/?token={TOKEN}",
                                              os.path.join(OUT, "insp"), str(w), str(h), str(scale)],
                                             cwd=TOOLS, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            procs["insp"].stdout.readline()  # READY
            time.sleep(1.0)

        def stop_insp():
            p = procs.pop("insp", None)
            if p:
                p.stdin.close()
                p.wait(timeout=20)

        # 1 回目の起動: score_tool を起動し忘れ、subgoal は更新で権限が増えている (画面を大きく映す)
        start_weave("first", ["subgoal", "shoutout", "scoreboard", "loop_node", "malicious_plugin"], ["--expect", "plugins/score_tool.json"])
        start_insp(960, 540, 1.5)
        ev("right", mode="inspector")
        cap("起動した瞬間に観測可能：止まっているものと、その原因・直し方まで表示")
        time.sleep(7.0)
        cap("更新で権限が増えたプラグインは、承認するまで起動しない")
        time.sleep(6.0)
        cap("直し方のとおりに、権限を確かめて承認し、起動し忘れを足して起動し直す")
        subprocess.run([f"{BIN}/weave", "add", "plugins/subgoal.wasm", "--yes", "--approvals", "approved.json"], cwd=WD, capture_output=True)
        stop_insp()
        stop("weave")
        start_weave("second", ["subgoal", "shoutout", "scoreboard", "score_tool", "loop_node", "malicious_plugin"], [])
        start_insp(1440, 810, 1)
        time.sleep(2.5)
        start_bot(4456, "booth-demo-pw")
        time.sleep(2.5)
        chat_bot("kumo_23", "!party")
        cap("普段どおりの操作は、そのまま OBS に届く")
        time.sleep(5.5)
        chat_bot("kumo_23", "!party")
        time.sleep(1.2)
        chat_bot("nyanta", "!party")
        cap("暴走した所だけ停止：同じバグでも、このツールだけを止めて、カウントを元に戻す")
        time.sleep(7.0)
        cap("止めた理由は Inspector に。配信とほかのツールは動いたまま")
        time.sleep(4.0)
        chat_bot("mallory", "!takeover")
        cap("宣言にない操作は拒否：乗っ取られても、番組名の書き換えも配信停止も OBS に届かない")
        time.sleep(6.0)
        stop("bot")

        cap("WEAVE の中のプラグインも同じ：無限ループは 1〜3 ms で停止・再起動、悪意ある操作は拒否")
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
