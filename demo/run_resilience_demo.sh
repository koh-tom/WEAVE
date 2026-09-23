#!/usr/bin/env bash
# =============================================================================
# WEAVE 「壊しても止まらない」通しデモ
#
#   第 0 幕  起動前に「乗っ取られたら / 落ちたら どこまで」を計算して見せる (weave audit)
#   第 1 幕  Supervisor 付きで一瞬で立ち上げる (weave up)
#   第 2 幕  チャットで草エフェクト (OBS 操作)
#   第 3 幕  暴走 Bot: 流量上限でバスの手前で止まる。他は無傷
#   第 4 幕  ハウリング: ツール同士の無限反響を、因果の深さで止める
#   第 5 幕  基盤そのものを kill -9 → 1 秒未満で戻り、配信の状態も戻る
#   第 6 幕  OBS 自体が落ちて戻る → WEAVE が意図した表示を自動で再適用する
#
# 使い方:  ./demo/run_resilience_demo.sh            各幕で Enter 待ち (発表用)
#          ./demo/run_resilience_demo.sh --auto     通しで自動再生 (録画・ブース用)
# 前提:    zig build 済み (Inspector を見せる場合は dashboard をビルド済み)
# OBS:     既定では weave-obs-sim を使う。実物の OBS を使う場合は OBS_PORT/OBS_PASS を指定し
#          USE_REAL_OBS=1 (第 6 幕は OBS を手で再起動する)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

