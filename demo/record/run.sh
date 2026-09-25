#!/usr/bin/env bash
# =============================================================================
# demo/record/run.sh — Before/After のデモ動画 demo/output/weave_demo.mp4 を作る
#
#   普段の Inspector をそのまま録画し、その上に文字と矢印の注釈を後付けする (雑な動画編集風)。
#   「今までの世界ならこうなってた / WEAVE は防いだ」を、DENIED の行や復帰の行を矢印で指して見せる。
#   実物の Before (偽トークン窃取→送信→クラッシュ) は weave demo before_after で別に見られる。
#
#   必要: bun (playwright-core を自動で入れる)、chromium、ffmpeg
#   使い方: ./demo/record/run.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
export CHROMIUM=${CHROMIUM:-$(command -v chromium || command -v chromium-browser || echo /usr/bin/chromium)}
WORK=$(mktemp -d); VID="$WORK/vid"; mkdir -p "$VID"
D=$(mktemp -d)
DASH=3037; NODE=8037; TOK=rec
mkdir -p demo/output

cleanup(){
  kill "${WEAVE:-0}" 2>/dev/null || true; sleep 0.3; kill -9 "${WEAVE:-0}" 2>/dev/null || true
  rm -rf "$D" /tmp/weave-demo 2>/dev/null || true
}
trap cleanup EXIT INT TERM

[ -x zig-out/bin/WEAVE ] || { echo "先に zig build してください"; exit 1; }
[ -d dashboard/dist ] || ( cd dashboard && "$BUN" install >/dev/null 2>&1 && "$BUN" run build >/dev/null 2>&1 )

# --- 2. WEAVE (白 UI) を起動。kusa / malicious / loop ---
./zig-out/bin/WEAVE --no-twitch --mock-obs --mock-obs-file "$D/o" \
  --dash-port $DASH --node-port $NODE --audit-log "$D/a.log" --state-dir "$D/st" --dashboard-token $TOK \
  wasm-apps/subgoal.wasm wasm-apps/shoutout.wasm wasm-apps/malicious_plugin.wasm wasm-apps/loop_node.wasm \
  > "$D/w.log" 2>&1 &
WEAVE=$!
for _ in $(seq 1 100); do grep -q "Running" "$D/w.log" 2>/dev/null && break; sleep 0.05; done
sleep 1

# --- 3. 録画 (発火も字幕も record.mjs の 1 本の時計) ---
( cd "$WORK" && "$BUN" add playwright-core@1 >/dev/null 2>&1; cp "$ROOT"/demo/record/record.mjs .
  "$BUN" record.mjs "http://127.0.0.1:$DASH/?token=$TOK" "$VID" ) >"$D/rec.log" 2>&1 || { echo "録画に失敗"; tail -8 "$D/rec.log"; exit 1; }

WEBM=$(ls -t "$VID"/*.webm 2>/dev/null | head -1)
[ -n "$WEBM" ] || { echo "webm が出来ていない"; tail -8 "$D/rec.log"; exit 1; }
ffmpeg -y -i "$WEBM" -movflags +faststart -pix_fmt yuv420p -c:v libx264 -crf 22 demo/output/weave_demo.mp4 >/dev/null 2>&1
echo "できました: demo/output/weave_demo.mp4 ($(du -h demo/output/weave_demo.mp4 | cut -f1))"
