#!/usr/bin/env bash
# E2E: OBS が断った操作を、どのプラグインの・どの名前への操作かと「もしかして」付きで配信者に伝える
#   1. OBS (シミュレータ) には "Score Board" しか無いのに、scoreboard は "Scoreboard" に書く
#      → core.health.summary (/status) に「scoreboard の操作が OBS に断られている。もしかして Score Board?」
#   2. OBS 側の名前を直して OBS を起動し直すと、WEAVE が意図した表示を送り直し、問題の表示は消える
#   3. OBS への送信役を別プロセスにしても (--isolate-egress)、どのプラグインの操作かが分かる
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
PORT=4478
URL=ws://127.0.0.1:3078/ws
SIM=0; W=0
kill_pid() { [ "$1" -gt 0 ] || return 0; kill -INT "$1" 2>/dev/null || true; for _ in $(seq 1 40); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.05; done; kill -9 "$1" 2>/dev/null || true; }
cleanup() { kill_pid "$W"; kill_pid "$SIM"; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*"; exit 1; }

sim() { "$BIN/weave-obs-sim" --port $PORT --inputs "$1" --scenes Overlay --state-file "$DIR/obs.json" > "$DIR/sim_$2.log" 2>&1 & SIM=$!; sleep 0.3; }
weave() {
  "$BIN/WEAVE" --real-obs --obs-port $PORT --no-twitch --dash-port 3078 --node-port 8078 --dashboard-token nm \
    --state-dir "$DIR/state" --audit-log "$DIR/audit_$1.log" $2 wasm-apps/scoreboard.wasm > "$DIR/weave_$1.log" 2>&1 & W=$!
  for _ in $(seq 1 60); do grep -q "Ready in" "$DIR/weave_$1.log" 2>/dev/null && break; sleep 0.05; done
}
# core.health.summary の最新を 1 つ取り出す
summary() { timeout 1.5 "$BIN/weave" topic echo core.health.summary --url $URL --token nm 2>/dev/null | tail -1 || true; }
wait_summary() { # pattern tries
  for _ in $(seq 1 "$2"); do S=$(summary); echo "$S" | grep -q "$1" && return 0; done; return 1
}

# 1
sim "Score Board,SubGoal" 1
weave plain ""
wait_summary '"plugin":"scoreboard","request":"SetInputSettings","target":"Scoreboard"' 4 || fail "the refused request was not reported with the plugin name"
echo "$S" | grep -q '"suggestion":"Score Board"' || fail "no suggestion of the closest OBS name"
echo "$S" | grep -q 'もしかして「Score Board」' || fail "no plain-language action"
echo "$S" | grep -q '"overall":"trouble"' || fail "overall should be trouble"
echo "ok 1: OBS に断られた操作を、プラグイン名と「もしかして Score Board」付きで出す"

# 2
kill_pid "$SIM"; SIM=0
sim "Scoreboard,SubGoal" 2
wait_summary '"obs_problems":\[\]' 6 || fail "the problem did not clear after OBS was fixed"
echo "ok 2: OBS の名前を直して起動し直すと、表示が送り直されて問題は消える"
kill_pid "$W"; W=0; kill_pid "$SIM"; SIM=0

# 3
sim "Score Board" 3
weave isolated "--isolate-egress"
wait_summary '"plugin":"scoreboard","request":"SetInputSettings","target":"Scoreboard"' 6 || fail "isolated egress lost who sent the request"
echo "ok 3: OBS への送信役が別プロセスでも、どのプラグインの操作かが分かる"
echo "PASS"
