#!/bin/bash
# Smoke-tests a built Conduit.app (CI's PR job and local release checks).
#
#   desktop/packaging/macos/smoke.sh APP [--launch]
#
# 1. The bundle: Info.plist lints, Apple Silicon only, signature valid and
#    every Mach-O signed for the app's team (none when ad-hoc);
#    the desktop widget is embedded (a sandboxed WidgetKit extension under
#    the app's id, sharing its app group) with the library the app reloads
#    it through; the Share extension embedded, sandboxed and signed, and the
#    Services items with their titles in every language (share/build.sh);
#    and its App Intents' metadata and strings (intents.sh verify).
# 2. The bundled conduitd, as signed (hardened runtime, entitlements,
#    its own libsqlite3): apps/daemon/tool/smoke.dart starts it, checks the
#    handshake, and that it exits 0 on stdin EOF and on system.shutdown.
# 3. With --launch: the app itself runs its `--shots` smoke pass against a
#    throwaway profile (CONDUIT_USER_DATA, CONDUIT_LOGS): it starts the
#    bundled conduitd, connects, checks that every type the App Intents
#    metadata names is in the binary, captures its windows and quits.
#    Afterwards no conduitd from this bundle may still run.
#
# Set CONDUIT_FLAVOR=dev to keep the master key in the dev Keychain item
# (on a Mac that should not get the release item); CI uses the default.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=share/build.sh
. "$here/share/build.sh"

app="${1:-}"
launch=0
[ "${2:-}" = "--launch" ] && launch=1
[ -d "$app" ] || die "usage: smoke.sh APP [--launch]"
app="$(cd "$app" && pwd)"
daemon="$app/Contents/Resources/conduitd/bin/conduitd"

log "bundle"
plutil -lint "$app/Contents/Info.plist"
lipo -info "$app/Contents/MacOS/Conduit" "$daemon"
while IFS= read -r f; do
  [ "$(lipo -archs "$f")" = "$ARCH" ] || die "$f is $(lipo -archs "$f")"
done < <(macho_files "$app")
codesign --verify --deep --strict --verbose=2 "$app"
# One signer throughout: every Mach-O under the app's team (ad-hoc: none).
signature="$(signature_of "$app")"
teams="$(macho_teams "$app")"
others="$(awk -v t="${signature%% *}" '$1 != t' <<<"$teams")"
[ -z "$others" ] || die "Mach-O files signed for another team than the app's (${signature%% *}): $others"
printf 'signature: %s, team %s on all %s Mach-O files\n' "${signature#* }" "${signature%% *}" \
  "$(wc -l <<<"$teams" | tr -d ' ')"
share_verify "$app" "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" ||
  die "the Share extension or the Services items are not as they should be"
log "Share extension and Services items"
python3 "$here/native_strings.py" infoplist --verify "$REPO_ROOT/lib/l10n" "$app" ||
  die "a privacy prompt is missing its words in a language"
log "privacy prompts in every language (InfoPlist.strings)"

log "desktop widget"
appex="$app/Contents/PlugIns/ConduitWidget.appex"
[ -d "$appex" ] || die "no Contents/PlugIns/ConduitWidget.appex"
plutil -lint "$appex/Contents/Info.plist"
point="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$appex/Contents/Info.plist")"
[ "$point" = com.apple.widgetkit-extension ] || die "the widget's extension point is '$point'"
app_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
widget_id="$(plutil -extract CFBundleIdentifier raw -o - "$appex/Contents/Info.plist")"
[ "$widget_id" = "$app_id.widget" ] || die "the widget's id $widget_id is not $app_id.widget"
group="$(plutil -extract ConduitAppGroup raw -o - "$app/Contents/Info.plist")"
[ "$(plutil -extract ConduitAppGroup raw -o - "$appex/Contents/Info.plist")" = "$group" ] ||
  die "the app and the widget name different app groups"
codesign --verify --strict --verbose=2 "$appex"
widget_ents="$(codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -convert json -o - -)"
grep -q '"com.apple.security.app-sandbox":true' <<<"$widget_ents" || die "the widget is not sandboxed"
grep -Fq "\"$group\"" <<<"$widget_ents" || die "the widget lacks the app group $group"
grep -Fq "\"$group\"" <<<"$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - -)" ||
  die "the app lacks the app group $group"
nm -gU "$app/Contents/Frameworks/libconduit_widget.dylib" | grep -q _conduit_widget_reload_all ||
  die "libconduit_widget.dylib is missing or lacks conduit_widget_reload_all"
printf 'widget %s, app group %s\n' "$widget_id" "$group"

log "App Intents"
"$here/intents.sh" verify "$app"

log "conduitd handshake (apps/daemon/tool/smoke.dart)"
(cd "$REPO_ROOT/apps/daemon" && dart run tool/smoke.dart "$daemon")

if [ "$launch" = 1 ]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/conduit-smoke.XXXXXX")"
  mkdir -p "$scratch/user-data" "$scratch/logs" "$scratch/shots"
  log "app launch smoke (profile in $scratch)"
  status=0
  # The bundle's own conduitd, whatever CONDUITD_PATH says.
  env -u CONDUITD_PATH CONDUIT_USER_DATA="$scratch/user-data" CONDUIT_LOGS="$scratch/logs" \
    "$app/Contents/MacOS/Conduit" --shots "$scratch/shots" >"$scratch/run.log" 2>&1 || status=$?
  grep '^SMOKE' "$scratch/run.log" || true
  if [ "$status" != 0 ] || grep -q 'SMOKE FAILED' "$scratch/run.log" ||
    ! grep -q 'SMOKE status Connected' "$scratch/run.log" ||
    ! grep -Eq 'SMOKE intents [0-9]+ types resolve' "$scratch/run.log"; then
    tail -n 60 "$scratch/run.log" >&2
    die "the app smoke failed (exit $status)"
  fi
  grep -h 'conduitd' "$scratch/logs"/*.log 2>/dev/null | grep -m3 -E 'spawn|ready|Resources/conduitd' || true
  sleep 1
  # By executable path, exactly (never a pattern over command lines).
  if ps -axo pid=,comm= | awk -v d="$daemon" '{p=$1; sub(/^ *[0-9]+ /, ""); if ($0 == d) print p}' | grep -q .; then
    die "a conduitd from this bundle is still running after the app quit"
  fi
  log "no orphan conduitd"
fi
log "smoke passed"
