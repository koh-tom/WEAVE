#!/usr/bin/env bash
# =============================================================================
# WEAVE 署名強制デモ (トラストアンカー Stage 1)
#
#   正規署名のプラグインはロードされ、manifest を改ざんすると WEAVE 本体が
#   起動時に「ロードを拒否」することをライブで見せる。
#
# 使い方:  ./demo/run_signature_demo.sh
# 前提:    zig build 済み (WEAVE / weave-key バイナリ)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."   # -> WEAVE リポジトリルート

BIN=./zig-out/bin
WASM=wasm-apps/kusa_node.wasm
MANIFEST=wasm-apps/kusa_node.json
KEYDIR=.weave
TRUST=$KEYDIR/trusted_keys
RUN_SECS=3
# ポートは既定と衝突しないようずらす（ブースPCで他が動いていても安全）
PORTS="--dash-port 3055 --ws-port 8095 --node-port 8096"
BASEARGS="--no-twitch --mock-obs $PORTS --signature-mode strict --trust-keys $TRUST"

blue(){ printf "\033[34;1m%s\033[0m\n" "$*"; }
green(){ printf "\033[32;1m%s\033[0m\n" "$*"; }
red(){ printf "\033[31;1m%s\033[0m\n" "$*"; }

# --- manifest を必ず元に戻す ---
cp "$MANIFEST" "/tmp/kusa_node.json.demobak"
restore(){ cp "/tmp/kusa_node.json.demobak" "$MANIFEST"; }
trap 'restore; pkill -KILL -f "zig-out/bin/WEAVE" 2>/dev/null' EXIT

run_weave(){ # $1: ログ出力先
  timeout -s KILL "$RUN_SECS" "$BIN/WEAVE" $BASEARGS "$WASM" > "$1" 2>&1
  return 0
}

blue "=== 0. ビルド確認 ==="
[ -x "$BIN/WEAVE" ] && [ -x "$BIN/weave-key" ] || { red "先に 'zig build' を実行してください"; exit 1; }

blue "=== 1. 開発者鍵を生成し、信頼リストに登録 ==="
mkdir -p "$KEYDIR"
[ -f "$KEYDIR/devkey.key" ] || "$BIN/weave-key" generate "$KEYDIR/devkey" >/dev/null
cp "$KEYDIR/devkey.pub" "$TRUST"
echo "  信頼する公開鍵: $(cat "$TRUST")"

blue "=== 2. kusa_node に署名 (wasm + manifest を束縛) ==="
"$BIN/weave-key" sign "$KEYDIR/devkey.key" "$WASM" "$MANIFEST"

blue "=== 3. strict モードで起動 → 正規署名なのでロードされるはず ==="
run_weave /tmp/weave_ok.log
if grep -qiE "Signature: OK" /tmp/weave_ok.log && grep -qiE "Loaded plugin" /tmp/weave_ok.log; then
  green "  ✓ ロード成功:"; grep -iE "Signature: OK|Loaded plugin" /tmp/weave_ok.log | sed 's/^/      /'
else
  red "  期待した 'Signature: OK / Loaded plugin' が出ませんでした。ログ:"; tail -15 /tmp/weave_ok.log
fi

echo
blue "=== 4. manifest を改ざん (権限に core.system.shutdown を追加) → 起動を拒否するはず ==="
sed 's/"core.obs.request.SetSceneItemEnabled"/"core.obs.request.SetSceneItemEnabled","core.system.shutdown"/' \
    "/tmp/kusa_node.json.demobak" > "$MANIFEST"
run_weave /tmp/weave_bad.log
restore   # すぐ戻す
if grep -qiE "REJECTED|signature_invalid|Failed to load plugin" /tmp/weave_bad.log; then
  green "  ✓ 改ざんを検出し、ロードを拒否:"; grep -iE "REJECTED|Failed to load plugin" /tmp/weave_bad.log | sed 's/^/      /'
else
  red "  期待した拒否ログが出ませんでした。ログ:"; tail -15 /tmp/weave_bad.log
fi

echo
green "=== デモ完了 ==="
echo "  正規署名 → ロード / 改ざん → 起動拒否 を本体(Core)が判定しました。"
echo "  ※ 秘密鍵 (.weave/devkey.key) は配布しないこと。"
