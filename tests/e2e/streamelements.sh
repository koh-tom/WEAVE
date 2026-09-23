#!/usr/bin/env bash
# E2E: StreamElements Astro を Core のアダプタで直接話す (互換戦略 A)
#
#   Astro (モック) の channel.activities → StreamElements アダプタ (ingress セル)
#     → ext.streamelements.activity.<type> → Inspector で観測
#   - JWT は環境変数だけで渡し、ログには出ない
#   - サーバーの PING に PONG を返す (実サービスは 70 秒 PONG が無いと切断する)
#   - 不正な JWT は err_unauthorized で拒否され、WEAVE 本体は動き続ける
#
# 実サービス (astro.streamelements.com) には接続しない。JWT はモック専用の偽値。
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=./zig-out/bin
DIR=$(mktemp -d)
JWT=e2e-fake-jwt-not-a-secret
cleanup() {
  # 未設定の PID を 0 にすると kill -9 0 でプロセスグループごと殺してしまうので、起動したものだけ
  for p in ${MA:-} ${W:-} ${EC:-} ${W2:-}; do kill -9 "$p" 2>/dev/null || true; done
  echo "logs: $DIR"
}
trap cleanup EXIT INT TERM

# 1. モックより先に WEAVE を起動する (接続失敗 → バックオフで再接続することも確かめる)
STREAMELEMENTS_JWT=$JWT "$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3078 --node-port 8078 --no-snapshot --introspection contents \
  --streamelements-channel e2e-channel --streamelements-url ws://127.0.0.1:9178/ > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 50); do grep -q "Ready in" "$DIR/weave.log" 2>/dev/null && break; sleep 0.1; done

"$BIN/weave" topic echo 'ext.streamelements.#' --url ws://127.0.0.1:3078/ws > "$DIR/echo.log" 2>&1 &
EC=$!
sleep 0.5

"$BIN/weave-bridge" mock-astro --port 9178 --jwt $JWT --count 5 --interval-ms 50 > "$DIR/astro.log" 2>&1 &
MA=$!

for _ in $(seq 1 100); do [ "$(grep -c 'ext.streamelements.activity' "$DIR/echo.log" 2>/dev/null || true)" -ge 5 ] && break; sleep 0.1; done
N=$(grep -c 'ext.streamelements.activity' "$DIR/echo.log" || true)
[ "$N" -ge 5 ] || { echo "FAIL: expected 5 activities, got $N"; tail -5 "$DIR/astro.log"; tail -20 "$DIR/weave.log"; exit 1; }
grep -q 'ext.streamelements.activity.tip' "$DIR/echo.log" || { echo "FAIL: tip activity missing"; exit 1; }
grep -q 'se_viewer2' "$DIR/echo.log" || { echo "FAIL: payload not forwarded"; exit 1; }
echo "Astro channel.activities -> WEAVE: OK ($N events)"

for _ in $(seq 1 20); do grep -q 'pongs' "$DIR/astro.log" 2>/dev/null && break; sleep 0.1; done
grep -q 'pongs 5/5' "$DIR/astro.log" || { echo "FAIL: PING was not answered"; cat "$DIR/astro.log"; exit 1; }
echo "PING -> PONG: OK"

# 2. 不正な JWT: 拒否され、WEAVE 本体は落ちない
STREAMELEMENTS_JWT=wrong-token "$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs2.jsonl" \
  --dash-port 3079 --node-port 8079 --no-snapshot \
  --streamelements-channel e2e-channel --streamelements-url ws://127.0.0.1:9178/ > "$DIR/weave2.log" 2>&1 &
W2=$!
for _ in $(seq 1 50); do grep -q 'err_unauthorized' "$DIR/weave2.log" 2>/dev/null && break; sleep 0.1; done
grep -q 'err_unauthorized' "$DIR/weave2.log" || { echo "FAIL: bad JWT was not rejected"; tail -20 "$DIR/weave2.log"; exit 1; }
kill -0 $W2 || { echo "FAIL: WEAVE died on a rejected JWT"; exit 1; }
echo "bad JWT -> err_unauthorized, core keeps running: OK"

# 3. JWT はログに出ない
if grep -q -e "$JWT" -e 'wrong-token' "$DIR/weave.log" "$DIR/weave2.log"; then echo "FAIL: JWT leaked into logs"; exit 1; fi
echo "JWT not in logs: OK"
echo "PASS"
