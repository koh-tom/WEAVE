#!/usr/bin/env bash
# E2E: 入力 (チャット) がバスに入ってから OBS に送るまでの時間を、配信中ずっと測っている (core.obs.latency)
#   1. 草ラッシュ → kusa_node がお祝いカードを出す。その要求は「チャットが起点」なので計測に入る
#   2. core.obs.latency (保持) に件数と分位点が出る。/status のまとめ (core.health.summary) にも載る
#   3. 値は常識的な範囲 (p99 < 50 ms。CI の遅いマシンでも落ちない緩い上限)
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
W=0
cleanup() { [ "$W" -gt 0 ] && { kill -INT "$W" 2>/dev/null || true; sleep 0.3; kill -9 "$W" 2>/dev/null || true; }; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*"; exit 1; }

"$BIN/WEAVE" --mock-twitch demo/scenarios/kusa.jsonl --mock-twitch-once --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3074 --node-port 8074 --dashboard-token lt --audit-log "$DIR/audit.log" --state-dir "$DIR/state" \
  wasm-apps/kusa_node.wasm > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 60); do grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" 2>/dev/null && break; sleep 0.1; done
grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" || fail "kusa_node never showed the overlay"
sleep 0.6
L=$(timeout 2 "$BIN/weave" topic echo core.obs.latency --url ws://127.0.0.1:3074/ws --token lt 2>/dev/null | tail -1 || true)
echo "latency: $L"
python3 - "$L" <<'PY' || exit 1
import json, sys
p = json.loads(sys.argv[1])["payload"]
assert p["samples"] >= 1, "no samples"
assert 0 < p["p50_us"] <= p["p99_us"] <= p["max_us"], "percentiles out of order"
assert p["p99_us"] < 50_000, f"p99 too slow: {p['p99_us']} us"
print(f"ok: {p['samples']} sample(s), p50 {p['p50_us']} us, p99 {p['p99_us']} us")
PY
S=$(timeout 2 "$BIN/weave" topic echo core.health.summary --url ws://127.0.0.1:3074/ws --token lt 2>/dev/null | tail -1 || true)
echo "$S" | grep -q '"latency":{"p50_ms":' || fail "the latency is not in the health summary (/status)"
echo "PASS"
