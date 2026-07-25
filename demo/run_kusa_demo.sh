#!/usr/bin/env bash
set -euo pipefail

# WEAVE repository root に移動
cd "$(dirname "$0")/.."

echo "========================================================"
echo "    🌱 WEAVE kusa_node 録画・デモ実行スクリプト"
echo "========================================================"
echo ""

# 1. ビルド
echo "[1/3] WEAVE Core, Wasm plugins, Dashboard をビルド中..."
zig build
zig build wasm

if [ -d "dashboard" ]; then
    (cd dashboard && npm run build)
fi

echo ""
echo "[2/3] デモ環境の準備が完了しました。"
echo "--------------------------------------------------------"
echo " 🌐 Dashboard: http://localhost:3030"
echo " 📌 モード: Web UI 上の「草ラッシュ (10連発)」ボタン または"
echo "           自動シナリオ (demo/scenarios/kusa.jsonl) でデモ可能"
echo "--------------------------------------------------------"
echo ""

# 引数処理 (--auto が指定されていればシナリオ自動再生モード、なければインタラクティブモード)
MOCK_TWITCH_OPT=""
if [[ "${1:-}" == "--auto" ]]; then
    echo "[3/3] シナリオ自動再生モードで WEAVE を起動します..."
    MOCK_TWITCH_OPT="--mock-twitch demo/scenarios/kusa.jsonl"
else
    echo "[3/3] インタラクティブモードで WEAVE を起動します..."
    echo "      (Web Dashboard http://localhost:3030 の「草ラッシュ」ボタンで動作確認できます)"
fi

echo ""
echo "🚀 サーバー起動中... (終了するには Ctrl+C を押してください)"
echo ""

./zig-out/bin/WEAVE \
  ${MOCK_TWITCH_OPT} \
  --mock-obs \
  wasm-apps/kusa_node.wasm
