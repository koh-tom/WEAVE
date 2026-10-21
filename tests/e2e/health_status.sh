#!/usr/bin/env bash
# E2E: 稼働状態 (core.health.summary) と観測専用インターフェース (/status)
#   1. 起動忘れ: score_tool を --expect で「本来いるはず」と宣言し、起動しない
#      → score_tool は missing、それだけを頼りにする scoreboard は「入力を失って沈黙」、原因は score_tool
#   2. 観測専用トークンで繋いだ端末には core.health.* しか届かず、publish は拒否されて監査ログに残る
#   3. 暴走したプラグインが自動で戻ると、それが「最近の自動復帰」に載る
#   4. manifest の 1 文字の typo を起動時に見つけ、正しい名前の候補を出す
#   5. /status (スマホ向けの観測専用ページ) が配信される
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
PORT=3061
URL="ws://127.0.0.1:$PORT/ws"
cleanup() {
  kill -INT "${W:-0}" "${W2:-0}" 2>/dev/null || true; sleep 0.3
  kill -9 "${W:-0}" "${W2:-0}" 2>/dev/null || true
  echo "logs: $DIR"
}
trap cleanup EXIT INT TERM

# --dashboard-dist dashboard/public: CI ではダッシュボードをビルドしないので、ソースの status.html をそのまま配る
"$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port $PORT --node-port 8061 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" \
  --dashboard-dist dashboard/public --dashboard-token fulltok --observer-token viewtok \
  --expect wasm-apps/score_tool.json \
  wasm-apps/scoreboard.wasm wasm-apps/loop_node.wasm > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 100); do grep -q "Ready in" "$DIR/weave.log" 2>/dev/null && break; sleep 0.1; done

# --- 1 + 2: 観測専用の端末が受け取るもの ---
timeout 2 "$BIN/weave" topic echo --url "$URL" --token viewtok > "$DIR/viewer.jsonl" 2>/dev/null || true
[ -s "$DIR/viewer.jsonl" ] || { echo "FAIL: the status viewer received nothing"; exit 1; }
if grep -v '"topic":"core.health.summary"' "$DIR/viewer.jsonl" | grep -q .; then
  echo "FAIL: the status viewer received something other than core.health.*:"; grep -v '"topic":"core.health.summary"' "$DIR/viewer.jsonl" | head -3; exit 1
fi
LAST=$(tail -1 "$DIR/viewer.jsonl")
echo "$LAST" | grep -q '"node":"score_tool","status":"missing"' || { echo "FAIL: score_tool was not reported as missing"; echo "$LAST"; exit 1; }
echo "$LAST" | grep -q '"node":"scoreboard","effect":"stalled","because":\["score_tool"\]' || { echo "FAIL: scoreboard was not reported as stalled because of score_tool"; echo "$LAST"; exit 1; }
echo "ok: missing score_tool → scoreboard stalled (cause: score_tool)"

"$BIN/weave" topic pub --url "$URL" --token viewtok ext.twitch.chat.message '{"user":"x","message":"hello"}' >/dev/null 2>&1 || true
sleep 0.3
grep -q '"detail":"status viewer cannot publish"' "$DIR/audit.log" || { echo "FAIL: a publish from the status viewer was not denied/audited"; exit 1; }
echo "ok: the status viewer cannot publish (audited)"

# --- 3: 暴走 → 自動復帰が recent に載る ---
"$BIN/weave" topic pub --url "$URL" --token fulltok ext.twitch.chat.message '{"user":"x","message":"!freeze"}' >/dev/null 2>&1
for _ in $(seq 1 50); do grep -q "Recovery: 'loop_node'" "$DIR/weave.log" && break; sleep 0.1; done
timeout 1.5 "$BIN/weave" topic echo --url "$URL" --token viewtok > "$DIR/viewer2.jsonl" 2>/dev/null || true
tail -1 "$DIR/viewer2.jsonl" | grep -q '"recent":\[{"node":"loop_node"' || { echo "FAIL: the recovery of loop_node is not in recent"; tail -1 "$DIR/viewer2.jsonl"; exit 1; }
echo "ok: loop_node's automatic recovery is shown to the viewer"

# --- 5: /status ---
curl -fsS "http://127.0.0.1:$PORT/status" | grep -q "配信の状態" || { echo "FAIL: /status is not served"; exit 1; }
echo "ok: /status is served"
kill -0 $W || { echo "FAIL: WEAVE died"; exit 1; }

# --- 4: typo を起動時に見つける (subgoal の manifest で 1 文字だけ間違えた写し) ---
cp wasm-apps/subgoal.wasm "$DIR/subgoal.wasm"
sed 's/"ext\.twitch\.chat\.message"/"ext.twich.chat.message"/' wasm-apps/subgoal.json > "$DIR/subgoal.json"
"$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs2.jsonl" \
  --dash-port 3062 --node-port 8062 --audit-log "$DIR/audit2.log" --state-dir "$DIR/state2" \
  "$DIR/subgoal.wasm" > "$DIR/weave2.log" 2>&1 &
W2=$!
for _ in $(seq 1 100); do grep -q "Ready in" "$DIR/weave2.log" 2>/dev/null && break; sleep 0.1; done
grep -q "Lint: 'subgoal' subscribes to 'ext.twich.chat.message'.*Did you mean 'ext.twitch.chat.message'" "$DIR/weave2.log" \
  || { echo "FAIL: the typo was not caught at startup"; grep Lint "$DIR/weave2.log" || true; exit 1; }
echo "ok: typo caught at startup → did you mean 'ext.twitch.chat.message'"
echo "PASS"
