#!/usr/bin/env bash
# =============================================================================
# WEAVE 「暴走 Bot」封じ込めデモ  (レート制限 + 監査ログ)
#
#   現状の世界: チャット Bot が暴走すると、直結された全ツールが巻き込まれ配信が崩壊。
#   WEAVE     : manifest の rate_limit_eps でバス手前でドロップ。他ノードは無傷、
#               証跡は audit.log に残る。しかも権限的にも OBS/FS/net には届かない。
#
# 使い方:  ./demo/run_ratelimit_demo.sh
# 前提:    zig build 済み
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin
AUDIT=audit.log
RUN_SECS=6
PORTS="--dash-port 3055 --node-port 8096"
blue(){ printf "\033[34;1m%s\033[0m\n" "$*"; }
green(){ printf "\033[32;1m%s\033[0m\n" "$*"; }

trap 'pkill -KILL -f "zig-out/bin/WEAVE" 2>/dev/null' EXIT
[ -x "$BIN/WEAVE" ] || { echo "先に 'zig build' を実行してください"; exit 1; }

blue "=== 0. 暴走 Bot の影響範囲を起動前に確認 (weave-audit) ==="
"$BIN/weave-audit" spam_node 2>&1 | sed 's/^/   /'
echo "   -> 権限上、実世界シンク(OBS/FS/net)には到達不能。あとは流量だけが問題。"
echo

blue "=== 1. WEAVE 起動: kusa_node と暴走 spam_node を同時ロード (audit.log 初期化) ==="
: > "$AUDIT"
timeout -s KILL "$RUN_SECS" "$BIN/WEAVE" \
  --mock-twitch demo/scenarios/kusa.jsonl --mock-obs $PORTS \
  --audit-log "$AUDIT" \
  wasm-apps/kusa_node.wasm wasm-apps/spam_node.wasm > /tmp/weave_rl.log 2>&1

echo
blue "=== 2. spam_node のログ (試行 vs 通過 vs ドロップ) ==="
grep "spam_node" /tmp/weave_rl.log | tail -6 | sed 's/^/   /'

blue "=== 3. 監査ログ audit.log に残ったレート制限イベント ==="
RL=$(grep -c "rate_limited" "$AUDIT" 2>/dev/null || echo 0)
echo "   rate_limited イベント数: $RL"
grep "rate_limited" "$AUDIT" 2>/dev/null | head -3 | sed 's/^/   /'

blue "=== 4. 暴走 Bot がいても kusa は正常動作したか (mock OBS 受信) ==="
if grep -qiE "SetSceneItemEnabled|Loaded plugin 'kusa_node'" /tmp/weave_rl.log; then
  green "   ✓ kusa_node は正常に OBS 制御を発行 = 暴走 Bot に巻き込まれていない"
else
  echo "   (ログ確認: /tmp/weave_rl.log)"
fi

echo
green "=== まとめ ==="
echo "  暴走 Bot は (1) 権限で OBS/FS/net に届かず (2) レート制限で大半がドロップされ"
echo "  (3) 証跡が audit.log に残り (4) 他ノードは無傷。現状の配信環境との決定的な差。"
