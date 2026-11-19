#!/bin/bash
# Builds the desktop widget: ConduitWidget.appex (the WidgetKit extension)
# and libconduit_widget.dylib (WidgetCenter for the app), unsigned.
# bundle.sh embeds and signs them; crates/app/run.sh --widget does too.
#
#   widget/build.sh --out DIR --bundle-id APP_ID --app-group GROUP \
#       [--version 1.2.0] [--build 1020099] [--min 14.0]
#
# The extension's id is the app's plus ".widget". Swift only: swiftc from
# the active Xcode (or Command Line Tools) and the macOS SDK, no Xcode
# project. Nothing here deletes files: an earlier build is moved aside.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

out="" bundle_id="" group="" version=0.0.0 build=0 min=14.0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift ;;
    --bundle-id) bundle_id="$2"; shift ;;
    --app-group) group="$2"; shift ;;
    --version) version="$2"; shift ;;
    --build) build="$2"; shift ;;
    --min) min="$2"; shift ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "widget/build.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$out" ] && [ -n "$bundle_id" ] && [ -n "$group" ] || {
  echo "widget/build.sh: --out, --bundle-id and --app-group are required" >&2
  exit 2
}
mkdir -p "$out"
out="$(cd "$out" && pwd)"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
swiftc=(xcrun --sdk macosx swiftc -sdk "$sdk" -target "arm64-apple-macos$min" -O
  -warnings-as-errors)

appex="$out/ConduitWidget.appex"
lib="$out/libconduit_widget.dylib"
for old in "$appex" "$lib"; do
  if [ -e "$old" ]; then mv "$old" "$old.old-$(date -u +%Y%m%dT%H%M%SZ)-$$"; fi
done

echo "==> widget: ConduitWidget.appex ($bundle_id.widget, group $group)" >&2
# The widget's words in every language, from the ARBs.
python3 "$here/../native_strings.py" widget "$here/../../../../lib/l10n" \
  "$out/gen/WidgetStrings.swift" >&2
mkdir -p "$appex/Contents/MacOS"
"${swiftc[@]}" -parse-as-library -application-extension -module-name ConduitWidget \
  "$here"/Sources/*.swift "$out/gen/WidgetStrings.swift" "$here/Extension/Main.swift" \
  -o "$appex/Contents/MacOS/ConduitWidget"
sed -e "s/@BUNDLE_ID@/$bundle_id.widget/" \
  -e "s/@VERSION@/$version/" \
  -e "s/@BUILD@/$build/" \
  -e "s/@APP_GROUP@/$group/" \
  -e "s/@MIN_OS@/$min/" \
  "$here/Info.plist" >"$appex/Contents/Info.plist"
plutil -lint -s "$appex/Contents/Info.plist"
printf 'XPC!????' >"$appex/Contents/PkgInfo"

echo "==> widget: libconduit_widget.dylib" >&2
"${swiftc[@]}" -emit-library -module-name ConduitWidgetBridge \
  "$here/Bridge/WidgetBridge.swift" \
  -Xlinker -install_name -Xlinker @rpath/libconduit_widget.dylib \
  -o "$lib"
