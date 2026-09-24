#!/usr/bin/env bash
# =============================================================================
# ソーク (B1): 長時間動かして、落ちない・メモリが増え続けないことを確かめる
#
#   使い方: ./scripts/soak.sh [秒数 (既定 86400 = 24 時間)]
#
#   負荷: mock Twitch のシナリオを無限ループ再生 (草ラッシュ + 通常チャット + 無限ループを起こす
#         "!freeze")、kusa / spam (暴走 Bot) / counter / loop_node、mock OBS、Inspector、監査ログ。
#   10 秒ごとに RSS を記録し ($DIR/rss.csv)、最後に次を判定する:
#     - プロセスが最後まで生きている
#     - ウォームアップ (最初の 1/10) 後の RSS に対して、終了時の RSS の増加が 10% かつ 4 MiB 以内
#       (単調増加 = リーク の検出。一時的な山は許す)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
DURATION=${1:-86400}
DIR=$(mktemp -d)
INTERVAL=10
[ "$DURATION" -lt 60 ] && INTERVAL=2

./zig-out/bin/WEAVE --mock-twitch demo/scenarios/soak.jsonl --mock-obs --mock-obs-file "$DIR/obs.jsonl" \
  --dash-port 3075 --node-port 8075 --audit-log "$DIR/audit.log" --state-dir "$DIR/state" \
  wasm-apps/kusa_node.wasm wasm-apps/spam_node.wasm wasm-apps/counter_node.wasm wasm-apps/loop_node.wasm \
  > "$DIR/weave.log" 2>&1 &
W=$!
cleanup() { kill -INT "$W" 2>/dev/null || true; sleep 0.5; kill -9 "$W" 2>/dev/null || true; }
trap cleanup EXIT

echo "soak: ${DURATION}s, logs in $DIR"
echo "elapsed_s,rss_kb" > "$DIR/rss.csv"
start=$(date +%s)
while :; do
  now=$(date +%s); el=$((now - start))
  [ "$el" -ge "$DURATION" ] && break
  kill -0 "$W" 2>/dev/null || { echo "FAIL: WEAVE died after ${el}s"; tail -20 "$DIR/weave.log"; exit 1; }
  rss=$(awk '/VmRSS/{print $2}' /proc/$W/status)
  echo "$el,$rss" >> "$DIR/rss.csv"
  sleep "$INTERVAL"
done

kill -0 "$W" 2>/dev/null || { echo "FAIL: WEAVE died"; exit 1; }
warm_n=$(( ($(wc -l < "$DIR/rss.csv") - 1) / 10 + 1 ))
warm=$(awk -F, -v n="$warm_n" 'NR>1 && NR<=n+1 {m=($2>m)?$2:m} END{print m}' "$DIR/rss.csv")
last=$(tail -1 "$DIR/rss.csv" | cut -d, -f2)
peak=$(awk -F, 'NR>1 {m=($2>m)?$2:m} END{print m}' "$DIR/rss.csv")
faults=$(grep -c "TRAPPED" "$DIR/weave.log" || true)
limited=$(grep -c rate_limited "$DIR/audit.log" || true)
echo "RSS after warm-up ${warm} KiB, at end ${last} KiB, peak ${peak} KiB"
echo "faults handled: ${faults}, rate_limited audit lines: ${limited}, OBS requests: $(wc -l < "$DIR/obs.jsonl")"
growth=$(( last - warm ))
limit=$(( warm / 10 > 4096 ? warm / 10 : 4096 ))
if [ "$growth" -gt "$limit" ]; then echo "FAIL: RSS grew by ${growth} KiB (> ${limit} KiB)"; exit 1; fi
echo "PASS"
