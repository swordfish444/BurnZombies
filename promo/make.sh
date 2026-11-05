#!/bin/zsh
# Rebuilds the README film from this folder. See README.md.
#   promo/make.sh            render, then titles, sound and encode
#   promo/make.sh render     only the 3D frames (FRAMES=a-b for a range, e.g. on a second Mac)
#   promo/make.sh finish     titles, sound and encode, once build/frames/ is complete
set -euo pipefail
cd "$(dirname "$0")"
B=$PWD/build
mkdir -p $B/frames $B/titled $B/audio
step=${1:-all}
POSTER_FRAME=f_0706.png   # 23.5 s, the end card: the base for frame 1, the poster

if [[ $step == all || $step == render ]]; then
  blender -b --factory-startup -P scene/build.py -- --render $B/frames/ ${FRAMES:+--frames $FRAMES}
fi
if [[ $step == all || $step == finish ]]; then
  python3 titles/overlay.py $B/frames $B/titled --poster $B/frames/$POSTER_FRAME
  python3 sound/mix.py timeline.json $B/events.json narration/lines $B/sound-src $B/audio/mix.wav
  # one static gain to -14 LUFS, peaks held under -1.5 dBFS
  I=$(ffmpeg -hide_banner -nostats -i $B/audio/mix.wav -af ebur128 -f null - 2>&1 | awk '/I:/ {v=$2} END {print v}')
  G=$(python3 -c "print(round(-14 - ($I), 2))")
  ffmpeg -v error -y -i $B/audio/mix.wav -af "volume=${G}dB,alimiter=limit=0.84:attack=2:release=60:level=false" $B/audio/master.wav
  ffmpeg -v error -y -framerate 30 -i $B/titled/f_%04d.png -i $B/audio/master.wav \
    -c:v libx264 -preset slow -crf ${CRF:-21} -pix_fmt yuv420p -profile:v high -movflags +faststart \
    -c:a aac -b:a 192k -shortest $B/burnzombies-readme-film.mp4
  ls -lh $B/burnzombies-readme-film.mp4
fi
