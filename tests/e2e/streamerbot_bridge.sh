#!/usr/bin/env bash
# E2E: 既存ツール (Streamer.bot) を WEAVE に繋ぐ (互換戦略 C)
#
#   Streamer.bot (モック) のチャット → weave-bridge → WEAVE (remote セル, manifest で権限検査)
#     → ext.twitch.chat.message に正規化 → kusa_node → OBS (mock) で草エフェクト
#   Inspector から ext.streamerbot.action.request → weave-bridge → Streamer.bot の DoAction
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=./zig-out/bin
DIR=$(mktemp -d)
TOKEN=e2e-node-token
cleanup() { kill -9 "${SB:-0}" "${W:-0}" "${BR:-0}" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

"$BIN/weave-bridge" mock-streamerbot --port 8076 --password sbpass --chat "草" --count 10 --interval-ms 50 --actions-log "$DIR/actions.jsonl" > "$DIR/sb.log" 2>&1 &
SB=$!
WEAVE_NODE_WS_TOKEN=$TOKEN "$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3076 --node-port 8077 wasm-apps/kusa_node.wasm > "$DIR/weave.log" 2>&1 &
W=$!
sleep 0.5
"$BIN/weave-bridge" --weave ws://127.0.0.1:8077/ --token $TOKEN --streamerbot ws://127.0.0.1:8076/ --password sbpass > "$DIR/bridge.log" 2>&1 &
BR=$!

for _ in $(seq 1 60); do grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" 2>/dev/null && break; sleep 0.1; done
grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" || { echo "FAIL: Streamer.bot chat did not reach kusa_node"; tail -5 "$DIR/bridge.log"; tail -20 "$DIR/weave.log"; exit 1; }
echo "Streamer.bot chat -> WEAVE -> kusa -> OBS: OK"

"$BIN/weave" topic pub ext.streamerbot.action.request '{"name":"Shoutout","args":{"user":"koh"}}' --url ws://127.0.0.1:3076/ws > /dev/null
for _ in $(seq 1 30); do grep -q 'Shoutout' "$DIR/actions.jsonl" 2>/dev/null && break; sleep 0.1; done
grep -q '"DoAction"' "$DIR/actions.jsonl" || { echo "FAIL: DoAction did not reach Streamer.bot"; exit 1; }
echo "WEAVE -> Streamer.bot DoAction: OK ($(cat "$DIR/actions.jsonl"))"

grep -q "remote node 'remote.streamerbot' joined" "$DIR/weave.log" || { echo "FAIL: bridge did not join as a remote node"; exit 1; }
echo "PASS"
