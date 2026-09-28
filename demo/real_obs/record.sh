#!/usr/bin/env bash
# =============================================================================
# demo/real_obs/record.sh — 「本物の OBS」版デモ動画を作る
#   左: OBS のアプリ画面そのもの (シーン一覧・ソース・コントロール込み。wf-recorder で画面録画)
#   右: Inspector (playwright で録画、注釈つき)
#   2 本を開始時刻で揃えて横に並べ、demo/output/weave_demo_real_obs.mp4 にする
#
#   OBS は Hyprland の仮想モニターに置いて録る (実画面は使わない。録画中に PC を触っても映り込まない)
#   位置合わせ: 画面録画の開始時刻 (起動直前の壁時計) と record.mjs が出す "T0 <epoch ms>"
#   必要: bun, chromium, ffmpeg, wf-recorder, hyprctl, OBS 32 (obs-websocket 有効)、zig build / dashboard build 済み
#   使い方: ./demo/real_obs/record.sh
# =============================================================================
set -uo pipefail
set -m   # ジョブ制御 ON: バックグラウンドの子が SIGINT を無視しないように (wf-recorder は SIGINT で mp4 を確定する)
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
export CHROMIUM=${CHROMIUM:-$(command -v chromium || command -v chromium-browser || echo /usr/bin/chromium)}
OUT="$ROOT/demo/output/obs"; mkdir -p "$OUT"
rm -rf "$OUT/state"; rm -f "$OUT"/weave_obs_*.mp4 "$OUT/obs_screen.mp4"   # 毎回まっさら (サブ数などの状態も初期値から)
WORK=$(mktemp -d); VID="$WORK/vid"; mkdir -p "$VID"
LOG="$OUT/record_run.log"
SCREEN="$OUT/obs_screen.mp4"
RUN=0; WFR=0

