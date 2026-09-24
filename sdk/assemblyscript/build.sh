#!/usr/bin/env bash
# AssemblyScript のプラグインを WEAVE 用の wasm にビルドする
#   使い方: sdk/assemblyscript/build.sh <plugin.ts> [出力名]   → wasm-apps/<出力名>.wasm
# WEAVE の WAMR は bulk-memory 拡張を有効にしていないので無効化してビルドする。
set -euo pipefail
cd "$(dirname "$0")"
SRC=${1:?usage: build.sh <plugin.ts> [name]}
case "$SRC" in /*) ;; *) [ -f "$SRC" ] || SRC="$OLDPWD/$SRC" ;; esac
NAME=${2:-$(basename "$SRC" .ts)}
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
[ -d node_modules/assemblyscript ] || "$BUN" install >/dev/null
./node_modules/.bin/asc "$SRC" -o "../../wasm-apps/$NAME.wasm" \
  --runtime incremental --optimize --noAssert \
  --use abort=assembly/weave/weaveAbort --disable bulk-memory
echo "built wasm-apps/$NAME.wasm"
