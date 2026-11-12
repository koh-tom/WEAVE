#!/usr/bin/env python3
"""demo/wrap/hype_bot.py — デモ用の「よくある既存の配信ツール」(WEAVE のことは何も知らない)

OBS に obs-websocket v5 で直接つなぎ、チャットのコマンドで配信画面を盛り上げる小さな Bot。
ネットで拾ってきたスクリプトや、昔自分で書いたツールを想定している。チャットはローカルのファイル
(1 行 1 件の JSON) を tail して読む。すべてローカルの偽データで、外部のサービスにはつながない。

  !party     お祝いカード (Overlay の item 1) を 3 秒出し、帯の文字 (OverlayText) を変える … 正常な機能
             ただしパーティー中にもう一度 !party が来ると、状態の管理を間違えて止まらなくなる (バグ)。
             止まらなくなると、カウンタの値を画面のいろいろな文字に書き込み続ける
  !takeover  「更新に悪意あるコードが混入した」想定。番組名を書き換え、ゲーム画面を消し、配信を止めようとする

  python3 hype_bot.py --chat chat.jsonl [--port 4455] [--password P] [--max-seconds 8]
  (--port / --password を省くと OBS の設定ファイルの値で本物の OBS に直接つなぐ)
  デモの安全のため、止まらなくなっても --max-seconds 秒で自分で止まる
"""
import argparse, json, os, random, sys, threading, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "stream_sim"))
from obsws import OBS  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--chat", required=True)
ap.add_argument("--port", type=int)
ap.add_argument("--password")
ap.add_argument("--max-seconds", type=float, default=8)
args = ap.parse_args()

obs = OBS(port=args.port, password=args.password)
lock = threading.Lock()
party_until = 0.0
runaway = False


def say(msg):
    print(f"[hype_bot] {msg}", flush=True)


def call(rt, data=None):
    """失敗しても気にせず続ける (よくある作り)。結果は表示だけする"""
    with lock:
        try:
            obs.call(rt, data)
            return True
        except Exception as e:
            say(f"{rt} failed: {e}")
            return False


def text(name, s):
    return call("SetInputSettings", {"inputName": name, "inputSettings": {"text": s}})


def card(on):
    return call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 1, "sceneItemEnabled": on})


def party():
    global party_until, runaway
    now = time.time()
    if now < party_until:
        # バグ: パーティー中の 2 回目で終了時刻を「足し算」してしまい、終わらなくなる
        runaway = True
        say("party again → (bug) never ends")
        threading.Thread(target=runaway_loop, daemon=True).start()
        return
    party_until = now + 3
    say("party!")
    text("OverlayText", "★ パーティータイム！ ★")
    card(True)
    threading.Thread(target=party_end, daemon=True).start()


def party_end():
    time.sleep(3)
    if runaway:
        return
    card(False)
    text("OverlayText", "草 草 草 ！ チャットが盛り上がってます")


def runaway_loop():
    start = time.time()
    n = 0
    while time.time() - start < args.max_seconds:
        n += 1
        k = random.randint(1000, 99999)
        # 止まらないカウンタを、画面のいろいろな文字に書き込み続ける (画面の点滅はしない)
        text("OverlayText", "★" * (1 + n % 12) + f" PARTY x{n} " + "★" * (1 + n % 12))
        text("Scoreboard", f"A {k} - {-n} B")
        text("SubGoal", f"サブ  {k} / 50")
        text("Timer", f"{n:06d}")
        card(True)
        time.sleep(0.04)
    say(f"runaway stopped by --max-seconds ({n} rounds)")


def takeover():
    say("takeover (malicious update)")
    text("番組名", "このチャンネルは乗っ取られました")
    call("SetSceneItemEnabled", {"sceneName": "Overlay", "sceneItemId": 3, "sceneItemEnabled": False})
    call("StopStream")


HANDLERS = {"!party": party, "!takeover": takeover}

say(f"connected to OBS on port {obs.port}")
# 起動より前のチャットは読まない (tail -f と同じ)
pos = os.path.getsize(args.chat) if os.path.exists(args.chat) else 0
while True:
    try:
        with open(args.chat, encoding="utf-8") as f:
            f.seek(pos)
            for line in f:
                pos += len(line.encode("utf-8"))
                try:
                    msg = json.loads(line)["message"].strip()
                except Exception:
                    continue
                h = HANDLERS.get(msg.split(" ")[0])
                if h:
                    threading.Thread(target=h, daemon=True).start()
    except FileNotFoundError:
        pass
    time.sleep(0.1)
