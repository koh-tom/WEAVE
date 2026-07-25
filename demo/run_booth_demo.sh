#!/usr/bin/env bash
set -euo pipefail

# WEAVE repository root に移動
cd "$(dirname "$0")/.."

echo "========================================================"
echo " 🎪 WEAVE ブース展示用・連続自動デモ起動スクリプト"
echo "========================================================"
echo ""

# デフォルト設定
OBS_HOST="127.0.0.1"
OBS_PORT="4455"
OBS_PASS="${OBS_PASS:-}"

# 引数解析
while [[ $# -gt 0 ]]; do
  case $1 in
    --obs-pass)
      OBS_PASS="$2"
      shift 2
      ;;
    --obs-host)
      OBS_HOST="$2"
      shift 2
      ;;
    --obs-port)
      OBS_PORT="$2"
      shift 2
      ;;
    *)
      # 第1引数がオプションでない場合はパスワードとして扱う
      if [ -z "$OBS_PASS" ]; then
        OBS_PASS="$1"
      fi
      shift
      ;;
  esac
done

echo "[1/3] WEAVE Core, Wasm プラグイン, ダッシュボードをビルド中..."
zig build
zig build wasm

if [ -d "dashboard" ]; then
    (cd dashboard && npm run build)
fi

OBS_PASS_OPT=""
if [ -n "$OBS_PASS" ]; then
  OBS_PASS_OPT="--obs-pass ${OBS_PASS}"
fi

echo ""
echo "[2/3] 展示構成:"
echo " 🟢 WEAVE Core Daemon (Host)"
echo " 🟢 Wasm Guest Plugin: kusa_node.wasm"
echo " 🟢 Real OBS WebSocket: ${OBS_HOST}:${OBS_PORT}"
echo " 🟢 Mock Twitch Chat Stream: 連続ループ再生 (demo/scenarios/kusa.jsonl)"
echo " 🌐 Dashboard UI: http://localhost:3030"
echo "--------------------------------------------------------"
echo ""
echo "🚀 実OBS接続モードでループデモを開始します..."
echo "   (Ctrl+C でいつでも停止できます)"
echo ""

./zig-out/bin/WEAVE \
  --real-obs \
  --obs-host "${OBS_HOST}" \
  --obs-port "${OBS_PORT}" \
  ${OBS_PASS_OPT} \
  --mock-twitch demo/scenarios/kusa.jsonl \
  wasm-apps/kusa_node.wasm
