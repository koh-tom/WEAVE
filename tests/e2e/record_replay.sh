#!/usr/bin/env bash
# E2E: 記録と再生 (record / replay)
#   1 回目: mock Twitch の草ラッシュで kusa_node を動かし、`weave record` で全イベントを記録する。
#   2 回目: Twitch なしで `--replay` に記録を渡す。外部入力 (チャット) と時刻 (tick) が元のタイムスタンプで
#           流れ直し、kusa_node は同じ判断をする → OBS への要求の列 (内容と間隔) が 1 回目と一致する。
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
cleanup() { for p in ${R:-} ${W:-} ${W2:-}; do kill -INT "$p" 2>/dev/null || true; done; sleep 0.3; for p in ${R:-} ${W:-} ${W2:-}; do kill -9 "$p" 2>/dev/null || true; done; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

# --- 1. 記録 ---
"$BIN/WEAVE" --mock-twitch demo/scenarios/record.jsonl --mock-twitch-once --mock-obs --mock-obs-file "$DIR/obs1.jsonl" \
  --dash-port 3071 --node-port 8071 --audit-log "$DIR/audit1.log" --state-dir "$DIR/state1" --dashboard-token rec \
  wasm-apps/kusa_node.wasm > "$DIR/weave1.log" 2>&1 &
W=$!
for _ in $(seq 1 50); do grep -q "Running" "$DIR/weave1.log" 2>/dev/null && break; sleep 0.05; done
"$BIN/weave" record "$DIR/rec.jsonl" --url ws://127.0.0.1:3071/ws --token rec > "$DIR/record.log" 2>&1 &
R=$!
sleep 12.5
kill -INT "$R" 2>/dev/null || true; kill -INT "$W"; wait "$W" 2>/dev/null || true
N1=$(wc -l < "$DIR/obs1.jsonl")
echo "run 1: $N1 OBS request(s), $(grep -c '"topic":"ext.twitch.chat.message"' "$DIR/rec.jsonl") chat line(s) recorded"
[ "$N1" -ge 2 ] || { echo "FAIL: the recording run did not drive OBS"; exit 1; }

# --- 2. 再生 ---
"$BIN/WEAVE" --replay "$DIR/rec.jsonl" --mock-obs --mock-obs-file "$DIR/obs2.jsonl" \
  --dash-port 3070 --node-port 8070 --audit-log "$DIR/audit2.log" --state-dir "$DIR/state2" \
  wasm-apps/kusa_node.wasm > "$DIR/weave2.log" 2>&1 &
W2=$!
for _ in $(seq 1 200); do grep -q "Replay: done" "$DIR/weave2.log" 2>/dev/null && break; sleep 0.1; done
sleep 0.5
kill -INT "$W2"; wait "$W2" 2>/dev/null || true
grep -h "Replay: done" "$DIR/weave2.log"

# 要求の内容の列が一致し、要求どうしの間隔の差が 300 ms 以内
python3 - "$DIR/obs1.jsonl" "$DIR/obs2.jsonl" <<'PY'
import json, sys
a = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
b = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
sa = [(x["topic"], json.dumps(x["payload"], sort_keys=True)) for x in a]
sb = [(x["topic"], json.dumps(x["payload"], sort_keys=True)) for x in b]
if sa != sb:
    print("FAIL: OBS request sequences differ"); print(" run 1:", sa); print(" replay:", sb); sys.exit(1)
ga = [a[i+1]["ts"] - a[i]["ts"] for i in range(len(a)-1)]
gb = [b[i+1]["ts"] - b[i]["ts"] for i in range(len(b)-1)]
worst = max([abs(x - y) for x, y in zip(ga, gb)] or [0])
print(f"same {len(sa)} OBS request(s); gaps run1={ga} replay={gb} (worst diff {worst} ms)")
if worst > 300: print("FAIL: timing differs"); sys.exit(1)
PY
echo "PASS"
