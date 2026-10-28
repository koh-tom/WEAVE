#!/usr/bin/env bash
# E2E: 利用者による承認 (トラストアンカー Stage 0)。--approval-mode strict で:
#   1. 承認していないプラグインは読み込まない (core.security.approval_required、稼働状態には「承認待ち」)
#   2. weave add で承認すると読み込み、動く (OBS mock にテキストが届く)
#   3. 更新で manifest の権限が増えたら (StopStream) 読み込まない。weave add は増えた分に ★ を付けて見せる
#   4. 再承認すると読み込む
#   5. 権限が増えていないコードの更新 (wasm に custom section を足す) はそのまま通す
#   6. weave list で承認したものと今の状態が見え、プラグインを指定しない weave run で承認したものが起動する。
#      weave remove で取り消すと、もう起動しない
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=$(pwd)/zig-out/bin
DIR=$(mktemp -d)
W=0
stop() { [ "$W" -gt 0 ] || return 0; kill -INT "$W" 2>/dev/null || true; for _ in $(seq 1 40); do kill -0 "$W" 2>/dev/null || break; sleep 0.05; done; kill -9 "$W" 2>/dev/null || true; W=0; }
cleanup() { stop || true; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$DIR/p"
cp wasm-apps/countdown.wasm wasm-apps/countdown.json "$DIR/p/"
P="$DIR/p/countdown.wasm"
A="$DIR/approved.json"

# $1 = ログ名。strict で起動して Running まで待つ
run() {
  : > "$DIR/obs_$1.jsonl"
  "$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs_$1.jsonl" --approval-mode strict --approvals "$A" \
    --dash-port 3071 --node-port 8071 --audit-log "$DIR/audit_$1.log" --state-dir "$DIR/state" --dashboard-token ap \
    ${P:+"$P"} > "$DIR/$1.log" 2>&1 &
  W=$!
  for _ in $(seq 1 60); do grep -q "Running" "$DIR/$1.log" 2>/dev/null && break; sleep 0.05; done
  grep -q "Running" "$DIR/$1.log" || fail "$1: WEAVE did not start"
}
loaded() { grep -q "Loaded plugin 'countdown'" "$DIR/$1.log"; }

# 1. 未承認
run unapproved
loaded unapproved && fail "unapproved plugin was loaded"
grep -q "Approval: REJECTED 'countdown' — まだ承認されていません" "$DIR/unapproved.log" || fail "no rejection log"
grep -q '"topic":"core.security.approval_required".*"reason":"not_approved"' "$DIR/audit_unapproved.log" || fail "approval_required not in the audit log"
# 稼働状態 (/status と同じ core.health.summary) には「起動していない」ではなく「承認待ち」と出る
timeout 2 "$BIN/weave" topic echo core.health.summary --url ws://127.0.0.1:3071/ws --token ap > "$DIR/health.jsonl" 2>/dev/null || true
grep -q '"node":"countdown","status":"approval_required"' "$DIR/health.jsonl" || fail "health summary does not say the plugin awaits approval"
stop
echo "ok 1: 未承認のプラグインは読み込まない (監査ログと稼働状態に「承認待ち」)"

# 2. 承認 → 読み込んで動く
echo y | "$BIN/weave" add "$P" --approvals "$A" > "$DIR/add1.txt"
grep -q "はじめて入れます" "$DIR/add1.txt" || fail "weave add did not explain a first install"
grep -q "配信画面の文字などの中身を変える" "$DIR/add1.txt" || fail "permission not described in plain words"
run approved
loaded approved || fail "approved plugin was not loaded"
"$BIN/weave" topic pub ext.countdown.cmd '{"cmd":"start","seconds":1,"source":"Timer","final":"Go!"}' \
  --url ws://127.0.0.1:3071/ws --token ap > /dev/null 2>&1
for _ in $(seq 1 60); do grep -q "Go!" "$DIR/obs_approved.jsonl" 2>/dev/null && break; sleep 0.05; done
grep -q "Go!" "$DIR/obs_approved.jsonl" || fail "approved plugin did not reach OBS"
stop
echo "ok 2: weave add で承認したプラグインは読み込まれ、OBS (mock) まで届く"

# 3. 更新で権限が増える (配信の停止)
python3 - "$DIR/p/countdown.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
m["permissions"]["publish"].append("core.obs.request.StopStream")
json.dump(m, open(p, "w"), indent=2)
PY
run increased
loaded increased && fail "plugin with new permissions was loaded"
grep -q "権限が増えています: +publish core.obs.request.StopStream" "$DIR/increased.log" || fail "the added permission was not named"
stop
echo n | "$BIN/weave" add "$P" --approvals "$A" > "$DIR/add2.txt" && fail "answering n should not approve"
grep -q "★ 配信・録画を始める / 止める  ⚠ 強い権限" "$DIR/add2.txt" || fail "weave add did not mark the new strong permission"
grep -q "SetInputSettings" "$DIR/add2.txt" || fail "existing permission should still be listed"
grep -q "★ 配信画面の文字" "$DIR/add2.txt" && fail "an existing permission was marked as new"
echo "ok 3: 権限が増えたら読み込まず、増えた分 (StopStream) だけに ★ を付けて再承認を求める"

# 4. 再承認
"$BIN/weave" add "$P" --approvals "$A" --yes > /dev/null
run reapproved
loaded reapproved || fail "re-approved plugin was not loaded"
stop
echo "ok 4: 再承認すると読み込む"

# 5. 権限は同じでコードだけ変わる (custom section "test" = "!")
printf '\x00\x06\x04test!' >> "$P"
run codeonly
loaded codeonly || fail "code-only update was not loaded"
grep -q "permissions did not grow — allowed" "$DIR/codeonly.log" || fail "code-only update not logged"
stop
echo "ok 5: 権限が増えていないコードの更新はそのまま通す"

# 6. 一覧・指定なしの起動・取り消し
"$BIN/weave" list --approvals "$A" > "$DIR/list.txt"
grep -q "countdown 1.0.0" "$DIR/list.txt" || fail "weave list does not show the plugin"
grep -q "状態: 更新されています (権限は増えていないので、そのまま起動します)" "$DIR/list.txt" || fail "weave list does not explain the current state"
grep -q "$P" "$DIR/list.txt" || fail "weave list does not show where the plugin is"
P_SAVE=$P; P=""   # 以降の run はプラグインを指定しない
run noargs
loaded noargs || fail "weave run without plugins did not start the approved plugin"
grep -q "starting 1 plugin(s) approved with weave add" "$DIR/noargs.log" || fail "no message about starting approved plugins"
stop
"$BIN/weave" remove countdown --approvals "$A" 2> "$DIR/remove.txt"
grep -q "承認を取り消しました" "$DIR/remove.txt" || fail "weave remove did not confirm"
run removed
loaded removed && fail "a removed plugin was started"
stop
P=$P_SAVE
echo "ok 6: weave list で状態が見え、指定なしの weave run で承認済みが起動し、weave remove で止まる"
echo "PASS"
