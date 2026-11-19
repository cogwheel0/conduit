#!/bin/bash
# The Share extension and the Services items in a built bundle, end to end,
# as other apps reach them:
#
#   desktop/packaging/macos/share/e2e-system.sh APP --shots DIR [--keep]
#
# 1. Registers APP with LaunchServices and its extension with PlugInKit
#    (`pluginkit -a`, then `-e use`), and checks `pluginkit -m` lists it and
#    `pbs` lists the two Services items.
# 2. Starts APP with `--e2e share-system` (it signs in to the local Open
#    WebUI, tool/local_owui, and waits).
# 3. tests/ShareDriver.swift, an app of its own, opens the extension's
#    sharing service with synthetic text and a file, as a Share menu does:
#    ShareKit must put up the extension's remote view, and the sandboxed
#    extension must stage a copy of the file in the inbox (unpublished).
#    The driver then quits, which closes the sheet without sharing.
# 4. Open in Conduit cannot be pressed from outside (the remote view takes
#    no synthetic keys, and AppleScript would need Accessibility access), so
#    the script finishes that staged share as the button does (the manifest
#    ShareInbox.swift writes, the final name) and opens its link with this
#    app (`open -a APP`), never the scheme's default handler. The app must
#    show a new chat with the text and the extension's copy of the file.
# 5. "Ask Conduit" through NSPerformService, as the Services menu calls it,
#    once `pbs` shows that only this bundle provides it; the app must show
#    Quick Ask with the selection quoted.
# 6. Unregisters everything again (unless --keep), and moves the test
#    shares out of the inbox into DIR/inbox.
#
# Left to a person: pressing Open in Conduit and Cancel in the real sheet,
# and how it looks (share/preview.sh draws its content).
#
# APP must be a test bundle with its own id (bundle.sh --bundle-id …
# --test-env CONDUIT_FLAVOR=dev --test-env CONDUIT_USER_DATA=… --test-env
# CONDUIT_LOGS=…): registering the release id would put this build in the
# Share and Services menus of the Mac's real Conduit. The release id is
# refused. Run it with the GUI to itself (it activates windows).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib.sh
. "$here/../lib.sh"
# shellcheck source=build.sh
. "$here/build.sh"

app="${1:-}"
shift || true
shots=""
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --shots) shots="$2"; shift ;;
    --keep) keep=1 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[ -d "$app" ] && [ -n "$shots" ] || die "usage: e2e-system.sh APP --shots DIR [--keep]"
app="$(cd "$app" && pwd)"
mkdir -p "$shots"
shots="$(cd "$shots" && pwd)"
plist="$app/Contents/Info.plist"
app_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
[ "$app_id" != "$BUNDLE_ID_DEFAULT" ] || die "refusing the release id $app_id: build a test bundle"
plutil -extract LSEnvironment.CONDUIT_FLAVOR raw -o - "$plist" >/dev/null 2>&1 ||
  die "$app has no LSEnvironment (bundle.sh --test-env CONDUIT_FLAVOR=dev …)"
ext_id="$app_id.share"
appex="$app/Contents/PlugIns/$SHARE_APPEX"
inbox="$HOME/Library/Caches/$app_id.share-inbox"
pbs=/System/Library/CoreServices/pbs
marker="Synthetic text from the share driver"
log_file="$shots/app.log"
pass=0
fail=0
check() {
  if [ "$1" = 0 ]; then
    printf 'SYSTEM ok %s\n' "$2"
    pass=$((pass + 1))
  else
    printf 'SYSTEM FAILED %s\n' "$2"
    fail=$((fail + 1))
  fi
}

app_pid=""
unregister() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
  if [ "$keep" = 0 ]; then
    pluginkit -e default -i "$ext_id" >/dev/null 2>&1 || true
    pluginkit -r "$appex" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    "$pbs" -update >/dev/null 2>&1 || true
    log "unregistered $app_id and $ext_id"
  fi
}
trap unregister EXIT

# --- 1. registration ---------------------------------------------------------
log "registering $app_id"
"$LSREGISTER" -f "$app"
pluginkit -a "$appex"
pluginkit -e use -i "$ext_id"
listed=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if pluginkit -m -i "$ext_id" | grep -q "$ext_id"; then listed=0; break; fi
  sleep 1
done
check $listed "pluginkit -m lists $ext_id"
pluginkit -m -v -i "$ext_id" | sed 's/^/     /'
"$pbs" -update
services_listed=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  dump="$("$pbs" -dump 2>/dev/null || true)"
  if grep -q "Ask Conduit" <<<"$dump" && grep -q "New Conduit Chat With Selection" <<<"$dump"; then
    services_listed=0
    break
  fi
  sleep 1
done
check $services_listed "pbs lists Ask Conduit and New Conduit Chat With Selection"

