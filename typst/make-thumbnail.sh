#!/bin/sh
# Regenerate thumbnail.png: five arms of the discrete logarithmic spiral
#
#     floor(15/(2pi) ln r) = floor(15/(2pi) theta) + k   (mod 15)
#
# for k = 0, 3, 6, 9, 12, plotted by the repository's own CLI and coloured
# with ImageMagick. theta is synthesised from the half-angle identity
# 2*atan(y / (sqrt(x^2+y^2) + x)), and the mod-15 congruence restores the
# full turn a single atan branch cannot express.
#
# Run from anywhere, after: zig build -Doptimize=ReleaseFast
set -e
cd "$(dirname "$0")/.."

CLI=zig-out/bin/implicit-plot
[ -x "$CLI" ] || { echo "build first: zig build -Doptimize=ReleaseFast" >&2; exit 1; }

SIZE=800x800
VIEW=6.3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

layers=""
for arm in 0:e5484d 3:f0b100 6:46a758 9:3e7bd6 12:9d5bd2; do
  k=${arm%%:*}
  colour=${arm#*:}
  "$CLI" -s "$SIZE" -x "-$VIEW:$VIEW" -y "-$VIEW:$VIEW" -d 4 -o "$work/$k.png" \
    "(floor(15/(2*pi) * log(x^2 + y^2) / 2) - floor(15/pi * atan(y / (sqrt(x^2 + y^2) + x))) - $k) % 15 = 0" \
    >/dev/null
  # The CLI paints #0078d4 ink on white paper: recolour the ink, drop the paper.
  magick "$work/$k.png" -fill "#$colour" -opaque "#0078d4" -transparent white "$work/arm-$k.png"
  layers="$layers $work/arm-$k.png"
done

# shellcheck disable=SC2086 # $layers is a deliberate word-split list
magick -size "$SIZE" xc:'#1e1e26' $layers -flatten typst/thumbnail.png
echo "wrote typst/thumbnail.png"
