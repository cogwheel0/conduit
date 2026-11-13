#!/bin/bash
# Makes the app icon files from the 1024 px master:
#
#   desktop/packaging/macos/icon.sh MASTER.png|MASTER.svg [OUT_DIR]
#
# writes, into OUT_DIR (default packaging/macos/, both committed):
#   AppIcon.icns  every size (16-512 px at 1x and 2x), via iconutil; what
#                 macOS 14 and 15 show (CFBundleIconFile)
#   Assets.car    the same images as an asset-catalog AppIcon, via Xcode's
#                 actool; what macOS 26+ shows (CFBundleIconName). Without
#                 it, macOS 27 draws the .icns shrunk inside a grey squircle
#                 at small sizes.
#
# The master is the finished macOS app icon: the tile on Apple's grid with
# its margins and shadow (AppIcon-master.png, made from the iOS app icon by
# icon-master.swift). This script only scales it; it never draws or changes
# the design. A PNG master is scaled with sips; an SVG master is rendered
# with Quick Look (qlmanage) first, never ImageMagick.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

master="${1:-}"
out="${2:-$PACKAGING_DIR}"
[ -f "$master" ] || die "usage: icon.sh MASTER.png|MASTER.svg [OUT_DIR]"
mkdir -p "$out"

work="$(mktemp -d "${TMPDIR:-/tmp}/conduit-icon.XXXXXX")"
case "$master" in
  *.svg)
    qlmanage -t -s 1024 -o "$work" "$master" >/dev/null 2>&1
    png="$work/$(basename "$master").png"
    [ -f "$png" ] || die "qlmanage did not render $master"
    ;;
  *.png) png="$master" ;;
  *) die "the master must be a .png or an .svg" ;;
esac
w="$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')"
h="$(sips -g pixelHeight "$png" | awk '/pixelHeight/ {print $2}')"
[ "$w" = 1024 ] && [ "$h" = 1024 ] || die "the master is ${w}x${h}; it must be 1024x1024"

# One set of images for both outputs.
set="$work/AppIcon.iconset"
mkdir -p "$set"
contents='{"images":['
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    suffix=""
    if [ "$scale" = 2 ]; then suffix="@2x"; fi
    name="icon_${size}x${size}${suffix}.png"
    if [ "$px" = 1024 ]; then
      cp "$png" "$set/$name"
    else
      sips -z "$px" "$px" "$png" --out "$set/$name" >/dev/null
    fi
    contents="$contents{\"filename\":\"$name\",\"idiom\":\"mac\",\"scale\":\"${scale}x\",\"size\":\"${size}x${size}\"},"
  done
done
contents="${contents%,}],\"info\":{\"author\":\"xcode\",\"version\":1}}"

iconutil -c icns "$set" -o "$out/AppIcon.icns"

catalog="$work/AppIcon.xcassets"
mkdir -p "$catalog/AppIcon.appiconset" "$work/compiled"
printf '{"info":{"author":"xcode","version":1}}\n' >"$catalog/Contents.json"
printf '%s\n' "$contents" >"$catalog/AppIcon.appiconset/Contents.json"
cp "$set"/*.png "$catalog/AppIcon.appiconset/"
xcrun actool --compile "$work/compiled" --platform macosx \
  --minimum-deployment-target "$MACOS_MIN" --app-icon AppIcon \
  --output-partial-info-plist "$work/partial.plist" "$catalog" >/dev/null
[ -f "$work/compiled/Assets.car" ] || die "actool did not write Assets.car"
cp "$work/compiled/Assets.car" "$out/Assets.car"

log "wrote $out/AppIcon.icns ($(du -h "$out/AppIcon.icns" | awk '{print $1}')) and $out/Assets.car ($(du -h "$out/Assets.car" | awk '{print $1}')) from $master"
