#!/usr/bin/env bash
# E2E: egress セルを別プロセスにする (ADR-010 Level 2 段階 1)
#   --isolate-egress で OBS への送信役 (ObsEgress) を weave-cell として別プロセスで動かし、
#   表示中に kill -9 する。Core と他のセルは止まらず、子はすぐ起動し直され、Core が持っている
#   「意図した OBS の状態」が送り直される。その後の自動非表示と 2 回目の表示も新しい子から OBS に届く。
#   終了時は子も一緒に片付く。
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
cleanup() { kill -INT "${W:-0}" 2>/dev/null || true; sleep 0.5; kill -9 "${W:-0}" 2>/dev/null || true; pkill -9 -f "weave-cell egress --socket $DIR/" 2>/dev/null || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM
cell_pid() { pgrep -f "weave-cell egress --socket $DIR/state/egress.sock" | head -1 || true; }

"$BIN/WEAVE" --isolate-egress --mock-twitch demo/scenarios/record.jsonl --mock-twitch-once --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3067 --node-port 8067 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" \
  wasm-apps/kusa_node.wasm > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 60); do grep -q '"sceneItemEnabled":true' "$DIR/obs.jsonl" 2>/dev/null && break; sleep 0.1; done
C1=$(cell_pid)
[ -n "$C1" ] || { echo "FAIL: weave-cell is not running"; exit 1; }
echo "egress cell pid $C1 (Core pid $W); overlay shown → kill -9 the egress cell"
kill -9 "$C1"
for _ in $(seq 1 50); do C2=$(cell_pid); [ -n "$C2" ] && [ "$C2" != "$C1" ] && break; sleep 0.05; done
sleep 8.5
kill -0 "$W" || { echo "FAIL: Core died with the egress cell"; exit 1; }
[ -n "${C2:-}" ] && [ "$C2" != "$C1" ] || { echo "FAIL: the egress cell was not restarted"; exit 1; }
grep -o "Recovery: 'ObsEgress'.*after [0-9]* ms" "$DIR/weave.log" | head -1
grep -q "re-sent 1 desired OBS state" "$DIR/weave.log" || { echo "FAIL: desired state was not re-sent"; exit 1; }
SEQ=$(python3 -c '
import json,sys
print(" ".join("on" if json.loads(l)["payload"]["sceneItemEnabled"] else "off" for l in open(sys.argv[1]) if l.strip()))' "$DIR/obs.jsonl")
echo "OBS requests: $SEQ"
[ "$SEQ" = "on on off on" ] || { echo "FAIL: expected show, re-applied show, auto-hide, show again"; exit 1; }
kill -INT "$W"
for _ in $(seq 1 40); do kill -0 "$W" 2>/dev/null || break; sleep 0.05; done
kill -0 "$W" 2>/dev/null && { echo "FAIL: Core did not exit"; exit 1; }
[ -z "$(cell_pid)" ] || { echo "FAIL: the egress cell outlived Core"; exit 1; }
echo "PASS"
