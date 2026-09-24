#!/usr/bin/env bash
# E2E: 実在する OBS 同梱スクリプト (Countdown) の振る舞いを WEAVE のプラグインとして動かす (C3)
#   weave topic pub で開始 → 実時間の tick で毎秒テキストソースを更新 → 終了メッセージ。
#   OBS への要求は core.obs.request.SetInputSettings だけ (manifest の宣言どおり)。
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
cleanup() { kill -INT "${W:-0}" 2>/dev/null || true; sleep 0.3; kill -9 "${W:-0}" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

"$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3069 --node-port 8069 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" --dashboard-token cd \
  wasm-apps/countdown.wasm > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 50); do grep -q "Running" "$DIR/weave.log" 2>/dev/null && break; sleep 0.05; done
"$BIN/weave" topic pub ext.countdown.cmd '{"cmd":"start","seconds":3,"source":"Timer","final":"Go!"}' \
  --url ws://127.0.0.1:3069/ws --token cd > /dev/null 2>&1
sleep 4.5
TEXTS=$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    x=json.loads(l)
    if x["topic"].endswith("SetInputSettings"): print(x["payload"]["inputSettings"]["text"])
' "$DIR/obs.jsonl" | tr '\n' ' ')
echo "Timer showed: $TEXTS"
[ "$TEXTS" = "00:00:03 00:00:02 00:00:01 Go! " ] || { echo "FAIL: unexpected sequence"; exit 1; }
grep -q acl_denied "$DIR/audit.log" 2>/dev/null && { echo "FAIL: countdown hit the ACL"; exit 1; }
echo "PASS"
