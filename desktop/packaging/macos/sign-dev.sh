#!/bin/bash
# Team signing for the dev bundle crates/app/run.sh makes ("Conduit
# Dev.app", app.cogwheel.conduit.desktop.dev), with the identity in
# CONDUIT_SIGN_IDENTITY: an Apple Development identity's SHA-1
# (`security find-identity -v -p codesigning`). With a team ID in the
# signature, Shortcuts and Spotlight can run the app's App Intents, and the
# app and its widget can share a team-prefixed app group.
#
#   sign-dev.sh team        prints the identity's team (the certificate's;
#                           a revoked or unknown identity is refused)
#   sign-dev.sh sign APP    signs APP inside out with the hardened runtime
#                           and no secure timestamp, as Xcode signs Debug
#                           builds: the widget's library and extension when
#                           embedded (sandboxed, entitled to the app group
#                           the app's Info.plist names; with
#                           CONDUIT_APP_PROFILE and CONDUIT_WIDGET_PROFILE,
#                           Mac Development profiles for the app's and the
#                           widget's ids, embedded as bundle.sh does), then
#                           the app with Conduit.entitlements (and that
#                           group). Both get get-task-allow, as Xcode's
#                           Debug builds do, so lldb and Instruments can
#                           attach; only in these dev copies, never in the
#                           files bundle.sh signs a release with
#
# Without CONDUIT_SIGN_IDENTITY, run.sh signs ad hoc and never calls this.
# The release bundle id is refused: development signatures are for test
# bundles only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

identity="${CONDUIT_SIGN_IDENTITY:-}"
if [ -z "$identity" ] || [ "$identity" = "-" ]; then
  die "sign-dev.sh: CONDUIT_SIGN_IDENTITY is not set"
fi
signing_identity "$identity"
[ -n "$SIGN_TEAM" ] || die "sign-dev.sh: the CONDUIT_SIGN_IDENTITY certificate names no team"

sign_dev_bundle() {
  local app="$1"
  [ -d "$app/Contents" ] || die "no app at $app"
  local plist="$app/Contents/Info.plist" id group
  id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
  [ "$id" != "$BUNDLE_ID_DEFAULT" ] || die "sign-dev.sh signs test bundles only, never $BUNDLE_ID_DEFAULT"
  # The dev app is built with the test harness: never with a Developer ID.
  refuse_harness_distribution "$(app_binary "$app")" "$SIGN_KIND"
  group="$(plutil -extract ConduitAppGroup raw -o - "$plist" 2>/dev/null || true)"
  local ent
  ent="$(dirname "$app")/entitlements"
  mkdir -p "$ent"
  dev_entitlements "$PACKAGING_DIR/Conduit.entitlements" "$ent/Conduit.entitlements"
  sign() { codesign --force --sign "$identity" --timestamp=none --options runtime "$@"; }

  local appex="$app/Contents/PlugIns/ConduitWidget.appex"
  if [ -d "$appex" ]; then
    case "$group" in
      "$SIGN_TEAM".*) ;;
      *) die "the widget is embedded, but the app's group '$group' is not prefixed with team $SIGN_TEAM" ;;
    esac
    dev_entitlements "$PACKAGING_DIR/widget/ConduitWidget.entitlements" "$ent/ConduitWidget.entitlements"
    local e
    for e in Conduit ConduitWidget; do
      set_plist "Add :com.apple.security.application-groups array" "$ent/$e.entitlements"
      set_plist "Add :com.apple.security.application-groups:0 string $group" "$ent/$e.entitlements"
    done
    # Development provisioning profiles for the two ids, when given: what
    # macOS needs before it lists the widget (docs/BUILDING-DESKTOP.md).
    embed_profiles "$app" "$id" "$SIGN_TEAM" "$ent"
    sign "$app/Contents/Frameworks/libconduit_widget.dylib"
    sign --entitlements "$ent/ConduitWidget.entitlements" "$appex"
  elif [ -n "${CONDUIT_APP_PROFILE:-}${CONDUIT_WIDGET_PROFILE:-}" ]; then
    warn "provisioning profiles ignored: the dev bundle has no widget (CONDUIT_DEV_WIDGET=1)"
  fi
  sign --entitlements "$ent/Conduit.entitlements" "$app"
  codesign --verify --deep --strict "$app"
  log "signed $(basename "$app") (team $SIGN_TEAM, $SIGN_KIND, hardened runtime${group:+, app group $group})"
}

case "${1:-}" in
  team) printf '%s\n' "$SIGN_TEAM" ;;
  sign)
    [ $# -eq 2 ] || die "usage: sign-dev.sh sign APP"
    sign_dev_bundle "$2"
    ;;
  *) die "usage: sign-dev.sh team | sign APP" ;;
esac
