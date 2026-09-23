#!/usr/bin/env bash
# E2E: 基盤 (Core) を kill -9 しても、Supervisor が即座に再起動し、配信の状態が戻る (R7 / デモ第 2 幕)
#
#   1. weave-obs-sim + WEAVE --supervise (実 OBS モード)
#   2. kusa シナリオで草エフェクトを表示させる
#   3. Core プロセスを kill -9
#   4. 1 秒以内に Core が Ready に戻ること
#   5. OBS の表示状態が保持され、kusa が状態を取り戻して自動非表示が来ること
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=./zig-out/bin
DIR=$(mktemp -d)
PORT=4478
cleanup() { kill -INT "${SUP:-0}" 2>/dev/null || true; sleep 0.3; kill -9 "${SUP:-0}" "${SIM:-0}" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

"$BIN/weave-obs-sim" --port $PORT --state-file "$DIR/obs.json" --quiet > "$DIR/sim.log" 2>&1 &
SIM=$!
sleep 0.3
"$BIN/WEAVE" --supervise --real-obs --obs-port $PORT \
  --mock-twitch demo/scenarios/kusa.jsonl --mock-twitch-once \
  --dash-port 3075 --node-port 8075 --state-dir "$DIR/state" \
  wasm-apps/kusa_node.wasm > "$DIR/weave.log" 2>&1 &
SUP=$!

wait_for() { for _ in $(seq 1 "$3"); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done; return 1; }

wait_for "$DIR/obs.json" '"Overlay#1":true' 60 || { echo "FAIL: overlay was never shown"; exit 1; }
sleep 0.4 # スナップショットが書かれるのを待つ (200ms 間隔)
CORE=$(pgrep -P $SUP | head -1)
[ -n "$CORE" ] || { echo "FAIL: core process not found"; exit 1; }
T0=$(date +%s%3N)
kill -9 "$CORE"
for _ in $(seq 1 100); do
  [ "$(grep -c 'Ready in' "$DIR/weave.log")" -ge 2 ] && break
  sleep 0.01
done
T1=$(date +%s%3N)
[ "$(grep -c 'Ready in' "$DIR/weave.log")" -ge 2 ] || { echo "FAIL: core did not come back"; tail -20 "$DIR/weave.log"; exit 1; }
DT=$((T1 - T0))
echo "core back in ${DT} ms after kill -9"
[ "$DT" -lt 1000 ] || { echo "FAIL: restart took ${DT} ms (>= 1000)"; exit 1; }

grep -q '"Overlay#1":true' "$DIR/obs.json" || { echo "FAIL: overlay state lost"; exit 1; }
grep -q "Snapshot: restored" "$DIR/weave.log" || { echo "FAIL: snapshot not restored"; exit 1; }
wait_for "$DIR/obs.json" '"Overlay#1":false' 200 || { echo "FAIL: auto-hide never came after restart"; exit 1; }
echo "overlay kept across the restart, and auto-hide still arrived"
echo "PASS"
