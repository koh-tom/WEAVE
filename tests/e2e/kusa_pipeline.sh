#!/usr/bin/env bash
set -euo pipefail

# Work from the repository root
cd "$(dirname "$0")/../.."

LOG_DIR=$(mktemp -d)
trap "kill -9 \$(jobs -p) 2>/dev/null || true; echo \"LOG_DIR is at $LOG_DIR\"" EXIT INT TERM

echo "Starting WEAVE core with kusa scenario in background..."
# Start WEAVE in the background
./zig-out/bin/WEAVE \
  --mock-twitch demo/scenarios/kusa.jsonl \
  --mock-obs \
  --mock-obs-file "$LOG_DIR/obs.jsonl" \
  wasm-apps/kusa_node.wasm \
  > "$LOG_DIR/weave.log" 2>&1 &

echo "Waiting 35 seconds for the scenario events to compile and settle..."
sleep 35

echo "--- obs.jsonl contents ---"
if [ -f "$LOG_DIR/obs.jsonl" ]; then
  cat "$LOG_DIR/obs.jsonl"
else
  echo "(obs.jsonl does not exist)"
fi
echo "--------------------------"

echo "--- weave.log contents ---"
if [ -f "$LOG_DIR/weave.log" ]; then
  cat "$LOG_DIR/weave.log"
else
  echo "(weave.log does not exist)"
fi
echo "--------------------------"

# Assertions
echo "Running E2E Assertions..."

if [ ! -f "$LOG_DIR/obs.jsonl" ]; then
  echo "FAIL: obs.jsonl log file was not created"
  exit 1
fi

ON_COUNT=$(grep -c '"sceneItemEnabled":true' "$LOG_DIR/obs.jsonl" || true)
OFF_COUNT=$(grep -c '"sceneItemEnabled":false' "$LOG_DIR/obs.jsonl" || true)

echo "ON_COUNT: $ON_COUNT (Expected: 2)"
echo "OFF_COUNT: $OFF_COUNT (Expected: 2)"

if [ "$ON_COUNT" -ne 2 ]; then
  echo "FAIL: Expected SetSceneItemEnabled(true) to be logged exactly 2 times, but got $ON_COUNT"
  exit 1
fi

if [ "$OFF_COUNT" -ne 2 ]; then
  echo "FAIL: Expected SetSceneItemEnabled(false) to be logged exactly 2 times, but got $OFF_COUNT"
  exit 1
fi

echo "PASS"
exit 0