# pid が 0 のときは kill しない (kill 0 は自分のプロセスグループ全体に飛ぶ)
cleanup() {
  if [ "$WFR" != 0 ]; then kill -INT "$WFR" 2>/dev/null; wait "$WFR" 2>/dev/null; fi
  if [ "$RUN" != 0 ]; then kill -TERM "$RUN" 2>/dev/null || true; sleep 3; kill -KILL "$RUN" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

for t in wf-recorder hyprctl ffmpeg; do command -v "$t" >/dev/null || { echo "$t がありません"; exit 1; }; done
[ -d dashboard/dist ] || { echo "dashboard/dist がありません (cd dashboard && bun run build)"; exit 1; }

# --- 1. OBS + WEAVE (OBS 自身の録画はしない。画面ごと録る) ---
bash demo/real_obs/run.sh > "$LOG" 2>&1 &
RUN=$!
for _ in $(seq 1 400); do grep -q "INSPECTOR" "$LOG" 2>/dev/null && break; sleep 0.2; done
URL=$(grep -oE "http://127\.0\.0\.1:[0-9]+/\?token=[0-9a-f]+" "$LOG" | head -1)
[ -n "$URL" ] || { echo "Inspector の URL が取れませんでした"; tail -15 "$LOG"; exit 1; }
grep -q "identified with OBS" "$LOG" || sleep 3
grep -q "identified with OBS" "$LOG" || { echo "ObsEgress が OBS に繋がっていません"; tail -15 "$LOG"; exit 1; }

# --- 2. OBS の窓を仮想モニターへ ---
ADDR=""
for _ in $(seq 1 50); do
  ADDR=$(hyprctl clients -j | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    if c.get("class")=="com.obsproject.Studio" and c.get("title","").startswith("OBS"): print(c["address"]); break')
  [ -n "$ADDR" ] && break; sleep 0.2
done
[ -n "$ADDR" ] || { echo "OBS の窓が見つかりません"; exit 1; }
# 実画面を録ると、録画中に別の窓やワークスペースを見た瞬間それが映り込む。
# Hyprland の仮想モニター (headless output) を作って OBS をそこへ静かに移し、その仮想モニターだけを録る。
# 実画面では何をしていても録画に影響しない。終わったら仮想モニターは消す
REC_MON=WEAVE-REC
hyprctl output remove "$REC_MON" >/dev/null 2>&1
hyprctl output create headless "$REC_MON" >/dev/null || { echo "仮想モニターを作れません"; exit 1; }
remove_mon() { hyprctl output remove "$REC_MON" >/dev/null 2>&1; }
trap 'cleanup; remove_mon' EXIT INT TERM
# 実画面から遠くに置く (マウスが迷い込まないように)。scale 1.5 = 実画面と同じ見た目 (論理 1280x720)
hyprctl keyword monitor "$REC_MON,1920x1080@30,20000x0,1.5" >/dev/null
sleep 0.8
REC_WS=$(hyprctl monitors all -j | python3 -c 'import json,sys
for m in json.load(sys.stdin):
    if m["name"]=="'"$REC_MON"'": print(m["activeWorkspace"]["id"])')
[ -n "$REC_WS" ] || { echo "仮想モニターのワークスペースが分かりません"; exit 1; }
hyprctl dispatch movetoworkspacesilent "$REC_WS,address:$ADDR" >/dev/null   # silent: 実画面のフォーカスは奪わない
sleep 2   # 移動とレイアウトの落ち着き待ち (単独の窓なのでモニター全体に広がる)

# --- 3. 画面録画を開始 (開始の壁時計を覚える) ---
WF_MS=$(date +%s%3N)
wf-recorder -y -o "$REC_MON" -r 30 -D -f "$SCREEN" > "$OUT/wf.log" 2>&1 &
WFR=$!
sleep 1.5
kill -0 "$WFR" 2>/dev/null || { echo "wf-recorder が起動しません"; tail -5 "$OUT/wf.log"; exit 1; }

# --- 4. Inspector を録画 (発火も注釈も record.mjs の 1 本の時計) ---
( cd "$WORK" && "$BUN" add playwright-core@1 >/dev/null 2>&1; cp "$ROOT"/demo/record/record.mjs .
  WEAVE_REC_SPLIT=1 "$BUN" record.mjs "$URL" "$VID" ) > "$WORK/rec.log" 2>&1 || { echo "Inspector の録画に失敗"; tail -8 "$WORK/rec.log"; exit 1; }
T0_MS=$(grep -oE "^T0 [0-9]+" "$WORK/rec.log" | awk '{print $2}')
[ -n "$T0_MS" ] || { echo "T0 が取れませんでした"; exit 1; }

# --- 5. 画面録画を確定 → OBS を閉じる ---
kill -INT "$WFR"; wait "$WFR" 2>/dev/null; WFR=0
kill -TERM "$RUN"; wait "$RUN" 2>/dev/null || true; RUN=0
[ -s "$SCREEN" ] || { echo "画面録画がありません ($SCREEN)"; tail -5 "$OUT/wf.log"; exit 1; }

# --- 6. 位置合わせして横に並べる (左 OBS 画面 1280x720 / 右 Inspector 1280x720) ---
WEBM=$(ls -t "$VID"/*.webm | head -1)
# playwright の動画は T0 より少し遅れて始まる。遅れ = (T0 から終了までのスクリプト時間) - (動画の長さ)
# 字幕/ラベル/切り替えの時刻はこの遅れを引き、画面録画側はこの遅れも含めて切る
WEBM_S=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$WEBM" | sort -g | tail -1)

# 字幕: record.mjs が出す "BAND <T0 からの ms> <文言>" から ASS を作り、下に足した黒帯に左右をまたぐ全幅で焼く
#       "MARK <ms> BEFORE|AFTER|''" → 左上のラベル、"MARK <ms> DEV" → 最後の開発者カードの開始 (ここから OBS を外す)
CAP="$WORK/cap.ass"
read -r DEV_S LAG_S CROP < <(python3 - "$WORK/rec.log" "$CAP" "$WEBM_S" <<'PY2'
import sys, re
log, out, webm_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
band, mark, dev, box, end_ms = [], [], None, None, None
for line in open(log, encoding="utf-8"):
    line = line.rstrip("\n")
    m = re.match(r"^DEVBOX (\d+) (\d+) (\d+) (\d+)$", line)
    if m: box = tuple(int(v) for v in m.groups()); continue
    m = re.match(r"^END (\d+)$", line)
    if m: end_ms = int(m.group(1)); continue
    m = re.match(r"^BAND (\d+) ?(.*)$", line)
    if m: band.append((int(m.group(1)), m.group(2).strip())); continue
    m = re.match(r"^MARK (\d+) ?(.*)$", line)
    if m:
        t, lab = int(m.group(1)), m.group(2).strip()
        if lab == "DEV": dev = t
        else: mark.append((t, lab))
lag = max(0, end_ms - int(webm_s * 1000)) if end_ms else 0
band = [(max(0, t - lag), x) for t, x in band]
mark = [(max(0, t - lag), x) for t, x in mark]
if dev is not None: dev = max(0, dev - lag)
def ts(ms):
    cs = ms // 10; return f"{cs//360000}:{cs//6000%60:02d}:{cs//100%60:02d}.{cs%100:02d}"
rows = []
for i, (t, txt) in enumerate(band):
    if not txt: continue
    end = band[i+1][0] if i + 1 < len(band) else t + 5000
    rows.append(f"Dialogue: 0,{ts(t)},{ts(end)},Band,,0,0,0,,{{\\an5\\pos(1280,785)}}{txt}")
TAG = {"BEFORE": ("Before", "BEFORE  今までの世界"), "AFTER": ("After", "AFTER  WEAVE")}
for i, (t, lab) in enumerate(mark):
    if lab not in TAG: continue
    end = mark[i+1][0] if i + 1 < len(mark) else t + 4000
    style, txt = TAG[lab]
    rows.append(f"Dialogue: 1,{ts(t)},{ts(end)},{style},,0,0,0,,{{\\an7\\pos(36,30)}}{txt}")
head = """[Script Info]
ScriptType: v4.00+
PlayResX: 2560
PlayResY: 850
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Band,Noto Sans CJK JP,46,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,0,0,5,60,60,0,1
Style: Before,Noto Sans CJK JP,62,&H00FFFFFF,&H00FFFFFF,&H001414D0,&H001414D0,-1,0,0,0,100,100,2,0,3,16,0,7,0,0,0,1
Style: After,Noto Sans CJK JP,62,&H00FFFFFF,&H00FFFFFF,&H00377F1A,&H00377F1A,-1,0,0,0,100,100,2,0,3,16,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
open(out, "w", encoding="utf-8").write(head + "\n".join(rows) + "\n")
M = 12   # カードの周りの余白 (px)
if box:
    x, y, w, h = box; x0, y0 = max(0, x - M), max(0, y - M)
    crop = f"{min(1440 - x0, w + 2*M)}:{min(810 - y0, h + 2*M)}:{x0}:{y0}"
else:
    crop = "1078:746:181:47"
print(f"{dev/1000:.3f}" if dev is not None else "99999", f"{lag/1000:.3f}", crop)
print(f"字幕 {len(band)} / ラベル {len(mark)} / 開発者カード開始 {dev} ms / 動画の遅れ {lag} ms / カード {crop}", file=sys.stderr)
PY2
)
OFF=$(python3 -c "print(max(0.0, ($T0_MS - $WF_MS)/1000 + $LAG_S))")
echo "画面録画側を ${OFF}s 切って揃える (Inspector 動画の遅れ ${LAG_S}s を含む)"
# 最後の開発者カード: OBS は外し、Inspector のカード部分 (record.mjs が測った位置) を切り出して中央に大きく
# shortest=1: 短い方 (Inspector 側) が終わったら終える
ffmpeg -y -i "$SCREEN" -i "$WEBM" -filter_complex \
  "[0:v]trim=start=${OFF},setpts=PTS-STARTPTS,fps=30,scale=1280:720:flags=lanczos,setsar=1[l];[1:v]fps=30,split=2[ra][rb];[ra]scale=1280:720,setsar=1[r];[rb]crop=${CROP},scale=-2:720:flags=lanczos,setsar=1,pad=2560:720:(ow-iw)/2:0:color=0x1e1e1e[d];[l][r]hstack=inputs=2:shortest=1[s];[s][d]overlay=0:0:enable='gte(t,${DEV_S})':shortest=1,pad=2560:850:0:0:black,subtitles=filename=${CAP},format=yuv420p" \
  -r 30 -c:v libx264 -crf 20 -movflags +faststart demo/output/weave_demo_real_obs.mp4 >/dev/null 2>&1 \
  || { echo "ffmpeg に失敗"; exit 1; }
echo "できました: demo/output/weave_demo_real_obs.mp4 ($(du -h demo/output/weave_demo_real_obs.mp4 | cut -f1))"
