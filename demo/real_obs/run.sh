#!/usr/bin/env bash
# =============================================================================
# demo/real_obs/run.sh — 本物の OBS Studio を横に並べる「画面分割」ライブ版
#
#   左: OBS (シーンコレクション WEAVE-demo。プラグインが出す SubGoal / お祝い / シャウトアウトが本物の配信画面に出る)
#   右: WEAVE Inspector (DENIED / 障害と復帰 / セル)
#
#   流れ: OBS を専用コレクションで起動 → obs-websocket が開くのを待つ → WEAVE を --real-obs で起動
#   使い方:
#     ./demo/real_obs/run.sh            # ライブ (ブース用)
#     ./demo/real_obs/run.sh --record   # OBS が自分の出力を demo/output/obs/ に録画しながら
#   前提: zig build 済み、OBS 32 系、obs-websocket 有効 (パスワードは OBS の設定ファイルから読む。表示はしない)
#   注意: OBS は「最後に使ったコレクション/プロファイル」を既定にしてしまうので、終了時に user.ini を元に戻す
# =============================================================================
set -uo pipefail
set -m   # ジョブ制御 ON: これが無いとバックグラウンド起動した OBS / WEAVE は SIGINT を無視する (bash の仕様) → 止められなくなる
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
CFG="$HOME/.config/obs-studio/plugin_config/obs-websocket/config.json"
USERINI="$HOME/.config/obs-studio/user.ini"
DASH=${DASH:-3030}; NODE=${NODE:-8081}
OUT="$ROOT/demo/output/obs"; mkdir -p "$OUT"

REC=""; [ "${1:-}" = "--record" ] && REC="--startrecording"

[ -x zig-out/bin/weave ] || { echo "先に zig build してください"; exit 1; }
[ -f "$CFG" ] || { echo "obs-websocket の設定が見つかりません: $CFG (OBS の ツール > WebSocket サーバー設定 で有効化)"; exit 1; }
if [ ! -f "$HOME/.config/obs-studio/basic/scenes/WEAVE-demo.json" ] || [ ! -f "$HOME/.config/obs-studio/basic/profiles/WEAVE-demo/basic.ini" ]; then
  echo "シーンコレクション/プロファイル WEAVE-demo を作ります (既存のシーンは触りません)"
  python3 demo/real_obs/make_obs_collection.py || exit 1
fi
pgrep -x obs >/dev/null && { echo "OBS が既に起動しています。終了してから実行してください"; exit 1; }

PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("server_port",4455))' "$CFG")
PASS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("server_password",""))' "$CFG")

# OBS が既定を書き換えるので退避 → 終了時に復元
[ -f "$USERINI" ] && cp "$USERINI" "$USERINI.weave-bak"
# 録画中に Ctrl+C すると OBS が「出力が動作中です。終了しますか?」のダイアログで止まってしまうので、
# このセッションの間だけ確認ダイアログを切る (終了時に user.ini ごと元に戻す)
python3 - "$USERINI" <<'PY'
import sys, re
p = sys.argv[1]
try: s = open(p).read()
except FileNotFoundError: s = ""
s = re.sub(r"^(ConfirmOnExit|WarnBeforeStoppingRecord|WarnBeforeStartingRecord)=.*\n?", "", s, flags=re.M)
add = "ConfirmOnExit=false\nWarnBeforeStoppingRecord=false\nWarnBeforeStartingRecord=false\n"
s = s.replace("[General]\n", "[General]\n" + add, 1) if "[General]\n" in s else "[General]\n" + add + s
open(p, "w").write(s)
PY
cleanup() {
  # pid が空/0 のときは kill しない (kill 0 は呼び出し元を含むプロセスグループ全体に飛んでしまう)
  [ "${WEAVE:-0}" != 0 ] && kill "$WEAVE" 2>/dev/null
  if [ "${OBS:-0}" != 0 ]; then kill -INT "$OBS" 2>/dev/null; wait "$OBS" 2>/dev/null; fi
  [ -f "$USERINI.weave-bak" ] && mv "$USERINI.weave-bak" "$USERINI"
  return 0
}
trap cleanup EXIT INT TERM

# 異常終了後の「セーフモードで起動しますか?」ダイアログを避ける (対応ビルドのみ)
SAFE=""; obs --help 2>&1 | grep -q -- "--disable-shutdown-check" && SAFE="--disable-shutdown-check"

echo "[1/3] OBS を起動 (collection=WEAVE-demo, profile=WEAVE-demo, scene=Overlay${REC:+, 録画 ON})"
obs --collection WEAVE-demo --profile WEAVE-demo --scene Overlay $SAFE $REC >"$OUT/obs.log" 2>&1 &
OBS=$!
for _ in $(seq 1 300); do (ss -ltn 2>/dev/null | grep -q ":$PORT ") && break; sleep 0.1; done
(ss -ltn 2>/dev/null | grep -q ":$PORT ") || { echo "obs-websocket (127.0.0.1:$PORT) が開きませんでした。$OUT/obs.log を確認"; exit 1; }
echo "      obs-websocket 127.0.0.1:$PORT OK"

echo "[2/3] WEAVE を本物の OBS に接続して起動"
./zig-out/bin/weave run --no-twitch --real-obs --obs-host 127.0.0.1 --obs-port "$PORT" --obs-pass "$PASS" \
  --dash-port "$DASH" --node-port "$NODE" --audit-log "$OUT/audit.log" --state-dir "$OUT/state" \
  wasm-apps/subgoal.wasm wasm-apps/shoutout.wasm wasm-apps/malicious_plugin.wasm wasm-apps/loop_node.wasm &
WEAVE=$!

cat <<EOS

[3/3] 画面分割のやり方
  ・左: OBS。右クリック > ウィンドウプロジェクター(プログラム) を出すと出力だけの綺麗な窓になります
  ・右: Inspector  http://127.0.0.1:$DASH/  (起動ログの [INSPECTOR] の URL)
  ・Inspector のチャット欄:  !sub  / !so 名前  → 本物の OBS にカードが出る
                              go     → 悪意プラグインの攻撃 (全部 DENIED)
                              !freeze → 暴走 → 1 セルだけ復帰、OBS の画面は生きたまま
  Ctrl+C で OBS ごと止まります
EOS
wait "$WEAVE"
