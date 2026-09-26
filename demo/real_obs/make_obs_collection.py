#!/usr/bin/env python3
# demo/real_obs/make_obs_collection.py — 本物の OBS 用のシーンコレクション "WEAVE-demo" と録画プロファイルを作る
#
#   プラグインが送る名前にぴったり合わせる:
#     scene "Overlay"  item 1 = お祝いカード (subgoal / kusa_node が toggle)   item 2 = シャウトアウトカード (shoutout)
#     input "SubGoal"      … subgoal が SetInputSettings で「サブ N / 50」を書く (常時表示)
#     input "OverlayText"  … subgoal のお祝い文言   input "ShoutoutText" … shoutout の文言 (別入力: 同時に出ても混ざらない)
#   ※ OBS ではシーン名と入力名が同じ名前空間なので、scene "Overlay" と同名の入力は作れない (だから OverlayText)
#
#   既存の scene collection (ユーザーのもの) は触らない。~/.config/obs-studio/basic/{scenes,profiles}/ に新規作成するだけ。
#   使い方: python3 demo/real_obs/make_obs_collection.py   (run.sh がコレクションが無いときに自動で呼ぶ)
import json, uuid, os, re, copy, glob, sys

HOME = os.path.expanduser("~")
BASE = f"{HOME}/.config/obs-studio/basic"
MAIN_CANVAS = "6c69626f-6273-4c00-9d88-c5136d61696e"   # libobs の main canvas (固定 UUID)
OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "output", "obs"))


def abgr(hexrgb, a=255):
    r, g, b = int(hexrgb[0:2], 16), int(hexrgb[2:4], 16), int(hexrgb[4:6], 16)
    return (a << 24) | (b << 16) | (g << 8) | r


def base_source(name):
    return {"prev_ver": 0, "name": name, "uuid": str(uuid.uuid4()),
            "mixers": 0, "sync": 0, "flags": 0, "volume": 1.0, "balance": 0.5, "enabled": True, "muted": False,
            "push-to-mute": False, "push-to-mute-delay": 0, "push-to-talk": False, "push-to-talk-delay": 0,
            "hotkeys": {}, "deinterlace_mode": 0, "deinterlace_field_order": 0, "monitoring_type": 0, "private_settings": {}}


def text(name, txt, size, color="ffffff", bold=True):
    s = base_source(name)
    s.update({"id": "text_ft2_source_v2", "versioned_id": "text_ft2_source_v2",
              "settings": {"text": txt,
                           "font": {"face": "Noto Sans CJK JP", "size": size, "flags": 1 if bold else 0, "style": "Bold" if bold else "Regular"},
                           "color1": abgr(color), "color2": abgr(color), "outline": True, "drop_shadow": False,
                           "antialiasing": True, "word_wrap": False, "custom_width": 0}})
    return s


def color(name, hexrgb, w, h):
    s = base_source(name)
    s.update({"id": "color_source_v3", "versioned_id": "color_source_v3",
              "settings": {"color": abgr(hexrgb), "width": w, "height": h}})
    return s


def item(iid, source, x, y, align=0, visible=True):
    # align: 0 = 中心基準, 5 = 左上 (LEFT|TOP), 6 = 右上 (RIGHT|TOP)
    return {"name": source["name"], "source_uuid": source["uuid"], "visible": visible, "locked": False, "rot": 0.0,
            "scale_ref": {"x": 1920.0, "y": 1080.0}, "align": align, "bounds_type": 0, "bounds_align": 0, "bounds_crop": False,
            "crop_left": 0, "crop_top": 0, "crop_right": 0, "crop_bottom": 0, "id": iid, "group_item_backup": False,
            "pos": {"x": float(x), "y": float(y)}, "scale": {"x": 1.0, "y": 1.0}, "bounds": {"x": 0.0, "y": 0.0},
            "scale_filter": "disable", "blend_method": "default", "blend_type": "normal",
            "show_transition": {"duration": 0}, "hide_transition": {"duration": 0}, "private_settings": {}}


def scene(name, items):
    s = base_source(name)
    s.update({"id": "scene", "versioned_id": "scene", "canvas_uuid": MAIN_CANVAS,
              "settings": {"id_counter": max(i["id"] for i in items), "custom_size": False, "items": items}})
    s["hotkeys"] = {"OBSBasic.SelectScene": []}
    for i in items:
        s["hotkeys"][f"libobs.show_scene_item.{i['id']}"] = []
        s["hotkeys"][f"libobs.hide_scene_item.{i['id']}"] = []
    return s


