#!/usr/bin/env bash
# E2E: Streamlabs Socket API (socket.io 2.x = Engine.IO v3) を Core のアダプタで直接話す (互換戦略 A)
#
#   Streamlabs (モック) のアラート → Streamlabs アダプタ (ingress セル) → ext.streamlabs.event.<type>
#   - トークンは環境変数だけで渡し、ログには出ない (プロトコル上 URL に載るので URL もログに出さない)
#   - サーバーが指定した pingInterval ごとに ping ("2") を送る
#   - 不正なトークンは接続エラー ("44") で拒否され、WEAVE 本体は動き続ける
#
# 実サービス (sockets.streamlabs.com) には接続しない。トークンはモック専用の偽値。
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=./zig-out/bin
DIR=$(mktemp -d)
TOKEN=e2e-fake-socket-token
cleanup() {
  for p in ${MS:-} ${W:-} ${EC:-} ${W2:-}; do kill -9 "$p" 2>/dev/null || true; done
  echo "logs: $DIR"
}
trap cleanup EXIT INT TERM

URL="ws://127.0.0.1:9181/socket.io/?EIO=3&transport=websocket"

# 1. モックより先に WEAVE と Inspector の購読を立ち上げる (接続失敗 → 再接続も確かめる)
STREAMLABS_SOCKET_TOKEN=$TOKEN "$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3081 --node-port 8081 --no-snapshot --introspection contents \
  --streamlabs-url "$URL" > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 50); do grep -q "Ready in" "$DIR/weave.log" 2>/dev/null && break; sleep 0.1; done
"$BIN/weave" topic echo 'ext.streamlabs.#' --url ws://127.0.0.1:3081/ws > "$DIR/echo.log" 2>&1 &
EC=$!
sleep 0.5
"$BIN/weave-bridge" mock-streamlabs --port 9181 --token $TOKEN --count 5 --interval-ms 150 --ping-interval-ms 300 > "$DIR/sl.log" 2>&1 &
MS=$!

for _ in $(seq 1 100); do [ "$(grep -c 'ext.streamlabs.event' "$DIR/echo.log" 2>/dev/null || true)" -ge 5 ] && break; sleep 0.1; done
N=$(grep -c 'ext.streamlabs.event' "$DIR/echo.log" || true)
[ "$N" -ge 5 ] || { echo "FAIL: expected events, got $N"; cat "$DIR/sl.log"; tail -20 "$DIR/weave.log"; exit 1; }
grep -q '"platform"' "$DIR/echo.log" || { echo "FAIL: payload not forwarded"; exit 1; }
grep -q 'ext.streamlabs.event.donation' "$DIR/echo.log" || { echo "FAIL: donation missing"; exit 1; }
echo "Streamlabs events -> WEAVE: OK ($N events)"

for _ in $(seq 1 30); do grep -q 'ping 2' "$DIR/sl.log" 2>/dev/null && break; sleep 0.1; done
grep -q 'ping 2' "$DIR/sl.log" || { echo "FAIL: client did not ping on pingInterval"; cat "$DIR/sl.log"; exit 1; }
echo "Engine.IO ping on pingInterval: OK ($(grep -c 'ping ' "$DIR/sl.log") pings)"

STREAMLABS_SOCKET_TOKEN=wrong-token "$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs2.jsonl" \
  --dash-port 3082 --node-port 8082 --no-snapshot --streamlabs-url "$URL" > "$DIR/weave2.log" 2>&1 &
W2=$!
for _ in $(seq 1 50); do grep -q 'connection refused by the server' "$DIR/weave2.log" 2>/dev/null && break; sleep 0.1; done
grep -q 'connection refused by the server' "$DIR/weave2.log" || { echo "FAIL: bad token was not rejected"; tail -20 "$DIR/weave2.log"; exit 1; }
kill -0 $W2 || { echo "FAIL: WEAVE died on a rejected token"; exit 1; }
echo "bad token -> rejected, core keeps running: OK"

if grep -q -e "$TOKEN" -e 'wrong-token' "$DIR/weave.log" "$DIR/weave2.log"; then echo "FAIL: token leaked into logs"; exit 1; fi
echo "token not in logs: OK"
echo "PASS"
