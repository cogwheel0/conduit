#!/bin/sh
# Runs the dev app through a .app bundle launched with `open`, so macOS lets
# it become the active app (a bare binary started from a background shell is
# refused activation and draws inactive chrome). Uses the dev daemon from
# `dart build cli` in apps/daemon and the dev paths (`Conduit Dev`).
#
#   crates/app/run.sh                              # run the app
#   crates/app/run.sh --shots /tmp/shots           # smoke pass, then quit
#   CONDUITD_PATH=/nonexistent crates/app/run.sh --shots /tmp/shots --expect-failure
#   crates/app/run.sh --build-only                 # build the .app, don't run it
#   crates/app/run.sh --shots /tmp/shots --e2e chat # an E2E pass on the local
#                                                  # Open WebUI (tool/local_owui)
#
# The bundle lives in target/app/ (ignored) and is reused. A scripted run
# (--shots, --e2e, --capture) uses the profile CONDUIT_USER_DATA names, never
# the app's own; without one it starts on a fresh profile in $TMPDIR.
set -eu
cd "$(dirname "$0")/../.."
cargo build -p conduit-desktop --features harness
app="target/app/Conduit Dev.app"
mkdir -p "$app/Contents/MacOS"
# Copy to a new file and move it into place: overwriting the binary in place
# keeps its inode, and macOS then refuses to launch it (the kernel's cached
# code signature no longer matches; "Launchd job spawn failed", error 162).
cp -f target/debug/conduit-desktop "$app/Contents/MacOS/conduit-desktop.new"
mv -f "$app/Contents/MacOS/conduit-desktop.new" "$app/Contents/MacOS/conduit-desktop"
# One Info.plist for every bundle (packaging/macos/Info.plist: the
# conduit:// scheme and the "Open with" document types), filled in for dev.
sed -e 's/@BUNDLE_ID@/app.cogwheel.conduit.desktop.dev/' \
    -e 's/@BUNDLE_NAME@/Conduit Dev/' \
    -e 's/@EXECUTABLE@/conduit-desktop/' \
    -e 's/@VERSION@/0.0.0/' \
    -e 's/@BUILD@/0/' \
    packaging/macos/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
# An ad-hoc signature over the whole bundle (Info.plist included), so the
# system treats it as an app for notifications and the login item. Dev
# secrets go through /usr/bin/security, so the signature changing on each
# build never meets a Keychain prompt.
codesign --force --sign - --timestamp=none "$app" 2>/dev/null || true
if [ "${1:-}" = "--build-only" ]; then
  echo "$PWD/$app"
  exit 0
fi
log=target/app/last-run.log
: > "$log"
# `open` does not pass the environment through; forward the overrides the
# app reads. Each `--env NAME=value` goes in front of the arguments as its
# own words, so a value with spaces stays whole.
set -- --stdout "$log" --stderr "$log" --args --cwd "$PWD" "$@"
for var in CONDUITD_PATH CONDUIT_USER_DATA CONDUIT_LOGS CONDUIT_FLAVOR CONDUIT_SHOT_WINDOW \
  CONDUIT_OWUI_ENV CONDUIT_OWUI_DIR CONDUIT_DEV_CACHE; do
  eval "val=\${$var:-}"
  if [ -n "$val" ]; then set -- --env "$var=$val" "$@"; fi
done
open -W -n "$app" "$@"
cat "$log"
grep -q "SMOKE FAILED" "$log" && exit 1
exit 0
