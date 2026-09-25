#!/usr/bin/env bash
# =============================================================================
# demo/record/run.sh — Inspector を録画して demo/output/weave_demo.mp4 を作る
#
#   Inspector を headless Chromium で開いて録画しながら、Before/After のシナリオ
#   (草ラッシュ → 悪意プラグインの拒否 → 暴走からの復帰) を字幕付きで流す。
#
#   必要: bun (playwright-core を自動で入れる)、chromium、ffmpeg
#   使い方: ./demo/record/run.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
CHROMIUM=${CHROMIUM:-$(command -v chromium || command -v chromium-browser || echo /usr/bin/chromium)}
WORK=$(mktemp -d); VID="$WORK/vid"; mkdir -p "$VID"
D=$(mktemp -d)
DASH=3037; NODE=8037; TOK=rec
mkdir -p demo/output

# playwright-core を作業ディレクトリに用意 (リポジトリの依存にはしない)
( cd "$WORK" && "$BUN" add playwright-core@1 >/dev/null 2>&1 )
cp demo/record/record.mjs "$WORK/record.mjs"

pub(){ ./zig-out/bin/weave topic pub ext.twitch.chat.message "$1" --url "ws://127.0.0.1:$DASH/ws" --token "$TOK" >/dev/null 2>&1 || true; }
cleanup(){ kill -INT "${W:-0}" 2>/dev/null || true; sleep 0.3; kill -9 "${W:-0}" 2>/dev/null || true; rm -rf "$D"; }
trap cleanup EXIT INT TERM

[ -x zig-out/bin/WEAVE ] || { echo "先に zig build してください"; exit 1; }
[ -d dashboard/dist ] || ( cd dashboard && "$BUN" install >/dev/null 2>&1 && "$BUN" run build >/dev/null 2>&1 )

./zig-out/bin/WEAVE --no-twitch --mock-obs --mock-obs-file "$D/o" \
  --dash-port $DASH --node-port $NODE --audit-log "$D/a.log" --state-dir "$D/st" --dashboard-token $TOK \
  wasm-apps/kusa_node.wasm wasm-apps/spam_node.wasm wasm-apps/malicious_plugin.wasm wasm-apps/loop_node.wasm \
  > "$D/w.log" 2>&1 &
W=$!
for _ in $(seq 1 100); do grep -q "Running" "$D/w.log" 2>/dev/null && break; sleep 0.05; done
sleep 1

CHROMIUM="$CHROMIUM" ( cd "$WORK" && CHROMIUM="$CHROMIUM" "$BUN" record.mjs "http://127.0.0.1:$DASH/?token=$TOK" "$VID" ) >/dev/null 2>&1 &
REC=$!

sleep 8;  pub '{"user":"v1","message":"草"}'; pub '{"user":"v2","message":"ww"}'
sleep 13; for i in 1 2 3 4 5; do pub '{"user":"attacker","message":"go"}'; sleep 0.3; done
sleep 8;  pub '{"user":"x","message":"!freeze"}'; sleep 1; pub '{"user":"x","message":"また草"}'
wait $REC

WEBM=$(ls -t "$VID"/*.webm 2>/dev/null | head -1)
[ -n "$WEBM" ] || { echo "録画に失敗しました"; exit 1; }
ffmpeg -y -i "$WEBM" -movflags +faststart -pix_fmt yuv420p -c:v libx264 -crf 22 demo/output/weave_demo.mp4 >/dev/null 2>&1
echo "できました: demo/output/weave_demo.mp4 ($(du -h demo/output/weave_demo.mp4 | cut -f1))"
