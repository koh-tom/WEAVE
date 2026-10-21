#!/usr/bin/env bash
# =============================================================================
# demo/run_health_demo.sh — 「どこが壊れたか、分かりますか?」(weave demo health)
#
#   原体験の再現: 競技イベントの運営で、スコア係のツールを起動し忘れた。配信画面のスコア表示は
#   0-0 のまま固まったが、見た目は正常なので誰も気づかず、原因が分からないまま進行が約 30 分遅れた。
#
#   第 1 幕 今までの世界: スコア係 (score_tool) を起動していない。どこにも警告は出ない。スコアは 0-0 のまま
#   第 2 幕 WEAVE: 構成を宣言 (--expect) しておくと、起動していないことと、それで止まった機能が出る
#             Inspector と、観測専用のスマホ画面 (/status) の両方に出る
#   第 3 幕 直す: スコア係を起動すると、スコアが更新される。状態は「すべて動いています」に戻る
#
#   使い方: weave demo health          (各幕で Enter 待ち)
#           weave demo health --auto   (通しで自動再生)
#   Inspector / スマホの URL は各幕で表示する。スマホから見るときは BIND=0.0.0.0 を付けて起動する
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
AUTO=0; [ "${1:-}" = "--auto" ] && AUTO=1
BIN=./zig-out/bin
DASH=${DASH:-3044}; NODE=${NODE:-8044}; BIND=${BIND:-127.0.0.1}
URL="ws://127.0.0.1:$DASH/ws"
DIR=$(mktemp -d)
W=0

b(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok(){ printf "   \033[32m✓\033[0m %s\n" "$*"; }
ng(){ printf "   \033[31m✗\033[0m %s\n" "$*"; }
say(){ printf "   %s\n" "$*"; }
pause(){ if [ $AUTO -eq 0 ]; then read -r -p "   [Enter で次へ] " _; else sleep "${1:-2}"; fi; }
pub(){ "$BIN/weave" topic pub ext.twitch.chat.message "{\"user\":\"staff\",\"message\":\"$1\"}" --url "$URL" --token fulltok > /dev/null 2>&1; }
score(){ grep -o '"inputName":"Scoreboard","inputSettings":{"text":"[^"]*"' "$DIR/obs.jsonl" 2>/dev/null | tail -1 | sed 's/.*"text":"//; s/"$//'; }
health(){ timeout 1.2 "$BIN/weave" topic echo --url "$URL" --token viewtok 2>/dev/null | tail -1; }
stop(){ if [ "$W" != 0 ]; then kill -INT "$W" 2>/dev/null; wait "$W" 2>/dev/null; W=0; fi; }
cleanup(){ stop; rm -rf "$DIR"; }
trap cleanup EXIT INT TERM

start(){ # $@ = 追加の引数
  : > "$DIR/obs.jsonl"
  "$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" --bind "$BIND" \
    --dash-port "$DASH" --node-port "$NODE" --audit-log "$DIR/audit.log" --state-dir "$DIR/state" --no-snapshot \
    --dashboard-token fulltok --observer-token viewtok "$@" > "$DIR/weave.log" 2>&1 &
  W=$!
  for _ in $(seq 1 100); do grep -q "Ready in" "$DIR/weave.log" 2>/dev/null && break; sleep 0.1; done
  sleep 0.5
}

[ -x "$BIN/WEAVE" ] || { echo "先に zig build してください"; exit 1; }

b "第 1 幕 — 今までの世界: スコア係 (score_tool) を起動し忘れた"
start wasm-apps/scoreboard.wasm wasm-apps/subgoal.wasm
say "Inspector: http://localhost:$DASH/?token=fulltok"
say "審判がチャットで得点を入れる: !point A を 3 回"
pub '!point A'; pub '!point A'; pub '!point A'; sleep 0.6
say "配信画面のスコア表示: $(score)"
ng "得点を入れたのに 0-0 のまま。でも、どこにもエラーは出ていない"
H=$(health)
echo "$H" | grep -q '"overall":"ok"' && say "WEAVE も「構成」を知らないので、止まっているとは判断できない" || true
say "→ 今までの世界では、ここで「OBS を再起動」「配線を一本ずつ確かめる」が始まる"
pause 3
stop

b "第 2 幕 — WEAVE: 「本来いるはずの構成」を宣言しておく (--expect)"
start --expect wasm-apps/score_tool.json wasm-apps/scoreboard.wasm wasm-apps/subgoal.wasm
say "Inspector:            http://localhost:$DASH/?token=fulltok"
say "スマホ (観測専用):      http://<この PC の IP>:$DASH/status?token=viewtok   (BIND=0.0.0.0 で起動したとき)"
H=$(health)
if echo "$H" | grep -q '"node":"score_tool","status":"missing"'; then ok "score_tool — 起動していません"; else ng "score_tool の起動忘れが検出されていない"; fi
if echo "$H" | grep -q '"node":"scoreboard","effect":"stalled","because":\["score_tool"\]'; then
  ok "scoreboard — 入力 (ext.score.update) が届かず止まっています。原因: score_tool"
  ok "→ scoreboard が出していた配信画面のスコア表示が更新されません"
fi
say "宣言 (manifest) の pub/sub から、止まったノードの影響を計算している (weave audit --failure と同じ規則)"
pause 4
stop

b "第 3 幕 — 直す: スコア係を起動する"
start --expect wasm-apps/score_tool.json wasm-apps/score_tool.wasm wasm-apps/scoreboard.wasm wasm-apps/subgoal.wasm
pub '!point A'; pub '!point A'; pub '!point B'; sleep 0.6
say "配信画面のスコア表示: $(score)"
H=$(health)
echo "$H" | grep -q '"overall":"ok"' && ok "状態: すべて動いています" || ng "状態がまだ ok になっていない"
say "30 分止まった事故が、起動した瞬間に「どれが原因か」まで分かる"
pause 3
b "おわり"
