#!/usr/bin/env python3
# demo/stream_sim/make_collection.py — 模擬配信用の OBS シーンコレクション "WEAVE-stream" とプロファイルを作る
#
#   scene "Overlay" (プラグインがこの名前と item id を使う)
#     item 1 = お祝いカード (kusa_node)   item 2 = シャウトアウトカード (shoutout)
#     ゲーム画面 (ライフゲームの動画をループ) / ● LIVE / 番組名 / SubGoal / Scoreboard / Timer
#     SE_clap / SE_drum / SE_yay / SE_fanfare … 効果音 (sfx プラグインが頭から再生し直す)
#     item 20 / 21 = BEFORE / AFTER の札 (demo/wrap の前後比較用)
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
    s["mixers"] = 0xFF  # 全部の音声トラックに出す (0 だと「Unassigned」で録画に音が入らない)
    return s


def image(name, file):
    s = roc.base_source(name)
    s.update({"id": "image_source", "versioned_id": "image_source", "settings": {"file": os.path.join(MEDIA, "panels", file), "unload": False}})
    return s


def label(name, txt, size):
    """パネルの上に置く文字 (縁取りなし・影つき)"""
    s = roc.text(name, txt, size)
    s["settings"].update({"outline": False, "drop_shadow": True})
    return s


def make_collection():
    # 背景は風景 (make_scenery.py)。無ければ前のライフゲームの動画
    bgfile = os.path.join(MEDIA, "scenery.mp4")
    game = media("ゲーム画面", bgfile if os.path.exists(bgfile) else os.path.join(MEDIA, "game.mp4"), True)
    live = image("LiveBadge", "live.png")
    title_bg, title = image("TitleBg", "title.png"), label("番組名", "WEAVE 杯 決勝 ― 実況配信", 30)
    sub_bg, subgoal = image("SubGoalBg", "subgoal.png"), label("SubGoal", "サブ  8 / 50", 40)
    score_bg, score = image("ScoreBg", "score.png"), label("Scoreboard", "A 0 - 0 B", 54)
    timer = label("Timer", "", 110)
    otext = label("OverlayText", "草 草 草 ！ チャットが盛り上がってます", 48)
    stext = label("ShoutoutText", "", 50)
    c1bg, c2bg = image("Card1Bg", "card1.png"), image("Card2Bg", "card2.png")
    card1 = roc.scene("Card1", [roc.item(1, c1bg, 960, 960), roc.item(2, otext, 960, 960)])
    card2 = roc.scene("Card2", [roc.item(1, c2bg, 960, 250), roc.item(2, stext, 960, 250)])
    ses = [media(n, os.path.join(MEDIA, f), False) for n, f in
           [("SE_clap", "se_clap.wav"), ("SE_drum", "se_drum.wav"), ("SE_yay", "se_yay.wav"), ("SE_fanfare", "se_fanfare.wav")]]
    game_item = roc.item(3, game, 0, 0, align=5)
    game_item["scale"] = {"x": 1.5, "y": 1.5}  # 1280x720 の動画を 1920x1080 の画面いっぱいに
    # item の番号はプラグインとデモが使う (1 = お祝いカード, 2 = シャウトアウト, 3 = 背景, 20 / 21 = BEFORE / AFTER の札)
    items = [game_item,
             roc.item(4, live, 135, 62), roc.item(5, title_bg, 485, 62), roc.item(6, title, 485, 60),
             roc.item(22, sub_bg, 1670, 66), roc.item(7, subgoal, 1670, 64),
             roc.item(23, score_bg, 960, 76), roc.item(8, score, 960, 72), roc.item(9, timer, 960, 540),
             roc.item(1, card1, 0, 0, align=5, visible=False), roc.item(2, card2, 0, 0, align=5, visible=False)]
    items += [roc.item(10 + i, s, 0, 0, align=5) for i, s in enumerate(ses)]
    # デモの前後比較の札 (文字は画像に入れてある)
    bb, ab = image("BeforeBg", "tag_before.png"), image("AfterBg", "tag_after.png")
    tag_b = roc.scene("TagBefore", [roc.item(1, bb, 1610, 170)])
    tag_a = roc.scene("TagAfter", [roc.item(1, ab, 1610, 170)])
    items += [roc.item(20, tag_b, 0, 0, align=5, visible=False), roc.item(21, tag_a, 0, 0, align=5, visible=False)]
    overlay = roc.scene("Overlay", items)
    out = copy.deepcopy(roc.scaffold())
    out["name"] = NAME
    out["current_scene"] = out["current_program_scene"] = "Overlay"
    out["scene_order"] = [{"name": "Overlay"}, {"name": "Card1"}, {"name": "Card2"}, {"name": "TagBefore"}, {"name": "TagAfter"}]
    out["sources"] = [game, live, title_bg, title, sub_bg, subgoal, score_bg, score, timer, otext, stext, c1bg, c2bg, *ses, bb, ab, card1, card2, tag_b, tag_a, overlay]
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
