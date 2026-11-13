#!/bin/sh
# The design capture, end to end: screenshots of every screen and state,
# frame strips of the transitions, contact sheets and copy notes, for
# reviewing the app's design. A fresh local Open WebUI (reset and seeded,
# plus the showcase chat), a release build of the app (with the `harness`
# feature) in its own .app, a throwaway profile, `--capture` into a capture
# folder, then the strips, sheets and notes.
#
#   crates/app/hc-capture.sh               # the next capture: captures/c0, c1, …
#   crates/app/hc-capture.sh NAME          # captures/NAME (must not exist)
#   crates/app/hc-capture.sh --out DIR     # anywhere
#   options: --no-reset (keep the server's data), --only a,b (phases:
#            onboarding main shell motion narrow reconnect; for iterating),
#            --skip-build, --compose-only DIR
#
# Paths (environment):
#   CONDUIT_HC_DIR       the capture's root (default
#                        ~/Library/Caches/conduit-dev/capture); captures go
#                        to $CONDUIT_HC_DIR/captures/, throwaway profiles
#                        and logs to $CONDUIT_HC_DIR/run/
#   CONDUIT_HC_OWUI_DIR  the local Open WebUI instance (default
#                        $CONDUIT_HC_DIR/owui), CONDUIT_HC_OWUI_PORT (8350;
#                        the fake model and Hermes take the next two)
#   CONDUITD_PATH        the daemon; else this checkout's apps/daemon build,
#                        else $CONDUIT_HC_DIR/daemon/bundle/bin/conduitd
#
# The app runs with the dev flavor, its own bundle id and a new
# CONDUIT_USER_DATA / CONDUIT_LOGS each run, with Full Keyboard Access on
# (System Settings › Keyboard Navigation) whatever this Mac has; it never touches another
# profile, the production Keychain item or a real server. The profile's
# preferences turn the global Quick Ask shortcut, answer notifications and
# the menu-bar item off, so a run never takes the user's shortcut or posts
# notifications (the menu-bar item is shown only while it is captured).
# Nothing is deleted: old captures are kept, and owui.sh reset moves old
# server data aside.
set -eu
cd "$(dirname "$0")/../.."
DESKTOP=$PWD
ROOT=$(cd .. && pwd)
CACHE=${CONDUIT_DEV_CACHE:-$HOME/Library/Caches/conduit-dev}
HC=${CONDUIT_HC_DIR:-$CACHE/capture}
OWUI_DIR=${CONDUIT_HC_OWUI_DIR:-$HC/owui}
OWUI_PORT=${CONDUIT_HC_OWUI_PORT:-8350}
VENV=${CONDUIT_OWUI_VENV:-$CACHE/owui-0.13.2}
PY="$VENV/bin/python"
export PATH="$(brew --prefix rustup 2>/dev/null || echo /opt/homebrew/opt/rustup)/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

name=""
out=""
reset=1
only=""
build=1
compose_only=""
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=$2; shift 2 ;;
    --no-reset) reset=0; shift ;;
    --only) only=$2; shift 2 ;;
    --skip-build) build=0; shift ;;
    --compose-only) compose_only=$2; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *) name=$1; shift ;;
  esac
done

# compose CAPTURE_DIR [RUN_DIR]: the older whole-window motion rule, kept
# for comparison, goes to RUN_DIR (the run's log folder), never into the
# capture folder.
compose() {
  dir=$1
  logs=${2:-$HC/run/$(basename "$dir")-compose-$(date +%Y%m%d-%H%M%S)}
  "$PY" -I "$DESKTOP/crates/app/hc/compose.py" "$dir" "$logs"
  "$PY" -I "$DESKTOP/crates/app/hc/copy_notes.py" --root "$ROOT" --out "$dir/notes/copy.md"
  echo "capture folder: $dir"
}

if [ -n "$compose_only" ]; then
  compose "$compose_only"
  exit 0
fi

if [ -z "$out" ]; then
  if [ -z "$name" ]; then
    n=0
    while [ -e "$HC/captures/c$n" ]; do n=$((n + 1)); done
    name=c$n
  fi
  out=$HC/captures/$name
fi
if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
  echo "$out exists and is not empty; pick another name" >&2
  exit 1
fi
mkdir -p "$out"

# One GUI app at a time: another Conduit window (a capture, an E2E or smoke
# run from any worktree) would steal activation and gray the shots' chrome.
# The app bundle's executable only, by each process's executable path (not
# its command line): a shell whose arguments name the path is not an app.
other_gui() { ps -axo comm= | grep -q '\.app/Contents/MacOS/conduit-desktop$'; }
# Waits until no other Conduit app has run for 90 s in a row (E2E suites
# start one app after another), for at most an hour.
wait_for_quiet() {
  quiet=0
  waited=0
  while [ "$quiet" -lt 90 ]; do
    if other_gui; then
      if [ "$waited" = 0 ]; then
        echo "another Conduit app is running (an .app/Contents/MacOS/conduit-desktop); waiting until none has run for 90 s" >&2
      fi
      quiet=0
    else
      quiet=$((quiet + 5))
    fi
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge 3600 ]; then
      echo "other Conduit apps kept running for an hour; giving up" >&2
      exit 1
    fi
  done
}
if other_gui; then wait_for_quiet; fi

