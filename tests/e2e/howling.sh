#!/usr/bin/env bash
# E2E: ハウリング (ツール同士の無限反響) を、因果の深さ (hops) の上限でバスが止める
#   howl_a と howl_b は互いのイベントに反応し合う。直結の世界では止まらない反響になる。
#   WEAVE では深さ 16 を超えた時点で止まり、audit.log に loop_detected が残る。
#   同時に動いている kusa_node は巻き込まれない。
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
cleanup() { kill -INT "${W:-0}" 2>/dev/null || true; sleep 0.3; kill -9 "${W:-0}" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

"$BIN/WEAVE" --mock-twitch demo/scenarios/kusa.jsonl --mock-twitch-once --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3044 --node-port 8044 --audit-log "$DIR/audit.log" \
  wasm-apps/howl_a.wasm wasm-apps/howl_b.wasm wasm-apps/kusa_node.wasm > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 40); do grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" 2>/dev/null && break; sleep 0.1; done
sleep 0.5
LOOPS=$(grep -c loop_detected "$DIR/audit.log" || true)
echo "loop_detected in audit.log: $LOOPS"
[ "$LOOPS" -ge 1 ] || { echo "FAIL: echo loop was not detected"; exit 1; }
grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" || { echo "FAIL: kusa_node was dragged down by the loop"; exit 1; }
kill -0 $W || { echo "FAIL: WEAVE died"; exit 1; }
echo "PASS"
