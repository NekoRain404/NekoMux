#!/usr/bin/env bash
#
# Renders the launcher icon from assets/icon/*.svg into the Android resource
# folders.
#
# Run from the repository root:  tool/generate_icons.sh
#
# The SVGs are the source of truth. The PNGs are outputs, and they are checked in
# because Android needs them at build time — but they should never be edited by
# hand: a change made only to a PNG is invisible to the next person who edits the
# artwork and regenerates, and it silently reverts.
#
# Needs rsvg-convert (librsvg) and ImageMagick. Both are checked for below rather
# than assumed, because the failure mode otherwise is a half-written set of icons
# with no error.
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in rsvg-convert magick; do
  command -v "$tool" >/dev/null || {
    echo "missing: $tool" >&2
    exit 1
  }
done

SRC=assets/icon
RES=android/app/src/main/res

# Adaptive icon layers: 108 dp at each density, and the foreground must be
# rendered with transparency so the background layer shows through.
declare -A LAYER_PX=([mdpi]=108 [hdpi]=162 [xhdpi]=216 [xxhdpi]=324 [xxxhdpi]=432)

# Legacy square icon: 48 dp at each density.
declare -A LEGACY_PX=([mdpi]=48 [hdpi]=72 [xhdpi]=96 [xxhdpi]=144 [xxxhdpi]=192)

for density in "${!LAYER_PX[@]}"; do
  px=${LAYER_PX[$density]}
  dir="$RES/mipmap-$density"
  mkdir -p "$dir"
  rsvg-convert -w "$px" -h "$px" "$SRC/icon_background.svg" -o "$dir/ic_launcher_background.png"
  rsvg-convert -w "$px" -h "$px" "$SRC/icon_foreground.svg" -o "$dir/ic_launcher_foreground.png"
  echo "adaptive $density -> ${px}px"
done

for density in "${!LEGACY_PX[@]}"; do
  px=${LEGACY_PX[$density]}
  dir="$RES/mipmap-$density"
  mkdir -p "$dir"
  rsvg-convert -w "$px" -h "$px" "$SRC/icon_full.svg" -o "$dir/ic_launcher.png"
  # The round variant is the same artwork: Android masks it, and an icon drawn
  # for a square shown inside a circle loses its corners — which on this mark
  # would be the ear tips.
  cp "$dir/ic_launcher.png" "$dir/ic_launcher_round.png"
  echo "legacy   $density -> ${px}px"
done

# The store listing wants one 512px square, and a 512px round of the same.
mkdir -p build/icon
rsvg-convert -w 512 -h 512 "$SRC/icon_full.svg" -o build/icon/play-store-512.png
rsvg-convert -w 512 -h 512 "$SRC/icon_full.svg" -o build/icon/play-store-512-round-src.png
magick build/icon/play-store-512-round-src.png \
  \( +clone -alpha extract \
     -draw 'fill black polygon 0,0 0,512 512,0 fill white circle 256,256 256,0' \
     \( +clone -flip \) -compose Multiply -composite \
     \( +clone -flop \) -compose Multiply -composite \
  \) -alpha off -compose CopyOpacity -composite \
  build/icon/play-store-512-round.png
rm build/icon/play-store-512-round-src.png
echo "store    512px (square + round)"
