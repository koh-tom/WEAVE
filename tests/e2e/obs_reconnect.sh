#!/usr/bin/env bash
# E2E: OBS が落ちて戻っても、WEAVE が意図した表示状態を再適用する (R6 / デモ第 3 幕)
#
#   1. weave-obs-sim (OBS WebSocket v5 シミュレータ) を起動
#   2. WEAVE を実 OBS モードで接続し、kusa シナリオで草エフェクトを表示させる
#   3. シミュレータを kill -9 し、状態が空の新品として再起動
#   4. WEAVE が再接続して Overlay#1 = true を再適用することを確認
#   5. その後の自動非表示 (false) も新しい OBS に届くことを確認
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=./zig-out/bin
DIR=$(mktemp -d)
PORT=4477
cleanup() { kill -9 "${SIM:-0}" "${W:-0}" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

"$BIN/weave-obs-sim" --port $PORT --password e2e --state-file "$DIR/obs1.json" --quiet > "$DIR/sim1.log" 2>&1 &
SIM=$!
sleep 0.3
"$BIN/WEAVE" --real-obs --obs-port $PORT --obs-pass e2e \
  --mock-twitch demo/scenarios/kusa.jsonl --mock-twitch-once \
  --dash-port 3072 --node-port 8072 \
  wasm-apps/kusa_node.wasm > "$DIR/weave.log" 2>&1 &
W=$!

wait_for() { # file pattern timeout_ds
  for _ in $(seq 1 "$3"); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1
}

wait_for "$DIR/obs1.json" '"Overlay#1":true' 30 || { echo "FAIL: overlay was never shown"; exit 1; }
echo "shown on OBS #1: $(cat "$DIR/obs1.json")"

kill -9 $SIM
sleep 0.2
T0=$(date +%s%3N)
"$BIN/weave-obs-sim" --port $PORT --password e2e --state-file "$DIR/obs2.json" --quiet > "$DIR/sim2.log" 2>&1 &
SIM=$!
wait_for "$DIR/obs2.json" '"Overlay#1":true' 50 || { echo "FAIL: desired state was not re-applied after OBS restart"; cat "$DIR/weave.log" | tail -20; exit 1; }
T1=$(date +%s%3N)
echo "re-applied on OBS #2 in $((T1 - T0)) ms: $(cat "$DIR/obs2.json")"

wait_for "$DIR/obs2.json" '"Overlay#1":false' 80 || { echo "FAIL: auto-hide did not reach the restarted OBS"; exit 1; }
echo "auto-hide reached OBS #2: $(cat "$DIR/obs2.json")"
grep -q "re-applied 1 desired state" "$DIR/weave.log" || { echo "FAIL: missing re-apply log"; exit 1; }
# R13: Core 自身が OBS 接続の停止時間を測って core.node.recovered を出す
REC=$(grep -o "Recovery: 'ObsEgress' (cell egress) is active again after [0-9]* ms" "$DIR/weave.log" | tail -1)
[ -n "$REC" ] || { echo "FAIL: no recovery event for ObsEgress"; exit 1; }
echo "$REC"
echo "PASS"