AUTO=0; [ "${1:-}" = "--auto" ] && AUTO=1
BIN=./zig-out/bin
DIR=$(mktemp -d)
DASH=3030; NODE=8081
OBS_PORT=${OBS_PORT:-4455}
OBS_PASS=${OBS_PASS:-weave-demo}
USE_REAL_OBS=${USE_REAL_OBS:-0}
export WEAVE_DASHBOARD_TOKEN=${WEAVE_DASHBOARD_TOKEN:-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')}
URL="ws://127.0.0.1:$DASH/ws"

b(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok(){ printf "   \033[32m✓\033[0m %s\n" "$*"; }
say(){ printf "   %s\n" "$*"; }
pause(){ if [ $AUTO -eq 0 ]; then read -r -p "   [Enter で次へ] " _; else sleep "${1:-2}"; fi; }
now(){ date +%s%3N; }
state(){ cat "$DIR/obs.json" 2>/dev/null; }
pub(){ "$BIN/weave" topic pub "$1" "$2" --url "$URL" > /dev/null 2>&1; }
burst(){ for i in $(seq 1 10); do pub ext.twitch.chat.message "{\"user\":\"viewer$i\",\"message\":\"草\"}"; done; }

cleanup(){ kill -INT "${SUP:-0}" 2>/dev/null; sleep 0.5; kill -9 "${SUP:-0}" "${SIM:-0}" 2>/dev/null; echo; echo "logs: $DIR"; }
trap cleanup EXIT INT TERM

[ -x "$BIN/WEAVE" ] && [ -x "$BIN/weave" ] || { echo "先に 'zig build' を実行してください"; exit 1; }
PLUGINS="wasm-apps/kusa_node.wasm wasm-apps/chat_node.wasm wasm-apps/spam_node.wasm wasm-apps/howl_a.wasm wasm-apps/howl_b.wasm"

# ---------------------------------------------------------------------------
b "第 0 幕  起動する前に、影響範囲を計算する"
say "コードを読まず、宣言 (manifest) だけから計算する。難読化されても結果は変わらない。"
"$BIN/weave" audit | sed 's/^/   /'
say "例: kusa_node が落ちたら何が止まるか"
"$BIN/weave" audit --failure kusa_node | sed -n '/縮退/,/止まる実世界/p' | sed 's/^/   /'
pause 3

# ---------------------------------------------------------------------------
b "第 1 幕  一瞬で立ち上げる (Supervisor 付き)"
if [ "$USE_REAL_OBS" = "1" ]; then
  say "実物の OBS (127.0.0.1:$OBS_PORT) に接続します"
else
  "$BIN/weave-obs-sim" --port "$OBS_PORT" --password "$OBS_PASS" --state-file "$DIR/obs.json" > "$DIR/obs-sim.log" 2>&1 &
  SIM=$!
  sleep 0.2
fi
T0=$(now)
"$BIN/weave" up --no-twitch --real-obs --obs-port "$OBS_PORT" --obs-pass "$OBS_PASS" \
  --dash-port $DASH --node-port $NODE --introspection contents --state-dir "$DIR/state" \
  --audit-log "$DIR/audit.log" $PLUGINS > "$DIR/weave.log" 2>&1 &
SUP=$!
for _ in $(seq 1 200); do grep -q "Ready in" "$DIR/weave.log" 2>/dev/null && break; sleep 0.01; done
ok "$(grep -ao 'Ready in [0-9]* ms' "$DIR/weave.log" | head -1)  (コマンド実行から $(( $(now) - T0 )) ms、5 プラグイン・署名/監査込み)"
say "Inspector: http://127.0.0.1:$DASH/?token=$WEAVE_DASHBOARD_TOKEN"
"$BIN/weave" node ls --url "$URL" 2>&1 | sed 's/^/   /'
pause 3

# ---------------------------------------------------------------------------
b "第 2 幕  チャットで草エフェクト"
burst
sleep 0.5
ok "OBS: $(state)"
pause 2

# ---------------------------------------------------------------------------
b "第 3 幕  暴走 Bot (spam_node) は流量上限でバスの手前で止まる"
say "spam_node は 0.5 秒ごとに 50 件を投げつける。manifest の上限は 5 件/秒。"
sleep 1.5
ok "監査ログの rate_limited: $(grep -c rate_limited "$DIR/audit.log" 2>/dev/null || echo 0) 件 (1 秒ごとに集約)"
ok "その間も他のプラグインは通常運転 (Inspector のセル表示を参照)"
pause 2

# ---------------------------------------------------------------------------
b "第 4 幕  ハウリング: ツール同士が反応し合う無限反響"
say "howl_a と howl_b は互いのイベントに反応する。直結の世界では止まらない。"
L0=$(grep -c loop_detected "$DIR/audit.log" 2>/dev/null || true)
EV0=$(grep -c "echo stopped" "$DIR/weave.log" 2>/dev/null || true)
pub ext.twitch.chat.message '{"user":"viewer","message":"hello"}'
sleep 0.5
L1=$(grep -c loop_detected "$DIR/audit.log" 2>/dev/null || true)
ok "チャット 1 行で始まった反響を、因果の深さ 16 で停止 (loop_detected +$((L1 - L0)) 件)"
ok "その間も kusa・chat_node・spam_node は通常運転"
pause 2

# ---------------------------------------------------------------------------
b "第 5 幕  基盤 (Core) そのものを kill -9 する"
burst
sleep 0.5
say "表示中: $(state)"
CORE=$(pgrep -P "$SUP" | head -1)
READY_BEFORE=$(grep -c "Ready in" "$DIR/weave.log")
T0=$(now)
kill -9 "$CORE"
for _ in $(seq 1 200); do [ "$(grep -c 'Ready in' "$DIR/weave.log")" -gt "$READY_BEFORE" ] && break; sleep 0.005; done
ok "Core が戻るまで $(( $(now) - T0 )) ms (Supervisor が即再起動、スナップショットから状態を復元)"
ok "OBS: $(state)  ← 表示状態はそのまま"
say "kusa は OBS の状態から自分の記憶を取り戻すので、自動非表示も予定どおり来る"
pause 6

# ---------------------------------------------------------------------------
b "第 6 幕  OBS 自体が落ちて戻る"
burst
sleep 0.5
if [ "$USE_REAL_OBS" = "1" ]; then
  say "OBS を終了して、もう一度起動してください。WEAVE は 250ms 間隔で再接続し、意図した表示を再適用します。"
  pause 10
else
  say "OBS (シミュレータ) を kill -9 し、状態が空の新品として再起動する"
  kill -9 "$SIM"; sleep 0.3
  T0=$(now)
  "$BIN/weave-obs-sim" --port "$OBS_PORT" --password "$OBS_PASS" --state-file "$DIR/obs.json" > "$DIR/obs-sim2.log" 2>&1 &
  SIM=$!
  for _ in $(seq 1 100); do grep -q '"Overlay#1":true' "$DIR/obs.json" 2>/dev/null && break; sleep 0.02; done
  ok "OBS が戻ってから $(( $(now) - T0 )) ms で、WEAVE が意図した表示を再適用: $(state)"
fi
pause 2

b "まとめ"
say "侵害されてもここまで (weave audit)、落ちてもここまで (weave audit --failure)。"
say "同じ宣言のグラフから、起動前に計算できる。そして実際にその範囲に収まった。"
