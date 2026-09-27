#!/usr/bin/env bash
# =============================================================================
# demo/real_obs/record.sh — 「本物の OBS」版デモ動画を作る
#   左: OBS のアプリ画面そのもの (シーン一覧・ソース・コントロール込み。wf-recorder で画面録画)
#   右: Inspector (playwright で録画、注釈つき)
#   2 本を開始時刻で揃えて横に並べ、demo/output/weave_demo_real_obs.mp4 にする
#
#   録画中の約 70 秒だけ、OBS の窓を全画面にする (Hyprland)。終わると OBS ごと閉じる
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
MON=$(hyprctl monitors -j | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])')

# --- 1. OBS + WEAVE (OBS 自身の録画はしない。画面ごと録る) ---
bash demo/real_obs/run.sh > "$LOG" 2>&1 &
RUN=$!
for _ in $(seq 1 400); do grep -q "INSPECTOR" "$LOG" 2>/dev/null && break; sleep 0.2; done
URL=$(grep -oE "http://127\.0\.0\.1:[0-9]+/\?token=[0-9a-f]+" "$LOG" | head -1)
[ -n "$URL" ] || { echo "Inspector の URL が取れませんでした"; tail -15 "$LOG"; exit 1; }
grep -q "identified with OBS" "$LOG" || sleep 3
grep -q "identified with OBS" "$LOG" || { echo "ObsEgress が OBS に繋がっていません"; tail -15 "$LOG"; exit 1; }

# --- 2. OBS の窓を全画面に ---
ADDR=""
for _ in $(seq 1 50); do
  ADDR=$(hyprctl clients -j | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    if c.get("class")=="com.obsproject.Studio" and c.get("title","").startswith("OBS"): print(c["address"]); break')
  [ -n "$ADDR" ] && break; sleep 0.2
done
[ -n "$ADDR" ] || { echo "OBS の窓が見つかりません"; exit 1; }
hyprctl dispatch focuswindow "address:$ADDR" >/dev/null
hyprctl dispatch fullscreen 0 >/dev/null
sleep 2   # 全画面への切り替えとレイアウトの落ち着き待ち

# --- 3. 画面録画を開始 (開始の壁時計を覚える) ---
WF_MS=$(date +%s%3N)
wf-recorder -y -o "$MON" -r 30 -D -f "$SCREEN" > "$OUT/wf.log" 2>&1 &
WFR=$!
sleep 1.5
kill -0 "$WFR" 2>/dev/null || { echo "wf-recorder が起動しません"; tail -5 "$OUT/wf.log"; exit 1; }

# --- 4. Inspector を録画 (発火も注釈も record.mjs の 1 本の時計) ---
( cd "$WORK" && "$BUN" add playwright-core@1 >/dev/null 2>&1; cp "$ROOT"/demo/record/record.mjs .
  "$BUN" record.mjs "$URL" "$VID" ) > "$WORK/rec.log" 2>&1 || { echo "Inspector の録画に失敗"; tail -8 "$WORK/rec.log"; exit 1; }
T0_MS=$(grep -oE "^T0 [0-9]+" "$WORK/rec.log" | awk '{print $2}')
[ -n "$T0_MS" ] || { echo "T0 が取れませんでした"; exit 1; }

# --- 5. 画面録画を確定 → OBS を閉じる ---
kill -INT "$WFR"; wait "$WFR" 2>/dev/null; WFR=0
kill -TERM "$RUN"; wait "$RUN" 2>/dev/null || true; RUN=0
[ -s "$SCREEN" ] || { echo "画面録画がありません ($SCREEN)"; tail -5 "$OUT/wf.log"; exit 1; }

# --- 6. 位置合わせして横に並べる (左 OBS 画面 1280x720 / 右 Inspector 1280x720) ---
OFF=$(python3 -c "print(max(0.0, ($T0_MS - $WF_MS)/1000))")
echo "画面録画開始 → Inspector 録画開始: ${OFF}s ずれ (画面録画側をその分切る)"
WEBM=$(ls -t "$VID"/*.webm | head -1)
# shortest=1: 短い方 (Inspector 側) が終わったら終える
ffmpeg -y -i "$SCREEN" -i "$WEBM" -filter_complex \
  "[0:v]trim=start=${OFF},setpts=PTS-STARTPTS,fps=30,scale=1280:720:flags=lanczos,setsar=1[l];[1:v]fps=30,scale=1280:720,setsar=1[r];[l][r]hstack=inputs=2:shortest=1,format=yuv420p" \
  -r 30 -c:v libx264 -crf 20 -movflags +faststart demo/output/weave_demo_real_obs.mp4 >/dev/null 2>&1 \
  || { echo "ffmpeg に失敗"; exit 1; }
echo "できました: demo/output/weave_demo_real_obs.mp4 ($(du -h demo/output/weave_demo_real_obs.mp4 | cut -f1))"
