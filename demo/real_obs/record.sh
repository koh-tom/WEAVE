#!/usr/bin/env bash
# =============================================================================
# demo/real_obs/record.sh — 「本物の OBS」版デモ動画を作る
#   左: OBS の実出力 (OBS 自身が --startrecording で録画)   右: Inspector (playwright で録画、注釈つき)
#   2 本を開始時刻で揃えて横に並べ、demo/output/weave_demo_real_obs.mp4 にする
#
#   位置合わせ: Inspector 側は record.mjs が出す "T0 <epoch ms>"、OBS 側は OBS のログの "==== Recording Start" の時刻
#   必要: bun, chromium, ffmpeg, OBS 32 (obs-websocket 有効)、zig build / dashboard build 済み
#   使い方: ./demo/real_obs/record.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
export CHROMIUM=${CHROMIUM:-$(command -v chromium || command -v chromium-browser || echo /usr/bin/chromium)}
OUT="$ROOT/demo/output/obs"; mkdir -p "$OUT"
rm -rf "$OUT/state"; rm -f "$OUT"/weave_obs_*.mp4          # 毎回まっさら (サブ数などの状態も初期値から)
WORK=$(mktemp -d); VID="$WORK/vid"; mkdir -p "$VID"
LOG="$OUT/record_run.log"

# run.sh はバックグラウンド起動なので SIGINT は無視される (bash の仕様)。TERM で trap を踏ませる
# pid が空/0 のときに kill しない (kill 0 は自分のプロセスグループ全体に飛ぶ)
cleanup() {
  if [ "${RUN:-0}" != 0 ]; then kill -TERM "$RUN" 2>/dev/null || true; sleep 3; kill -KILL "$RUN" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -d dashboard/dist ] || { echo "dashboard/dist がありません (cd dashboard && bun run build)"; exit 1; }

# --- 1. OBS (録画 ON) + WEAVE ---
bash demo/real_obs/run.sh --record > "$LOG" 2>&1 &
RUN=$!
for _ in $(seq 1 400); do grep -q "INSPECTOR" "$LOG" 2>/dev/null && break; sleep 0.2; done
URL=$(grep -oE "http://127\.0\.0\.1:[0-9]+/\?token=[0-9a-f]+" "$LOG" | head -1)
[ -n "$URL" ] || { echo "Inspector の URL が取れませんでした"; tail -15 "$LOG"; exit 1; }
grep -q "identified with OBS" "$LOG" || sleep 3
grep -q "identified with OBS" "$LOG" || { echo "ObsEgress が OBS に繋がっていません"; tail -15 "$LOG"; exit 1; }
sleep 2

# --- 2. Inspector を録画 (発火も注釈も record.mjs の 1 本の時計) ---
( cd "$WORK" && "$BUN" add playwright-core@1 >/dev/null 2>&1; cp "$ROOT"/demo/record/record.mjs .
  "$BUN" record.mjs "$URL" "$VID" ) > "$WORK/rec.log" 2>&1 || { echo "Inspector の録画に失敗"; tail -8 "$WORK/rec.log"; exit 1; }
T0_MS=$(grep -oE "^T0 [0-9]+" "$WORK/rec.log" | awk '{print $2}')
[ -n "$T0_MS" ] || { echo "T0 が取れませんでした"; exit 1; }

# --- 3. OBS を止めて録画を確定 ---
kill -TERM "$RUN"; wait "$RUN" 2>/dev/null || true; RUN=0
OBSMP4=$(ls -t "$OUT"/weave_obs_*.mp4 2>/dev/null | head -1)
[ -n "$OBSMP4" ] || { echo "OBS の録画ファイルがありません ($OUT)"; exit 1; }

# --- 4. 開始時刻で位置合わせ ---
OBSLOG=$(ls -t "$HOME"/.config/obs-studio/logs/*.txt | head -1)
TS=$(grep -oE "^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}: ==== Recording Start" "$OBSLOG" | tail -1 | cut -d: -f1-3)
[ -n "$TS" ] || { echo "OBS ログに Recording Start がありません ($OBSLOG)"; exit 1; }
REC_MS=$(python3 -c "import datetime; t=datetime.datetime.strptime('$(date +%Y-%m-%d) $TS','%Y-%m-%d %H:%M:%S.%f'); print(int(t.timestamp()*1000))")
OFF=$(python3 -c "print(max(0.0, ($T0_MS - $REC_MS)/1000))")
echo "OBS 録画開始 → Inspector 録画開始: ${OFF}s ずれ (OBS 側をその分切る)"

# --- 5. 横に並べる (左 OBS 1280x720 / 右 Inspector 1280x720) ---
WEBM=$(ls -t "$VID"/*.webm | head -1)
# shortest=1: 短い方 (Inspector 側) が終わったら終える。無いと OBS 側の長さまで右が静止画で続く
ffmpeg -y -i "$OBSMP4" -i "$WEBM" -filter_complex \
  "[0:v]trim=start=${OFF},setpts=PTS-STARTPTS,fps=30,scale=1280:720,setsar=1[l];[1:v]fps=30,scale=1280:720,setsar=1[r];[l][r]hstack=inputs=2:shortest=1,format=yuv420p" \
  -r 30 -c:v libx264 -crf 22 -movflags +faststart demo/output/weave_demo_real_obs.mp4 >/dev/null 2>&1 \
  || { echo "ffmpeg に失敗"; exit 1; }
echo "できました: demo/output/weave_demo_real_obs.mp4 ($(du -h demo/output/weave_demo_real_obs.mp4 | cut -f1))"
