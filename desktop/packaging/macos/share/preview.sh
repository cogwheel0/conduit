#!/bin/bash
# Draws the Share sheet's content in light and dark (tests/SharePreview.swift:
# the extension's own view controller over synthetic items, off screen) into
# OUT_DIR/share-sheet-{light,dark}.png. No share, no registration, no window
# on screen.
#
#   desktop/packaging/macos/share/preview.sh OUT_DIR
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: preview.sh OUT_DIR}"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/conduit-share-preview.XXXXXX")"
xcrun swiftc -swift-version 5 -parse-as-library -D SHARE_PREVIEW \
  -target arm64-apple-macos14.0 -module-name SharePreview -o "$work/SharePreview" \
  "$here/ShareInbox.swift" "$here/ShareViewController.swift" "$here/tests/SharePreview.swift"
printf '# Seed list\n\n- chard\n- sorrel\n' >"$work/seed list.md"
for look in light dark; do
  "$work/SharePreview" "$look" "$out/share-sheet-$look.png" "$here/../AppIcon.icns" "$work/seed list.md"
done
