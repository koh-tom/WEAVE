#!/usr/bin/env python3
# demo/stream_sim/make_collection.py — 模擬配信用の OBS シーンコレクション "WEAVE-stream" とプロファイルを作る
#
#   scene "Overlay" (プラグインがこの名前と item id を使う)
#     item 1 = お祝いカード (kusa_node)   item 2 = シャウトアウトカード (shoutout)
#     ゲーム画面 (ライフゲームの動画をループ) / ● LIVE / 番組名 / SubGoal / Scoreboard / Timer
#     SE_clap / SE_drum / SE_yay / SE_fanfare … 効果音 (sfx プラグインが頭から再生し直す)
#   既存のコレクション・プロファイルには触らない。録画先は demo/output/stream_sim/obs/
import copy, importlib.util, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
spec = importlib.util.spec_from_file_location("roc", os.path.join(ROOT, "demo", "real_obs", "make_obs_collection.py"))
roc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roc)
BASE = roc.BASE
MEDIA = os.path.join(ROOT, "demo", "output", "stream_sim", "media")
REC = os.path.join(ROOT, "demo", "output", "stream_sim", "obs")
NAME = "WEAVE-stream"


def media(name, path, loop):
    s = roc.base_source(name)
    s.update({"id": "ffmpeg_source", "versioned_id": "ffmpeg_source",
              "settings": {"local_file": path, "is_local_file": True, "looping": loop, "restart_on_activate": loop,
                           "close_when_inactive": False, "clear_on_media_end": True, "hw_decode": False}})
    s["monitoring_type"] = 0
    return s


def make_collection():
    game = media("ゲーム画面", os.path.join(MEDIA, "game.mp4"), True)
    live_bg = roc.color("LiveBadge", "c62828", 210, 64)
    live = roc.text("LiveText", "● LIVE", 40)
    title = roc.text("番組名", "WEAVE 杯 決勝 ― 実況配信", 44)
    subgoal = roc.text("SubGoal", "サブ  8 / 50", 52)
    score = roc.text("Scoreboard", "A 0 - 0 B", 64)
    timer = roc.text("Timer", "", 96)
    otext = roc.text("OverlayText", "草 草 草 ！ チャットが盛り上がってます", 60)
    stext = roc.text("ShoutoutText", "", 64)
    c1bg = roc.color("Card1Bg", "1a7f37", 1920, 120)
    c2bg = roc.color("Card2Bg", "1f5fbf", 1200, 120)
    card1 = roc.scene("Card1", [roc.item(1, c1bg, 960, 1010), roc.item(2, otext, 960, 1010)])
    card2 = roc.scene("Card2", [roc.item(1, c2bg, 960, 260), roc.item(2, stext, 960, 260)])
    ses = [media(n, os.path.join(MEDIA, f), False) for n, f in
           [("SE_clap", "se_clap.wav"), ("SE_drum", "se_drum.wav"), ("SE_yay", "se_yay.wav"), ("SE_fanfare", "se_fanfare.wav")]]
    game_item = roc.item(3, game, 0, 0, align=5)
    game_item["scale"] = {"x": 1.5, "y": 1.5}  # 1280x720 の動画を 1920x1080 の画面いっぱいに
    items = [game_item,
             roc.item(4, live_bg, 40, 30, align=5), roc.item(5, live, 60, 36, align=5), roc.item(6, title, 40, 110, align=5),
             roc.item(7, subgoal, 1880, 30, align=6), roc.item(8, score, 960, 80), roc.item(9, timer, 960, 540),
             roc.item(1, card1, 0, 0, align=5, visible=False), roc.item(2, card2, 0, 0, align=5, visible=False)]
    items += [roc.item(10 + i, s, 0, 0, align=5) for i, s in enumerate(ses)]
    overlay = roc.scene("Overlay", items)
    out = copy.deepcopy(roc.scaffold())
    out["name"] = NAME
    out["current_scene"] = out["current_program_scene"] = "Overlay"
    out["scene_order"] = [{"name": "Overlay"}, {"name": "Card1"}, {"name": "Card2"}]
    out["sources"] = [game, live_bg, live, title, subgoal, score, timer, otext, stext, c1bg, c2bg, *ses, card1, card2, overlay]
    out["groups"] = []
    out["saved_projectors"] = []
    os.makedirs(f"{BASE}/scenes", exist_ok=True)
    path = f"{BASE}/scenes/{NAME}.json"
    json.dump(out, open(path, "w"), ensure_ascii=False, indent=1)
    print(f"wrote {path}")


def make_profile():
    pd = f"{BASE}/profiles/{NAME}"
    os.makedirs(pd, exist_ok=True)
    src = f"{BASE}/profiles/WEAVE-demo/basic.ini"
    ini = open(src).read() if os.path.exists(src) else "[General]\nName=x\n[Video]\nBaseCX=1920\nBaseCY=1080\nOutputCX=1280\nOutputCY=720\nFPSType=0\nFPSCommon=30\n[SimpleOutput]\nFilePath=\nRecFormat2=mp4\n[AdvOut]\nRecFilePath=\n"
    for k, v in {"FilePath": REC, "RecFilePath": REC, "FilenameFormatting": "weave_stream_%CCYY-%MM-%DD_%hh-%mm-%ss"}.items():
        ini = re.sub(rf"^{re.escape(k)}=.*$", f"{k}={v}", ini, flags=re.M)
    ini = re.sub(r"^Name=.*$", f"Name={NAME}", ini, flags=re.M)
    open(f"{pd}/basic.ini", "w").write(ini)
    os.makedirs(REC, exist_ok=True)
    print(f"wrote {pd}/basic.ini")


if __name__ == "__main__":
    if not os.path.isdir(BASE):
        sys.exit(f"OBS の設定ディレクトリがありません: {BASE}")
    if not os.path.exists(os.path.join(MEDIA, "game.mp4")):
        sys.exit("先に demo/stream_sim/make_media.sh を実行してください")
    make_collection()
    make_profile()
