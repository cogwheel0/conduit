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
# (--shots, --smoke, --e2e, --capture) uses the profile CONDUIT_USER_DATA
# names, never the app's own; without one it starts on a fresh profile in
# $TMPDIR.
#
# On Linux it runs the binary itself (no bundle); the app runs on XWayland
# when the session has it, however it's started (D2: the web views embed
# only in X11 windows; CONDUIT_WAYLAND=1 keeps Wayland's own windows):
#
#   crates/app/run.sh                              # run the app
#   crates/app/run.sh --build-only                 # build, print the binary
#   crates/app/run.sh --register-scheme [--force]  # conduit:// links open
#                                                  # this build (a .desktop
#                                                  # file and xdg-mime);
#                                                  # only on this command
#   crates/app/run.sh --unregister-scheme [--force] # undo it
#   crates/app/run.sh --smoke /tmp/smoke.txt       # the smoke pass: its SMOKE
#                                                  # lines in the file, then
#                                                  # quit (exit code 0 if it
#                                                  # passed; --shots is the
#                                                  # Mac's)
#
# Every checkout writes the same conduit-dev.desktop, so both refuse an
# entry another checkout wrote unless --force is given; and the run passes
# on the app's own exit code.
#
# Windows has crates/app/run.ps1.
set -eu
# File arguments are the caller's: made absolute before the cd below, there
# or not, so `run.sh notes.md` still names that file, never one in the
# checkout. Flags, links and the value after each of the app's flags that
# takes one (`--e2e chat`) stay as they are. A link is what the app takes
# for one (`deep_link::from_argv`): a `conduit:`, `file:`, `http:` or
# `https:` URL, `conduit:chat/abc` too. Anything else with a colon
# (`notes:meeting.md`) is a file, to the app as here.
caller="$PWD"
is_link() {
  case "$1" in
    *:*) ;;
    *) return 1 ;;
  esac
  case "$(printf '%s' "${1%%:*}" | tr '[:upper:]' '[:lower:]')" in
    conduit | file | http | https) ;;
    *) return 1 ;;
  esac
}
value_next=0
last=
before=
for arg in "$@"; do
  shift
  given="$arg"
  if [ "$value_next" = 1 ]; then
    value_next=0
  elif [ "$before" = --fixture ] && [ "$last" = perf ] && [ "$arg" = comfortable ]; then
    : # `--fixture perf comfortable`: the perf fixture's layout, a second value
  else
    case "$arg" in
      --cwd | --shots | --smoke | --e2e | --e2e-env | --capture | --capture-env | --capture-only | --probe | \
        --fixture | --chat-fixture | --channel-fixture | --calendar-fixture | --tasks-fixture | --workspace-fixture | --preview-route)
        value_next=1 ;;
      -* | /*) ;;
      *) if ! is_link "$arg"; then arg="$caller/$arg"; fi ;;
    esac
  fi
  before="$last"
  last="$given"
  set -- "$@" "$arg"
done
cd "$(dirname "$0")/../.."
if [ "$(uname -s)" = Linux ]; then
  bin="$PWD/target/debug/conduit-desktop"
  # Only the scheme commands need the data folder.
  data_home="${XDG_DATA_HOME:-}"
  if [ -z "$data_home" ] && [ -n "${HOME:-}" ]; then
    data_home="$HOME/.local/share"
  fi
  apps="${data_home:+$data_home/applications}"
  entry_name=conduit-dev.desktop
  entry="${apps:+$apps/$entry_name}"
  needs_apps() {
    if [ -z "$apps" ]; then
      echo "the conduit:// handler goes in \$XDG_DATA_HOME/applications; set XDG_DATA_HOME or HOME" >&2
      exit 1
    fi
  }
  exec_line="Exec=\"$bin\" %u"
  # An entry another checkout wrote: left alone unless --force.
  others_entry() {
    [ -f "$entry" ] && ! grep -qxF "$exec_line" "$entry" && [ "${2:-}" != --force ]
  }
  case "${1:-}" in
    --unregister-scheme)
      needs_apps
      if others_entry "$@"; then
        echo "$entry opens $(sed -n 's/^Exec=//p' "$entry" | head -1), not this checkout; add --force to remove it" >&2
        exit 1
      fi
      # Moved aside, never deleted (as the widget's files below).
      if [ -f "$entry" ]; then
        mkdir -p target/app
        stamp="$(date +%s)"
        mv "$entry" "target/app/unregistered-$stamp-$entry_name"
        if command -v update-desktop-database >/dev/null 2>&1; then
          update-desktop-database "$apps" || true
        fi
        # xdg-mime made it conduit://'s default in a mimeapps.list (the
        # config folder's; older xdg-utils, the applications folder's):
        # taken out there, a copy of the list kept beside the entry.
        config_home="${XDG_CONFIG_HOME:-${HOME:+$HOME/.config}}"
        for where in config data; do
          case "$where" in
            config) list="${config_home:+$config_home/mimeapps.list}" ;;
            data) list="$apps/mimeapps.list" ;;
          esac
          if [ -n "$list" ] && [ -f "$list" ] && grep -q "^x-scheme-handler/conduit=.*$entry_name" "$list"; then
            cp "$list" "target/app/unregistered-$stamp-$where-mimeapps.list"
            python3 -I packaging/winlinux.py forget-handler "$list" x-scheme-handler/conduit "$entry_name" ||
              echo "$list still names $entry_name for conduit://" >&2
          fi
        done
        echo "conduit:// links no longer open this build"
      else
        echo "no dev conduit:// handler is registered; nothing changed"
      fi
      exit 0
      ;;
  esac
  cargo build -p conduit-desktop --features harness
  case "${1:-}" in
    --build-only)
      echo "$bin"
      exit 0
      ;;
    --register-scheme)
      needs_apps
      current="$(xdg-mime query default x-scheme-handler/conduit 2>/dev/null || true)"
      if [ -n "$current" ] && [ "$current" != "$entry_name" ] && [ "${2:-}" != --force ]; then
        echo "conduit:// links open $current; add --force to point them at this build" >&2
        exit 1
      fi
      if others_entry "$@"; then
        echo "$entry opens $(sed -n 's/^Exec=//p' "$entry" | head -1), not this checkout; add --force to point it at this build" >&2
        exit 1
      fi
      # The Exec line quotes the path; these characters would need escapes
      # (and `%` is a field code there).
      case "$bin" in
        *'"'* | *'`'* | *'$'* | *'\'* | *'%'*)
          echo "this checkout's path can't go in a .desktop file (\" \` \$ \\ or %): $bin" >&2
          exit 1
          ;;
      esac
      mkdir -p "$apps"
      {
        echo '[Desktop Entry]'
        echo 'Type=Application'
        echo 'Name=Conduit Dev'
        echo "Comment=Conduit Desktop, a dev build from $PWD"
        echo "$exec_line"
        echo 'Terminal=false'
        echo 'NoDisplay=true'
        echo 'MimeType=x-scheme-handler/conduit;'
      } > "$entry"
      xdg-mime default "$entry_name" x-scheme-handler/conduit
      if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps" || true
      fi
      echo "conduit:// links now open $bin"
      exit 0
      ;;
  esac
  mkdir -p target/app
  log=target/app/last-run.log
  case " $* " in
    *" --e2e "*) export CONDUIT_SPEECH_OUTPUT="${CONDUIT_SPEECH_OUTPUT:-null}" ;;
  esac
  # The app's exit code, past tee (sh has no pipefail), in a file of this
  # run's own.
  status_file="$(mktemp target/app/last-run.status.XXXXXX)"
  trap 'rm -f "$status_file"' EXIT
  { "$bin" "$@" && code=0 || code=$?; echo "$code" > "$status_file"; } 2>&1 | tee "$log"
  code="$(cat "$status_file")"
  if grep -q "SMOKE FAILED" "$log"; then exit 1; fi
  exit "${code:-1}"
fi
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
# The app's profile a run before embedded stays only if this run embeds it
# again (sign-dev.sh with both profiles): moved aside, never kept stale.
if [ -e "$app/Contents/embedded.provisionprofile" ]; then
  mkdir -p "$widget_dir"
  mv "$app/Contents/embedded.provisionprofile" "$widget_dir/unused-$(date +%s)-embedded.provisionprofile"
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
  CONDUIT_SPEECH_OUTPUT CONDUIT_WIDGET_SNAPSHOT CONDUIT_APPLE_ENGINE \
  CONDUIT_FULL_KEYBOARD_ACCESS CONDUIT_REDUCE_MOTION; do
  eval "val=\${$var:-}"
  if [ -n "$val" ]; then set -- --env "$var=$val" "$@"; fi
done
open -W -n "$app" "$@"
cat "$log"
grep -q "SMOKE FAILED" "$log" && exit 1
exit 0
