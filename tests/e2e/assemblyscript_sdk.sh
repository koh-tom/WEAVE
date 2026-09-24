#!/usr/bin/env bash
# E2E: 3 つ目の言語 (AssemblyScript) の SDK で書いたプラグインが、Zig/C と同じ Host API で動く (C2)
#   weave init --lang as でひな形を作り、sdk/assemblyscript/build.sh でビルドし、mock Twitch の
#   "!hello" に反応して ext.<name>.greeting を出すことを Inspector (weave topic echo) で確かめる。
#   bun が必要 (CI は setup-bun で入れる)。
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
NAME=as_e2e_$$
cleanup() {
  kill -INT "${W:-0}" 2>/dev/null || true; sleep 0.3; kill -9 "${W:-0}" 2>/dev/null || true
  rm -f "sdk/assemblyscript/plugins/$NAME.ts" "wasm-apps/$NAME.json" "wasm-apps/$NAME.wasm"
  rmdir sdk/assemblyscript/plugins 2>/dev/null || true
  echo "logs: $DIR"
}
trap cleanup EXIT INT TERM

"$BIN/weave" init "$NAME" --lang as > "$DIR/init.log" 2>&1
sdk/assemblyscript/build.sh "sdk/assemblyscript/plugins/$NAME.ts" > "$DIR/build.log" 2>&1 || { cat "$DIR/build.log"; echo "FAIL: build"; exit 1; }
printf '{"delta_ms":1500,"user":"a","message":"!hello"}\n{"delta_ms":100,"user":"b","message":"hi"}\n' > "$DIR/chat.jsonl"

"$BIN/WEAVE" --mock-twitch "$DIR/chat.jsonl" --mock-twitch-once --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3072 --node-port 8072 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" \
  --dashboard-token e2e --introspection contents "wasm-apps/$NAME.wasm" > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 50); do grep -q "Running" "$DIR/weave.log" 2>/dev/null && break; sleep 0.05; done
grep -q "Loaded plugin '$NAME'" "$DIR/weave.log" || { tail -5 "$DIR/weave.log"; echo "FAIL: plugin did not load"; exit 1; }
timeout 4 "$BIN/weave" topic echo "ext.$NAME.#" --url ws://127.0.0.1:3072/ws --token e2e > "$DIR/echo.log" 2>&1 || true
N=$(grep -c "\"topic\":\"ext.$NAME.greeting\"" "$DIR/echo.log" || true)
echo "greetings from the AssemblyScript plugin: $N"
[ "$N" = 1 ] || { cat "$DIR/echo.log"; echo "FAIL: expected exactly 1 greeting"; exit 1; }
echo "PASS"
