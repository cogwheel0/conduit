#!/bin/sh
# Renders gallery screens through a .app bundle launched with `open`, so
# macOS lets the gallery become the active app and windows draw key-window
# chrome (coloured traffic lights, active selection). A bare binary launched
# from a background shell is refused activation and renders inactive chrome.
#
#   crates/gallery/render.sh --all /tmp/conduit-gallery
#   crates/gallery/render.sh --screen main-empty --mode dark --out shot.png
#
# The bundle lives in target/gallery/ (ignored) and is reused.
set -eu
cd "$(dirname "$0")/../.."
cargo build -p conduit-gallery
app=target/gallery/ConduitGallery.app
mkdir -p "$app/Contents/MacOS"
cp -f target/debug/conduit-gallery "$app/Contents/MacOS/conduit-gallery"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.cogwheel.conduit.design-gallery</string>
<key>CFBundleName</key><string>Conduit Gallery</string>
<key>CFBundleExecutable</key><string>conduit-gallery</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
log=target/gallery/last-run.log
: > "$log"
open -W -n "$app" --stdout "$log" --stderr "$log" --args --cwd "$PWD" "$@"
cat "$log"
grep -q FAILED "$log" && exit 1
exit 0
