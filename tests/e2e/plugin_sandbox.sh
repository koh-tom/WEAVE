#!/usr/bin/env bash
# E2E: プラグインのプロセスを OS で閉じ込める (ADR-010 段階 3)
#   1. seccomp: 許可していないシステムコール (ファイルを開く) を呼ぶと SIGSYS で終わる
#   2. 名前空間: 子のネットワーク名前空間は Core と別 (外へ出るネットワークを持たない)
#   3. cgroup: 子は weave.slice の下に入り、無限ループしても CPU は上限 (1 コアの 50%) に抑えられる
#      (cgroup v2 の委譲が無い環境ではこの項目だけ飛ばす)
#   4. 無限ループの最中でも Core はすぐ終われて、子と cgroup が片付く
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
ulimit -c 0 # seccomp の自己テストで core を残さない
DIR=$(mktemp -d)
cleanup() { kill -9 "${W:-0}" 2>/dev/null || true; for p in $(pgrep -f "weave-cell plugin --socket $DIR/" || true); do kill -9 "$p" 2>/dev/null || true; done; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

# 1
set +e; "$BIN/weave-cell" selftest-seccomp > "$DIR/selftest.log" 2>&1; rc=$?; set -e
[ "$rc" = 159 ] || { cat "$DIR/selftest.log"; echo "FAIL: seccomp did not kill a forbidden syscall (exit $rc)"; exit 1; }
echo "1: opening a file under seccomp → killed by SIGSYS"

cp wasm-apps/loop_node.wasm "$DIR/loop_slow.wasm"
python3 - "$DIR/loop_slow.json" <<'PY'
import json, sys
m = json.load(open("wasm-apps/loop_node.json")); m["name"] = "loop_slow"; m["limits"] = {"max_instructions": 2000000000}
json.dump(m, open(sys.argv[1], "w"))
PY
"$BIN/WEAVE" --isolate-plugins --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3058 --node-port 8058 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" --dashboard-token sb \
  "$DIR/loop_slow.wasm" > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 60); do grep -q "Running" "$DIR/weave.log" 2>/dev/null && break; sleep 0.05; done
C=$(pgrep -f "weave-cell plugin --socket $DIR/" | head -1 || true)
[ -n "$C" ] || { echo "FAIL: plugin process not running"; exit 1; }
grep -q "sandboxed (seccomp" "$DIR/weave.log" || { echo "FAIL: the plugin process was not sandboxed"; exit 1; }

# 2
[ "$(readlink /proc/$C/ns/net)" != "$(readlink /proc/$W/ns/net)" ] || { echo "FAIL: the plugin process shares Core's network namespace"; exit 1; }
echo "2: plugin process network namespace $(readlink /proc/$C/ns/net) (Core: $(readlink /proc/$W/ns/net))"

# 3
"$BIN/weave" topic pub ext.twitch.chat.message '{"user":"x","message":"!freeze"}' --url ws://127.0.0.1:3058/ws --token sb >/dev/null 2>&1
CGPATH=$(cut -d: -f3 /proc/$C/cgroup)
if [[ "$CGPATH" == *weave.slice/cell-* ]]; then
  CG=/sys/fs/cgroup$CGPATH
  sleep 0.5
  u0=$(awk '/usage_usec/{print $2}' "$CG/cpu.stat"); t0=$(date +%s%N); sleep 2; u1=$(awk '/usage_usec/{print $2}' "$CG/cpu.stat"); t1=$(date +%s%N)
  PCT=$(awk "BEGIN{printf \"%.0f\", ($u1-$u0)/(($t1-$t0)/1000)*100}")
  echo "3: cgroup $(basename "$CG"): cpu.max=$(cat "$CG/cpu.max"), memory.max=$(cat "$CG/memory.max"); CPU while spinning ${PCT}%"
  [ "$PCT" -le 60 ] || { echo "FAIL: CPU not capped"; exit 1; }
else
  echo "3: skipped (no cgroup v2 delegation here: $CGPATH)"
fi

# 4
t0=$(date +%s%N); kill -INT "$W"
for _ in $(seq 1 40); do kill -0 "$W" 2>/dev/null || break; sleep 0.05; done
kill -0 "$W" 2>/dev/null && { echo "FAIL: Core did not exit while the plugin was spinning"; exit 1; }
echo "4: Core exited in $(( ($(date +%s%N)-t0)/1000000 )) ms while the plugin was spinning"
[ -z "$(pgrep -f "weave-cell plugin --socket $DIR/" || true)" ] || { echo "FAIL: plugin process left behind"; exit 1; }
if [[ "${CGPATH:-}" == *weave.slice/cell-* ]] && [ -d "/sys/fs/cgroup$CGPATH" ]; then echo "FAIL: cgroup left behind"; exit 1; fi
echo "PASS"
