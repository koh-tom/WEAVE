#!/usr/bin/env bash
# =============================================================================
# WEAVE: clone → ビルド → 起動 までの速度を実測する
#
#   使い方:
#     ./scripts/bench_clone_to_up.sh                 # 現在のチェックアウトで build+起動 を計測
#     ./scripts/bench_clone_to_up.sh <repo-url>      # 新規 clone から丸ごと計測 (新品マシン相当)
#
#   計測項目:
#     1. clone + submodule(WAMR) 取得   (URL 指定時のみ)
#     2. cold build (グローバル/ローカル キャッシュを空にした "新品マシン相当")
#     3. 起動 → "Running" までの時間
#     + 生成バイナリサイズ
# =============================================================================
set -uo pipefail

now(){ date +%s.%N; }
dur(){ awk "BEGIN{printf \"%.2f\", $2-$1}"; }
b(){ printf "\033[1m%s\033[0m\n" "$*"; }

REPO_URL="${1:-}"
CLONE_T="—  (現在のチェックアウトを使用)"

if [ -n "$REPO_URL" ]; then
  TMP=$(mktemp -d)
  b "[1/3] clone --recursive $REPO_URL ..."
  s=$(now); git clone --recursive "$REPO_URL" "$TMP/WEAVE" >/dev/null 2>&1 || { echo "clone 失敗"; exit 1; }; e=$(now)
  CLONE_T="$(dur $s $e) s"
  cd "$TMP/WEAVE"
else
  cd "$(dirname "$0")/.."
fi

# --- 2. cold build (新品マシン相当: キャッシュ空) ---
b "[2/3] cold build (zig build / キャッシュ空) ..."
CACHE=$(mktemp -d)
s=$(now)
ZIG_GLOBAL_CACHE_DIR="$CACHE/g" ZIG_LOCAL_CACHE_DIR="$CACHE/l" zig build >/dev/null 2>&1
rc=$?; e=$(now)
BUILD_T="$(dur $s $e) s"
[ $rc -ne 0 ] && { echo "build 失敗 (rc=$rc)"; exit 1; }
BIN_SIZE=$(stat -c%s zig-out/bin/WEAVE 2>/dev/null || echo 0)
BIN_MB=$(awk "BEGIN{printf \"%.1f\", $BIN_SIZE/1048576}")

# --- 3. 起動 → Running までの時間 ---
b "[3/3] 起動 → Running 計測 ..."
LOG=$(mktemp)
s=$(now)
./zig-out/bin/WEAVE --no-twitch --mock-obs \
  --dash-port 3099 --node-port 8100 \
  wasm-apps/kusa_node.wasm > "$LOG" 2>&1 &
WPID=$!
START_T="timeout(>10s)"
for _ in $(seq 1 100); do
  if grep -q "Running" "$LOG" 2>/dev/null; then e=$(now); START_T="$(dur $s $e) s"; break; fi
  if ! kill -0 "$WPID" 2>/dev/null; then e=$(now); START_T="プロセス終了 ($(dur $s $e)s) — ログ確認: $LOG"; break; fi
  sleep 0.1
done
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

echo
b "================ WEAVE clone → 起動 実測 ================"
printf "  1. clone + submodule : %s\n" "$CLONE_T"
printf "  2. cold build        : %s  (WAMR C 32ファイル + Zig を静的リンク。zap/facil.io 依存は廃止)\n" "$BUILD_T"
printf "  3. 起動 → Running     : %s\n" "$START_T"
printf "  ─ 生成バイナリ        : %s MB (単一実行ファイル / Docker 不要 / 実行に Node 不要)\n" "$BIN_MB"
echo "========================================================"
echo "  ※ Dashboard の UI を出す場合のみ 'cd dashboard && bun install && bun run build' が別途必要"
