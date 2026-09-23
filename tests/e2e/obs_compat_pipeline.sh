#!/usr/bin/env bash
set -euo pipefail

# Work from the repository root
cd "$(dirname "$0")/../.."

# ---------------------------------------------------------
# Test 1: Good Plugin (scene_switcher.wasm)
# ---------------------------------------------------------
LOG_DIR_GOOD=$(mktemp -d)
trap "kill -9 \$(jobs -p) 2>/dev/null || true; rm -rf $LOG_DIR_GOOD" EXIT INT TERM

echo "=== Running Good Plugin Test (scene_switcher) ==="
./zig-out/bin/WEAVE \
  --mock-twitch demo/scenarios/obs_compat.jsonl --mock-twitch-once \
  --mock-obs --dash-port 3073 --node-port 8073 \
  --mock-obs-file "$LOG_DIR_GOOD/obs.jsonl" \
  wasm-apps/scene_switcher.wasm \
  > "$LOG_DIR_GOOD/weave.log" 2>&1 &

echo "Waiting 12 seconds for scenario events..."
sleep 12

echo "--- obs.jsonl contents ---"
if [ -f "$LOG_DIR_GOOD/obs.jsonl" ]; then
  cat "$LOG_DIR_GOOD/obs.jsonl"
else
  echo "(obs.jsonl does not exist)"
fi
echo "--------------------------"

# Assertions for scene_switcher
echo "Verifying scene_switcher behavior..."
if [ ! -f "$LOG_DIR_GOOD/obs.jsonl" ]; then
  echo "FAIL: obs.jsonl log file was not created"
  exit 1
fi

# !scene1 -> overlay1:true, overlay2:false
# !scene2 -> overlay1:false, overlay2:true
# !hide -> overlay1:false, overlay2:false
# Total SetSceneItemEnabled actions should be 6
ACTION_COUNT=$(grep -c 'SetSceneItemEnabled' "$LOG_DIR_GOOD/obs.jsonl" || true)
echo "Total OBS actions logged: $ACTION_COUNT (Expected: 6)"
if [ "$ACTION_COUNT" -ne 6 ]; then
  echo "FAIL: Expected exactly 6 OBS actions, but got $ACTION_COUNT"
  exit 1
fi

echo "Good Plugin E2E: PASS"
echo ""

# Clean up first test background jobs
kill -9 $(jobs -p) 2>/dev/null || true

# ---------------------------------------------------------
# Test 2: Malicious Plugin (malicious_plugin.wasm)
# ---------------------------------------------------------
LOG_DIR_BAD=$(mktemp -d)
trap "kill -9 \$(jobs -p) 2>/dev/null || true; rm -rf $LOG_DIR_GOOD $LOG_DIR_BAD" EXIT INT TERM

echo "=== Running Malicious Plugin Test (malicious_plugin) ==="
./zig-out/bin/WEAVE \
  --mock-twitch demo/scenarios/obs_compat.jsonl --mock-twitch-once \
  --mock-obs --dash-port 3074 --node-port 8074 \
  --mock-obs-file "$LOG_DIR_BAD/obs.jsonl" \
  wasm-apps/malicious_plugin.wasm \
  > "$LOG_DIR_BAD/weave.log" 2>&1 &

echo "Waiting 12 seconds for scenario events..."
sleep 12

echo "--- weave.log contents ---"
if [ -f "$LOG_DIR_BAD/weave.log" ]; then
  cat "$LOG_DIR_BAD/weave.log"
else
  echo "(weave.log does not exist)"
fi
echo "--------------------------"

# Assertions for malicious_plugin (checking console outputs/security alerts)
echo "Verifying malicious_plugin safety blocks..."
if [ ! -f "$LOG_DIR_BAD/weave.log" ]; then
  echo "FAIL: weave.log was not created"
  exit 1
fi

# 1. Check file access blocked
if ! grep -q "fopen: filesystem access denied by Wasm sandbox" "$LOG_DIR_BAD/weave.log"; then
  echo "FAIL: File access was not blocked, or not logged properly"
  exit 1
fi

# 2. Check network socket blocked
if ! grep -q "socket: network access denied by Wasm sandbox" "$LOG_DIR_BAD/weave.log"; then
  echo "FAIL: Socket access was not blocked, or not logged properly"
  exit 1
fi

# 3. Check unauthorized publish blocked (Capability ACL)
if ! grep -q "Security Error: Plugin 'malicious_plugin'.*attempted to publish to unauthorized topic 'core.system.shutdown'" "$LOG_DIR_BAD/weave.log"; then
  echo "FAIL: Unauthorized topic publish was not blocked by Capability ACL, or not logged properly"
  exit 1
fi

if ! grep -q "Permission denied by Capability ACL" "$LOG_DIR_BAD/weave.log"; then
  echo "FAIL: Plugin did not receive permission denied error code"
  exit 1
fi

echo "Malicious Plugin E2E: PASS"
echo "=== ALL OBS COMPAT TESTS PASSED ==="
exit 0
