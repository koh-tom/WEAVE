#!/usr/bin/env bash
# E2E: 無限ループするプラグイン (デモ D, P0-1)
#   loop_node は "!freeze" を含むチャットで while(true) に入る。素の環境ならホストごと固まる。
#   WEAVE では manifest の limits.max_instructions を超えた時点で trap し、そのメッセージは隔離され (R2)、
#   予備インスタンスと差し替えてすぐ戻る (R4)。同じ時間に流れた草ラッシュで kusa_node は OBS を操作できる。
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
cleanup() { kill -INT "${W:-0}" 2>/dev/null || true; sleep 0.3; kill -9 "${W:-0}" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

"$BIN/WEAVE" --mock-twitch demo/scenarios/freeze.jsonl --mock-twitch-once --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3048 --node-port 8048 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" \
  wasm-apps/loop_node.wasm wasm-apps/kusa_node.wasm > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 50); do grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" 2>/dev/null && break; sleep 0.1; done
sleep 0.3
grep -q "instruction limit exceeded" "$DIR/weave.log" || { echo "FAIL: the infinite loop was not stopped by instruction metering"; exit 1; }
REC=$(grep -o "Recovery: 'loop_node'.*after [0-9]* ms" "$DIR/weave.log" | head -1 || true)
[ -n "$REC" ] || { echo "FAIL: loop_node did not come back"; exit 1; }
echo "$REC"
ls "$DIR/state/dlq/"*.jsonl >/dev/null 2>&1 || { echo "FAIL: the poison message was not recorded in the DLQ"; exit 1; }
echo "DLQ: $(cat "$DIR"/state/dlq/*.jsonl | wc -l) message(s) quarantined"
grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" || { echo "FAIL: kusa_node was dragged down by the loop"; exit 1; }
kill -0 $W || { echo "FAIL: WEAVE died"; exit 1; }
echo "PASS"
