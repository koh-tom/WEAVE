#!/usr/bin/env bash
# E2E: Wasm プラグインを別プロセスで動かす (ADR-010 段階 2, --isolate-plugins)
#   1. 同じプロセスで動かした時と同じ出力 (kusa: 表示 → 自動非表示 → 表示)
#   2. 待機中に子を kill -9 → 次のメッセージは隔離されずに、起動し直した子が処理する
#   3. 子の中の publish も Core が検査する: malicious_plugin の core.system.shutdown は拒否され監査に残る
#   4. 処理の途中で子が落ちたら、そのメッセージだけ Core で隔離。同じメッセージを送り直しても配送されない
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
cleanup() { kill -INT "${W:-0}" 2>/dev/null || true; sleep 0.5; kill -9 "${W:-0}" 2>/dev/null || true; pkill -9 -f "weave-cell plugin --socket $DIR/" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM
child_of() { pgrep -f "weave-cell plugin --socket $DIR/state/plugin-$1.sock" | head -1 || true; }

# 無限ループを長く回す複製 (命令数上限を 20 億に) — 4. で「処理の途中」に kill するため
cp wasm-apps/loop_node.wasm "$DIR/loop_slow.wasm"
python3 - "$DIR/loop_slow.json" <<'PY'
import json, sys
m = json.load(open("wasm-apps/loop_node.json")); m["name"] = "loop_slow"; m["limits"] = {"max_instructions": 2000000000}
json.dump(m, open(sys.argv[1], "w"))
PY

"$BIN/WEAVE" --isolate-plugins --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3062 --node-port 8062 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" --dashboard-token iso \
  wasm-apps/kusa_node.wasm wasm-apps/malicious_plugin.wasm "$DIR/loop_slow.wasm" > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 60); do grep -q "Running" "$DIR/weave.log" 2>/dev/null && break; sleep 0.05; done
chat() { "$BIN/weave" topic pub ext.twitch.chat.message "{\"user\":\"$1\",\"message\":\"$2\"}" --url ws://127.0.0.1:3062/ws --token iso > /dev/null 2>&1; }
[ "$(grep -c "Core: Loaded plugin .* in its own process" "$DIR/weave.log")" = 3 ] || { echo "FAIL: plugins did not start as processes"; exit 1; }

# 1 + 3: 草ラッシュ (malicious_plugin にも届き、攻撃を試みる)
for i in $(seq 1 11); do chat "v$i" "草"; done
for _ in $(seq 1 40); do grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" 2>/dev/null && break; sleep 0.1; done
grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" || { echo "FAIL: kusa (in its own process) did not drive OBS"; exit 1; }
grep -q '"topic":"core.system.shutdown"' "$DIR/audit.log" || { echo "FAIL: the unauthorized publish from the child was not denied by Core"; exit 1; }
echo "1/3: kusa drove OBS; malicious_plugin's core.system.shutdown denied by Core: $(grep -c '"topic":"core.system.shutdown"' "$DIR/audit.log") time(s)"

# 2: 待機中の kill -9 → 次のメッセージは隔離されずに処理される
K1=$(child_of 100); kill -9 "$K1"; sleep 0.3
sleep 5.5 # kusa の自動非表示を待つ (tick で起動し直した子が処理する)
grep -q '"sceneItemEnabled":false' "$DIR/obs.jsonl" || { echo "FAIL: after kill -9 while idle, kusa did not continue"; exit 1; }
K2=$(child_of 100)
[ -n "$K2" ] && [ "$K2" != "$K1" ] || { echo "FAIL: kusa's process was not restarted"; exit 1; }
grep -q "exited while idle" "$DIR/weave.log" || { echo "FAIL: idle death not detected"; exit 1; }
echo "2: kusa process $K1 killed while idle → restarted as $K2, auto-hide still arrived"

# 4: 処理の途中で落ちる → そのメッセージだけ隔離
chat viewerX "!freeze"
sleep 0.8
L1=$(child_of 102); kill -9 "$L1"
sleep 0.5
grep -q "process exited while handling" "$DIR/weave.log" || { echo "FAIL: crash during a message was not handled"; exit 1; }
chat viewerX "!freeze"   # 同じ内容 (指紋が同じ) → 配送されない
sleep 1
N=$(grep -c "entering an infinite loop" "$DIR/weave.log" || true)
[ "$N" = 1 ] || { echo "FAIL: the poisoned message was delivered again ($N)"; exit 1; }
grep -q '"core.node.poison"' "$DIR/weave.log" 2>/dev/null || true
echo "4: loop_slow's process killed mid-message → message quarantined in Core, not delivered again"
kill -0 "$W" || { echo "FAIL: Core died"; exit 1; }

kill -INT "$W"
for _ in $(seq 1 60); do kill -0 "$W" 2>/dev/null || break; sleep 0.05; done
kill -0 "$W" 2>/dev/null && { echo "FAIL: Core did not exit"; exit 1; }
[ -z "$(pgrep -f "weave-cell plugin --socket $DIR/" || true)" ] || { echo "FAIL: plugin processes outlived Core"; exit 1; }
echo "PASS"
