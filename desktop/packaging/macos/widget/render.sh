#!/bin/bash
# Draws the widget's views to PNG files (light and dark, each family and
# state) without WidgetKit, from Fixtures/snapshot.json:
#
#   widget/render.sh OUT_DIR
#
# For reviewing the widget where the gallery can't load it (an ad-hoc or
# unprovisioned build; see docs/BUILDING-DESKTOP.md).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
[ $# -eq 1 ] || { echo "usage: widget/render.sh OUT_DIR" >&2; exit 2; }
mkdir -p "$1"
dest="$(cd "$1" && pwd)"
tool="$dest/.render-widgets"
python3 "$here/../native_strings.py" widget "$here/../../../../lib/l10n" \
  "$dest/.gen/WidgetStrings.swift" >&2
sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$sdk" -target arm64-apple-macos14.0 -O \
  -warnings-as-errors -parse-as-library -module-name RenderWidgets \
  "$here"/Sources/*.swift "$dest/.gen/WidgetStrings.swift" \
  "$here/Render/RenderWidgets.swift" -o "$tool"
"$tool" "$here/Fixtures/snapshot.json" "$dest"
