#!/bin/bash
# Makes the Windows and Linux app icons from the app's square icon (the
# one the README shows; the Mac's AppIcon-master.png carries macOS's grid
# margins and shadow, which these platforms don't use):
#
#   desktop/packaging/winlinux-icons.sh [SOURCE.png]   (on a Mac: sips)
#
# writes, both committed:
#   linux/icons/<N>x<N>/conduit-desktop.png   N = 16 ... 512 (hicolor)
#   windows/conduit.ico                       16 ... 256 px, PNG entries
#
# It only scales the source; it never draws or changes the design.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=macos/lib.sh
. "$here/macos/lib.sh"

source_png="${1:-$REPO_ROOT/assets/icons/icon.png}"
[ -f "$source_png" ] || die "usage: winlinux-icons.sh [SOURCE.png]"
w="$(sips -g pixelWidth "$source_png" | awk '/pixelWidth/ {print $2}')"
h="$(sips -g pixelHeight "$source_png" | awk '/pixelHeight/ {print $2}')"
[ "$w" = "$h" ] && [ "$w" -ge 512 ] || die "the source must be square and at least 512 px (it is ${w}x$h)"

work="$(mktemp -d "${TMPDIR:-/tmp}/conduit-icons.XXXXXX")"
scale() {
  sips -z "$1" "$1" "$source_png" --out "$2" >/dev/null
}

for n in 16 24 32 48 64 128 256 512; do
  mkdir -p "$here/linux/icons/${n}x$n"
  scale "$n" "$here/linux/icons/${n}x$n/conduit-desktop.png"
done
log "linux/icons/<N>x<N>/conduit-desktop.png (16-512 px)"

pngs=()
for n in 16 20 24 32 40 48 64 256; do
  scale "$n" "$work/$n.png"
  pngs+=("$work/$n.png")
done
python3 -I "$here/winlinux.py" ico "$here/windows/conduit.ico" "${pngs[@]}"
log "windows/conduit.ico (16-256 px)"