def scaffold():
    """既存コレクションがあれば version / transitions / canvases などの骨組みを借りる (OBS のバージョン差を吸収)"""
    for p in sorted(glob.glob(f"{BASE}/scenes/*.json")):
        if os.path.basename(p) == "WEAVE-demo.json":
            continue
        try:
            return json.load(open(p))
        except Exception:
            pass
    return {"current_scene": "", "current_program_scene": "", "current_transition": "Fade", "transition_duration": 300,
            "transitions": [], "groups": [], "modules": {}, "saved_projectors": [], "quick_transitions": [],
            "preview_locked": False, "scaling_enabled": False, "scaling_level": 0, "scaling_off_x": 0.0, "scaling_off_y": 0.0,
            "resolution": {"x": 1920, "y": 1080}, "version": 2, "canvases": []}


def make_collection():
    bg = color("背景", "1e1e1e", 1920, 1080)
    label = text("ゲーム画面ラベル", "ゲーム画面", 72, "8a8a8a", False)
    subgoal = text("SubGoal", "サブ  8 / 50", 56)
    otext = text("OverlayText", "", 64)
    stext = text("ShoutoutText", "", 64)
    c1bg = color("Card1Bg", "1a7f37", 1920, 120)   # お祝い: 緑バー (下)
    c2bg = color("Card2Bg", "1f5fbf", 1200, 120)   # シャウトアウト: 青カード (上。右上の SubGoal に被らない幅/高さ)
    card1 = scene("Card1", [item(1, c1bg, 960, 1010), item(2, otext, 960, 1010)])
    card2 = scene("Card2", [item(1, c2bg, 960, 240), item(2, stext, 960, 240)])
    overlay = scene("Overlay", [item(5, bg, 0, 0, align=5), item(4, label, 960, 540), item(3, subgoal, 1880, 30, align=6),
                                item(1, card1, 0, 0, align=5, visible=False), item(2, card2, 0, 0, align=5, visible=False)])
    out = copy.deepcopy(scaffold())
    out["name"] = "WEAVE-demo"
    out["current_scene"] = out["current_program_scene"] = "Overlay"
    out["scene_order"] = [{"name": "Overlay"}, {"name": "Card1"}, {"name": "Card2"}]
    out["sources"] = [bg, label, subgoal, otext, stext, c1bg, c2bg, card1, card2, overlay]
    out["groups"] = []
    out["saved_projectors"] = []
    os.makedirs(f"{BASE}/scenes", exist_ok=True)
    path = f"{BASE}/scenes/WEAVE-demo.json"
    json.dump(out, open(path, "w"), ensure_ascii=False, indent=1)
    print(f"wrote {path}")


def make_profile():
    """録画プロファイル: 1280x720 / 30fps / 出力先 demo/output/obs。既存プロファイルをコピーして出力だけ変える"""
    pd = f"{BASE}/profiles/WEAVE-demo"
    os.makedirs(pd, exist_ok=True)
    src = None
    for p in sorted(glob.glob(f"{BASE}/profiles/*/basic.ini")):
        if "WEAVE-demo" not in p:
            src = p
            break
    ini = open(src).read() if src else "[General]\nName=WEAVE-demo\n[Video]\nBaseCX=1920\nBaseCY=1080\nOutputCX=1280\nOutputCY=720\nFPSType=0\nFPSCommon=30\n[SimpleOutput]\nFilePath=" + OUT_DIR + "\nRecFormat2=mp4\nRecEncoder=x264\n[AdvOut]\nRecFilePath=" + OUT_DIR + "\nRecFormat2=mp4\n"
    rep = {"OutputCX": "1280", "OutputCY": "720", "FPSCommon": "30", "FPSType": "0",
           "FilePath": OUT_DIR, "RecFilePath": OUT_DIR, "FilenameFormatting": "weave_obs_%CCYY-%MM-%DD_%hh-%mm-%ss"}
    for k, v in rep.items():
        ini = re.sub(rf"^{re.escape(k)}=.*$", f"{k}={v}", ini, flags=re.M)
    ini = re.sub(r"^Name=.*$", "Name=WEAVE-demo", ini, flags=re.M)
    open(f"{pd}/basic.ini", "w").write(ini)
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"wrote {pd}/basic.ini")


if __name__ == "__main__":
    if not os.path.isdir(BASE):
        print(f"OBS の設定ディレクトリがありません: {BASE} (先に OBS を一度起動してください)", file=sys.stderr)
        sys.exit(1)
    make_collection()
    make_profile()
