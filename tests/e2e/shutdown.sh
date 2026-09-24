#!/usr/bin/env bash
# E2E: Ctrl+C (SIGINT) / SIGTERM で毎回きれいに終了する (B3, P1-10)
#   プラグイン・mock Twitch・mock OBS・Inspector・リモートノード待ち受けが全部動いている状態で、
#   起動 → シグナル → 終了 を繰り返す。2 秒以内に終わり、終了コード 0、panic やリーク報告が無いこと。
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
ROUNDS=${ROUNDS:-10}
trap 'echo "logs: $DIR"' EXIT

fail=0
for i in $(seq 1 "$ROUNDS"); do
  for sig in INT TERM; do
    LOG="$DIR/run-$i-$sig.log"
    "$BIN/WEAVE" --mock-twitch demo/scenarios/kusa.jsonl --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
      --dash-port 3047 --node-port 8047 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" \
      wasm-apps/kusa_node.wasm wasm-apps/spam_node.wasm wasm-apps/counter_node.wasm > "$LOG" 2>&1 &
    W=$!
    for _ in $(seq 1 50); do grep -q "Running" "$LOG" 2>/dev/null && break; sleep 0.05; done
    # イベントが流れている最中 (0〜300 ms のばらつき) に止める
    sleep "0.$(( RANDOM % 3 ))"
    kill -"$sig" "$W"
    ok=0
    for _ in $(seq 1 40); do kill -0 "$W" 2>/dev/null || { ok=1; break; }; sleep 0.05; done
    if [ "$ok" != 1 ]; then echo "FAIL: round $i SIG$sig: did not exit within 2 s"; kill -9 "$W" 2>/dev/null || true; fail=1; continue; fi
    set +e; wait "$W"; rc=$?; set -e
    if [ "$rc" != 0 ]; then echo "FAIL: round $i SIG$sig: exit code $rc"; fail=1; fi
    if grep -qE "panic|Segmentation|leaked|Deadlock" "$LOG"; then echo "FAIL: round $i SIG$sig: $(grep -m1 -E 'panic|Segmentation|leaked|Deadlock' "$LOG")"; fail=1; fi
  done
done
[ "$fail" = 0 ] || exit 1
echo "clean shutdowns: $((ROUNDS * 2))/$((ROUNDS * 2))"
echo "PASS"