# 1. The server: reset and seeded, then the showcase chat.
if [ ! -x "$PY" ]; then
  echo "no Open WebUI venv at $VENV: run tool/local_owui/owui.sh setup" >&2
  exit 1
fi
if [ "$reset" = 1 ]; then
  CONDUIT_OWUI_DIR=$OWUI_DIR "$ROOT/tool/local_owui/owui.sh" reset --port "$OWUI_PORT"
else
  CONDUIT_OWUI_DIR=$OWUI_DIR "$ROOT/tool/local_owui/owui.sh" up --port "$OWUI_PORT"
fi
ENV_FILE=$OWUI_DIR/local-owui.env
stamp=$(date +%Y%m%d-%H%M%S)
run_dir=$HC/run/$(basename "$out")-$stamp
mkdir -p "$run_dir/userdata" "$run_dir/logs"
"$PY" -I "$DESKTOP/crates/app/hc/seed_showcase.py" --env-file "$ENV_FILE" \
  --data "$OWUI_DIR/data" --out "$run_dir/capture.env"

# 2. The daemon.
daemon=${CONDUITD_PATH:-}
if [ -z "$daemon" ] && [ -x "$ROOT/apps/daemon/build/cli/macos_arm64/bundle/bin/conduitd" ]; then
  daemon=$ROOT/apps/daemon/build/cli/macos_arm64/bundle/bin/conduitd
fi
if [ -z "$daemon" ] && [ -x "$HC/daemon/bundle/bin/conduitd" ]; then
  daemon=$HC/daemon/bundle/bin/conduitd
fi
if [ -z "$daemon" ]; then
  echo "no daemon: build apps/daemon (dart build cli) or set CONDUITD_PATH" >&2
  exit 1
fi

# 3. The app: release, in its own bundle so it can be the active app.
if [ "$build" = 1 ]; then
  cargo build --release -p conduit-desktop --features harness
fi
app="target/hc/Conduit Capture.app"
mkdir -p "$app/Contents/MacOS"
# A new file moved into place: overwriting in place keeps the inode and
# macOS refuses to launch it (error 162).
cp -f target/release/conduit-desktop "$app/Contents/MacOS/conduit-desktop.new"
mv -f "$app/Contents/MacOS/conduit-desktop.new" "$app/Contents/MacOS/conduit-desktop"
sed -e 's/@BUNDLE_ID@/app.cogwheel.conduit.desktop.capture/' \
    -e 's/@BUNDLE_NAME@/Conduit Capture/' \
    -e 's/@EXECUTABLE@/conduit-desktop/' \
    -e 's/@VERSION@/0.0.0/' \
    -e 's/@BUILD@/0/' \
    packaging/macos/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app" 2>/dev/null || true

# 4. The throwaway profile: English, light, no global shortcut, no
# notifications, no menu-bar item; the window where the shots expect it.
cat > "$run_dir/userdata/desktop-preferences.json" <<'JSON'
{
  "appearance": { "mode": "light" },
  "locale": "en",
  "desktop": {
    "closeToMenuBar": false,
    "launchAtLogin": false,
    "quickAsk": false,
    "notifyAnswers": false,
    "notifyChannels": false
  }
}
JSON
cat > "$run_dir/userdata/window-state.json" <<'JSON'
{ "x": 96, "y": 64, "width": 1280, "height": 860, "maximized": false, "sidebarVisible": true }
JSON

# 5. The capture. `open` does not pass the environment through.
if other_gui; then wait_for_quiet; fi
log=$run_dir/capture.log
: > "$log"
only_args=""
if [ -n "$only" ]; then only_args="--capture-only $only"; fi
echo "capturing into $out (log $log)"
# shellcheck disable=SC2086
open -W -n "$app" \
  --env "CONDUITD_PATH=$daemon" \
  --env "CONDUIT_USER_DATA=$run_dir/userdata" \
  --env "CONDUIT_LOGS=$run_dir/logs" \
  --env "CONDUIT_FLAVOR=dev" \
  --env "CONDUIT_FULL_KEYBOARD_ACCESS=1" \
  --stdout "$log" --stderr "$log" \
  --args --cwd "$DESKTOP" --capture "$out" \
  --e2e-env "$ENV_FILE" --capture-env "$run_dir/capture.env" $only_args
grep -E "^CAPTURE (done|FAILED)" "$log" || true
# The capture's copy of the log says ~ for the home folder.
sed "s|$HOME|~|g" "$log" > "$out/notes/capture.log"

# 6. Strips, contact sheets, copy notes.
compose "$out" "$run_dir"
grep -q "^CAPTURE FAILED" "$log" && exit 1
# A run that ended without saying it finished (a crash, a quit) failed too.
grep -q "^CAPTURE done" "$log" || { echo "the capture did not finish" >&2; exit 1; }
exit 0
