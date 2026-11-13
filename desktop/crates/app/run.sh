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
#   CONDUIT_DEV_WIDGET=1 crates/app/run.sh         # with the desktop widget
#                                                  # embedded (ad-hoc: macOS
#                                                  # won't list it; see
#                                                  # docs/BUILDING-DESKTOP.md)
#   CONDUIT_SIGN_IDENTITY=<SHA-1> crates/app/run.sh
#                                                  # signed with an Apple
#                                                  # Development identity
#                                                  # (packaging/macos/
#                                                  # sign-dev.sh): Shortcuts
#                                                  # can run the App Intents;
#                                                  # the widget's group gets
#                                                  # the team's prefix
#
# The bundle lives in target/app/ (ignored) and is reused. A scripted run
# (--shots, --e2e, --capture) uses the profile CONDUIT_USER_DATA names, never
# the app's own; without one it starts on a fresh profile in $TMPDIR.
set -eu
cd "$(dirname "$0")/../.."
cargo build -p conduit-desktop --features harness
# Team signing, only when asked; ad-hoc otherwise ("-" means ad-hoc too).
identity="${CONDUIT_SIGN_IDENTITY:-}"
if [ "$identity" = "-" ]; then identity=""; fi
team=""
if [ -n "$identity" ]; then
  team="$(bash packaging/macos/sign-dev.sh team)"
fi
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
# No Services menu items for dev bundles: every worktree's build would add
# its own "Ask Conduit" to the Services menu of every app on this Mac. The
# E2E pass calls the provider itself (desktop::services_provider).
/usr/libexec/PlistBuddy -c 'Delete :NSServices' "$app/Contents/Info.plist" >/dev/null
plutil -lint -s "$app/Contents/Info.plist"
# The privacy prompts in every language, as in a release bundle.
python3 packaging/macos/native_strings.py infoplist ../lib/l10n \
  "$app/Contents/Info.plist" "$app/Contents/Resources" >/dev/null
# The desktop widget, only when asked: every dev bundle would otherwise
# register an extension with the system. Without it, an earlier build's
# widget is moved aside.
widget_dir=target/app/widget
dev_group=app.cogwheel.conduit.desktop.dev
# Team-signed: the group carries the team's prefix, which macOS lets the
# app and its widget use without a provisioning profile.
if [ -n "$team" ]; then dev_group="$team.$dev_group"; fi
if [ "${CONDUIT_DEV_WIDGET:-}" = 1 ]; then
  packaging/macos/widget/build.sh --out "$widget_dir" \
    --bundle-id app.cogwheel.conduit.desktop.dev --app-group "$dev_group"
  mkdir -p "$app/Contents/PlugIns" "$app/Contents/Frameworks"
  for f in "$app/Contents/PlugIns/ConduitWidget.appex" "$app/Contents/Frameworks/libconduit_widget.dylib"; do
    if [ -e "$f" ]; then mv "$f" "$widget_dir/replaced-$(date +%s)-$(basename "$f")"; fi
  done
  ditto "$widget_dir/ConduitWidget.appex" "$app/Contents/PlugIns/ConduitWidget.appex"
  cp "$widget_dir/libconduit_widget.dylib" "$app/Contents/Frameworks/"
  /usr/libexec/PlistBuddy -c "Add :ConduitAppGroup string $dev_group" "$app/Contents/Info.plist"
  # Team-signed bundles sign the widget with the app (sign-dev.sh, below).
  if [ -z "$identity" ]; then
    ents="$widget_dir/entitlements"
    mkdir -p "$ents"
    cp packaging/macos/widget/ConduitWidget.entitlements "$ents/widget.plist"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" \
      -c "Add :com.apple.security.application-groups:0 string $dev_group" "$ents/widget.plist" >/dev/null
    codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libconduit_widget.dylib"
    codesign --force --sign - --timestamp=none --entitlements "$ents/widget.plist" \
      "$app/Contents/PlugIns/ConduitWidget.appex"
  fi
else
  mkdir -p "$widget_dir"
  for f in "$app/Contents/PlugIns/ConduitWidget.appex" "$app/Contents/Frameworks/libconduit_widget.dylib"; do
    if [ -e "$f" ]; then mv "$f" "$widget_dir/unused-$(date +%s)-$(basename "$f")"; fi
  done
fi
# App Intents (Shortcuts, Siri, Spotlight): their metadata and strings,
# made again when the Swift, the strings or the scripts changed.
# The stamp (beside the bundle, outside its signature) is written only once
# metadata and strings are both made, so a failed string step runs again; a
# bundle made anew (its metadata gone) is filled again whatever the stamp says.
meta="$app.intents-built"
if [ ! -f "$meta" ] || [ ! -f "$app/Contents/Resources/Metadata.appintents/extract.actionsdata" ] ||
  [ -n "$(find crates/app/intents ../lib/l10n/desktop \
  packaging/macos/intents.sh packaging/macos/native_strings.py -newer "$meta" | head -1)" ]; then
  bash packaging/macos/intents.sh bundle "$app" >/dev/null
  touch "$meta"
fi
# An ad-hoc signature over the whole bundle (Info.plist included), so the
# system treats it as an app for notifications and the login item. Dev
# secrets go through /usr/bin/security, so the signature changing on each
# build never meets a Keychain prompt. With CONDUIT_SIGN_IDENTITY, the
# team's signature instead (hardened runtime, Conduit.entitlements).
if [ -n "$identity" ]; then
  bash packaging/macos/sign-dev.sh sign "$app"
else
  codesign --force --sign - --timestamp=none "$app" 2>/dev/null || true
fi
if [ "${1:-}" = "--build-only" ]; then
  echo "$PWD/$app"
  exit 0
fi
log=target/app/last-run.log
: > "$log"
# `open` does not pass the environment through; forward the overrides the
# app reads. Each `--env NAME=value` goes in front of the arguments as its
# own words, so a value with spaces stays whole.
# An E2E pass reads aloud into a null sink (everything at volume 0): the
# voices and clips still run, so the reading moves on, and nothing is heard.
case " $* " in
  *" --e2e "*) CONDUIT_SPEECH_OUTPUT=${CONDUIT_SPEECH_OUTPUT:-null} ;;
esac
set -- --stdout "$log" --stderr "$log" --args --cwd "$PWD" "$@"
for var in CONDUITD_PATH CONDUIT_USER_DATA CONDUIT_LOGS CONDUIT_FLAVOR CONDUIT_SHOT_WINDOW \
  CONDUIT_OWUI_ENV CONDUIT_OWUI_DIR CONDUIT_DEV_CACHE CONDUIT_WHISPER_LIB CONDUIT_DICTATION_INPUT \
  CONDUIT_SPEECH_OUTPUT CONDUIT_WIDGET_SNAPSHOT CONDUIT_APPLE_ENGINE; do
  eval "val=\${$var:-}"
  if [ -n "$val" ]; then set -- --env "$var=$val" "$@"; fi
done
open -W -n "$app" "$@"
cat "$log"
grep -q "SMOKE FAILED" "$log" && exit 1
exit 0
