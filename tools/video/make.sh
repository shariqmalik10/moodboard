#!/bin/sh
# Records the Greenhouse demo with a Debug build and cuts it into docs/media.
#   tools/video/make.sh                 builds the Debug app from this folder, then records and cuts
#   tools/video/make.sh <Moodboard.app> records and cuts with a Debug build you already have
#   tools/video/make.sh --recut         cuts the last take again, after a change to the edit in take.mjs
# Run it from a clean clone: the take shows everything the build contains.
# It needs Xcode, Node and ffmpeg, and the terminal needs Screen Recording permission.
set -eu
cd "$(dirname "$0")/../.."
OUT=build/video
APP=${1:-}
if [ "$APP" = "--recut" ] && { [ ! -f "$OUT/take.json" ] || [ ! -f "$OUT/take.mov" ]; }; then
  echo "There's no take in $OUT to cut. Run tools/video/make.sh without --recut first." >&2
  exit 1
fi
mkdir -p "$OUT/bin" docs/media

swiftc -O -parse-as-library -swift-version 6 tools/video/record.swift -o "$OUT/bin/record"
swiftc -O -parse-as-library -swift-version 6 tools/video/render.swift -o "$OUT/bin/render"

if [ "$APP" = "--recut" ]; then
  node tools/video/take.mjs --edit "$OUT"
else
  if [ -z "$APP" ]; then
    npm ci
    npm run build
    xcodebuild -project native/Moodboard.xcodeproj -scheme Moodboard -configuration Debug -derivedDataPath native/build -quiet build
    APP=native/build/Build/Products/Debug/Moodboard.app
  fi
  node tools/video/take.mjs "$APP" "$OUT"
fi
"$OUT/bin/render" "$OUT/edit.json"

ffmpeg -v error -y -i "$OUT/cut.mov" -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -movflags +faststart -an docs/media/demo.mp4
ffmpeg -v error -y -ss "$(node -p "require('./$OUT/edit.json').poster")" -i "$OUT/cut.mov" -frames:v 1 -q:v 3 docs/media/poster.jpg
cp "$OUT/chapters.vtt" docs/media/chapters.vtt
echo "Wrote docs/media/demo.mp4, poster.jpg and chapters.vtt"
