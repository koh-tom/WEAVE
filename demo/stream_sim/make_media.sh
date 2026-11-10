#!/usr/bin/env bash
# demo/stream_sim/make_media.sh — 模擬配信で OBS に置く素材を ffmpeg で作る (外部の素材は使わない)
#   game.mp4  … ゲーム画面の代わり (ライフゲームが動き続ける 30 秒のループ)
#   se_*.wav  … 効果音 4 種 (拍手・ドラム・歓声・ファンファーレ)。sfx プラグインが鳴らす
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=demo/output/stream_sim/media; mkdir -p "$OUT"
[ -s "$OUT/game.mp4" ] || ffmpeg -loglevel error -y -f lavfi \
  -i "life=s=320x180:mold=12:r=30:ratio=0.12:death_color=#13161c:life_color=#3d7bd9:mold_color=#1f3a5f,scale=1280:720:flags=neighbor" \
  -t 30 -c:v libx264 -pix_fmt yuv420p -preset veryfast "$OUT/game.mp4"
# 拍手: 短いノイズの粒を 6 回
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=d=0.9:c=pink:a=0.6" -af "volume='if(lt(mod(t,0.15),0.03),1,0)':eval=frame,afade=t=out:st=0.6:d=0.3" "$OUT/se_clap.wav"
# ドラム: 低い音が急に減衰 x2
ffmpeg -loglevel error -y -f lavfi -i "sine=f=70:d=0.8" -af "volume='exp(-mod(t,0.4)*12)':eval=frame" "$OUT/se_drum.wav"
# 歓声: 上がっていく和音
ffmpeg -loglevel error -y -f lavfi -i "sine=f=523:d=0.9" -f lavfi -i "sine=f=659:d=0.9" -f lavfi -i "sine=f=784:d=0.9" \
  -filter_complex "[0][1][2]amix=inputs=3,afade=t=in:d=0.1,afade=t=out:st=0.6:d=0.3" "$OUT/se_yay.wav"
# ファンファーレ: ド・ミ・ソ・ド
ffmpeg -loglevel error -y -f lavfi -i "sine=f=523:d=0.18" -f lavfi -i "sine=f=659:d=0.18" -f lavfi -i "sine=f=784:d=0.18" -f lavfi -i "sine=f=1047:d=0.5" \
  -filter_complex "[0][1][2][3]concat=n=4:v=0:a=1,afade=t=out:st=0.8:d=0.24" "$OUT/se_fanfare.wav"
ls -la "$OUT"
