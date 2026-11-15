#!/bin/sh
# The chat view's streaming perf check, in a release build:
# a 10,000-message transcript with a 32K-character answer streaming at
# 60 Hz, first following the tail, then while scrolling through history.
# Prints one JSON line per phase with the frame-interval percentiles.
#
#   crates/app/perf.sh                 # perf
#   crates/app/perf.sh a11y            # the AccessKit report instead
#
# Keep the display awake (`pmset -g assertions`); a sleeping display stops
# frames. The bundle lives in target/app/ (ignored) and is reused.
set -eu
cd "$(dirname "$0")/../.."
mode="${1:-perf}"
cargo build --release -p conduit-desktop --features harness
app="target/app/Conduit Perf.app"
mkdir -p "$app/Contents/MacOS"
# A new file moved into place: overwriting keeps the inode, and macOS then
# refuses to launch it (error 162).
cp -f target/release/conduit-desktop "$app/Contents/MacOS/conduit-desktop.new"
mv -f "$app/Contents/MacOS/conduit-desktop.new" "$app/Contents/MacOS/conduit-desktop"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.cogwheel.conduit.desktop.perf</string>
<key>CFBundleName</key><string>Conduit Perf</string>
<key>CFBundleExecutable</key><string>conduit-desktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
log=target/app/perf-run.log
: > "$log"
scratch="${PERF_SCRATCH:-$PWD/target/app/perf-profile}"
open -W -n "$app" --env "CONDUIT_USER_DATA=$scratch/user-data" --env "CONDUIT_LOGS=$scratch/logs" \
  --stdout "$log" --stderr "$log" --args --cwd "$PWD" --chat-fixture "$mode"
grep '^{' "$log"
# A report has samples; a fixture that could not run prints {"error": …}.
grep -q '^{"error"' "$log" && exit 1
grep -q '^{' "$log"