# --- the driver and its files ------------------------------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/conduit-share-system.XXXXXX")"
xcrun swiftc -swift-version 5 -target "$ARCH-apple-macos$MACOS_MIN" -o "$work/ShareDriver" \
  "$here/tests/ShareDriver.swift" 2>/dev/null
mkdir -p "$work/files"
printf '# Seed list\n\n- chard\n- sorrel\n' >"$work/files/seed list.md"
driver() { "$work/ShareDriver" "$@"; }

# --- 2. the app --------------------------------------------------------------
log "starting $app_id (--e2e share-system)"
: >"$log_file"
open -n "$app" --env "CONDUIT_SHARE_MARKER=$marker" \
  ${CONDUIT_OWUI_ENV:+--env "CONDUIT_OWUI_ENV=$CONDUIT_OWUI_ENV"} \
  --stdout "$log_file" --stderr "$log_file" \
  --args --cwd "$DESKTOP_DIR" --shots "$shots" --e2e share-system
wait_log() {
  local pattern="$1" seconds="$2" i=0
  while [ "$i" -lt "$seconds" ]; do
    grep -q "$pattern" "$log_file" 2>/dev/null && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
ready=1
wait_log "SMOKE share-system ready" 120 && ready=0
check $ready "the app signed in and waits for a share"
app_pid="$(pgrep -f "$app/Contents/MacOS/Conduit" | head -1 || true)"

# --- 3. the Share menu -------------------------------------------------------
parts() { { find "$inbox" -mindepth 1 -maxdepth 1 -name '*.part' 2>/dev/null || true; } | sort; }
before="$(parts)"
driver share "$ext_id" 6 "$marker" "$work/files/seed list.md" >"$shots/driver-share.log" 2>&1 || true
sed 's/^/     /' "$shots/driver-share.log"
presented=1
grep -q "DRIVER presented" "$shots/driver-share.log" && presented=0
check $presented "ShareKit presents the extension's sheet for text and a file"
part="$(comm -13 <(printf '%s\n' "$before") <(parts) | tail -1)"
staged=1
if [ -n "$part" ] && cmp -s "$part/files/0/seed list.md" "$work/files/seed list.md" &&
  [ ! -e "$part/manifest.json" ]; then
  staged=0
fi
check $staged "the sandboxed extension staged its copy of the file in the inbox, unpublished"

# --- 4. the hand-off Open in Conduit makes -------------------------------------
if [ -n "$part" ]; then
  id="$(basename "$part" .part)"
  cat >"$part/manifest.json" <<JSON
{"version": 1, "texts": ["$marker"], "urls": [], "tooLarge": [], "tooMany": 0,
 "files": [{"name": "seed list.md", "path": "files/0/seed list.md"}]}
JSON
  mv "$part" "$inbox/$id"
  open -a "$app" "conduit://share/$id"
fi
shared=1
wait_log "SMOKE share-system shared" 90 && shared=0
check $shared "the app opened a new chat with the shared text and the extension's copy of the file"
taken="$({ find "$inbox" -name manifest.taken.json 2>/dev/null || true; } | wc -l | tr -d ' ')"
check "$([ "$taken" -ge 1 ] && echo 0 || echo 1)" "the share in the inbox is marked taken"

# --- 5. the Services menu ----------------------------------------------------
# Only when this bundle alone answers "Ask Conduit": never a real Conduit.
providers="$("$pbs" -dump 2>/dev/null |
  awk '/NSBundleIdentifier =/ {id=$3} /default = "Ask Conduit"/ {print id}' |
  tr -d '";' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$providers" = "$app_id" ]; then
  status=0
  driver service "Ask Conduit" "$marker, selected in another app" || status=$?
  check $status "NSPerformService(\"Ask Conduit\") reaches Conduit"
else
  check 1 "only $app_id provides Ask Conduit (pbs: '$providers'); not invoked"
fi
done_=1
wait_log "SMOKE share-system done" 60 && done_=0
check $done_ "the app finished its checks"
for _ in $(seq 1 30); do
  pgrep -f "$app/Contents/MacOS/Conduit" >/dev/null || break
  sleep 1
done
app_pid=""
mkdir -p "$shots/inbox"
for entry in "$inbox"/*; do
  [ -e "$entry" ] && mv "$entry" "$shots/inbox/"
done

grep -E '^SMOKE (e2e ok|FAILED)' "$log_file" | sed 's/^/     /' || true
app_ok="$(grep -c 'SMOKE e2e ok' "$log_file" || true)"
app_failed="$(grep -c 'SMOKE FAILED' "$log_file" || true)"
printf 'SYSTEM app: %s ok, %s failed\n' "$app_ok" "$app_failed"
printf 'SYSTEM %s ok, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ] && [ "$app_failed" = 0 ] && [ "$app_ok" -gt 0 ]
