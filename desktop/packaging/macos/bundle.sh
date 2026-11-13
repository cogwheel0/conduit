#!/bin/bash
# Builds, signs, notarizes and packages Conduit Desktop for macOS (Apple
# Silicon, macOS 14+): Conduit.app and Conduit-<version>.dmg.
#
#   desktop/packaging/macos/bundle.sh [command] [options]
#
# Commands (default: all, in this order):
#   build          compile the app (Rust, with its Swift App Intents),
#                  conduitd (`dart build cli`), libconduit_whisper, the
#                  desktop widget (widget/build.sh) and the Share extension
#                  (share/build.sh), and assemble an unsigned Conduit.app
#                  (the intents' metadata and strings from intents.sh, the
#                  third-party notices from notices/notices.sh, which needs
#                  cargo-about). The app is built without its test harness
#                  (no `harness` feature).
#   sign           sign inside out with the hardened runtime: conduitd's
#                  libraries, conduitd, Sparkle's helpers and framework, the
#                  widget's library and extension, the Share extension
#                  (sandboxed), the app
#   notarize-app   notarize Conduit.app and staple it (skipped without
#                  credentials, see below)
#   dmg            Conduit-<version>.dmg with an Applications link (signed
#                  when there is a signing identity)
#   notarize-dmg   notarize the DMG and staple it (skipped without credentials)
#   verify         codesign, Gatekeeper, architecture, minimum-OS,
#                  Info.plist, App Intents, notices and no-test-harness
#                  checks (harness_check.sh), and the bundle's sizes
#   all            everything above
#
# Options:
#   --version V    1.2.0 or 1.3.0-beta.2 (default 0.0.0). The build number
#                  (CFBundleVersion) is derived from it (lib.sh build_number).
#   --out DIR      output folder (default desktop/target/macos/Conduit-<version>);
#                  `build` moves an existing one aside, never deletes it
#   --release      CI mode: a missing identity, notarization credentials,
#                  Sparkle key or app icon is an error instead of a warning
#   --skip-rust, --skip-daemon, --skip-whisper
#                  reuse what an earlier build left (local iteration)
#   --bundle-id ID, --test-env K=V
#                  local update tests only (another bundle id; LSEnvironment
#                  entries); refused with --release
#
# Environment:
#   CONDUIT_SIGN_IDENTITY   codesign identity ("Developer ID Application: …"
#                           or its SHA-1); default "-" (ad-hoc). An Apple
#                           Development identity signs local test bundles
#                           (--bundle-id only, never --release): the team
#                           comes from its certificate, no secure timestamp,
#                           no notarization; Shortcuts can then run the
#                           App Intents (docs/BUILDING-DESKTOP.md). A
#                           revoked or unknown identity is refused.
#   CONDUIT_NOTARY_PROFILE  a `notarytool store-credentials` profile, or
#   CONDUIT_NOTARY_KEY_FILE + CONDUIT_NOTARY_KEY_ID + CONDUIT_NOTARY_ISSUER
#                           an App Store Connect API key (.p8)
#   SPARKLE_PUBLIC_ED_KEY   Sparkle's public EdDSA key (base64). Without it
#                           the bundle carries no Sparkle and no updater.
#   CONDUIT_APP_PROFILE, CONDUIT_WIDGET_PROFILE
#                           provisioning profiles (.provisionprofile) for the
#                           app and the widget extension, embedded when set.
#                           macOS lists the widget only when a profile
#                           vouches for its entitlements (docs/BUILDING-
#                           DESKTOP.md, "The desktop widget")
#   CONDUIT_APPCAST_URL     overrides the feed URL release.env derives
#   CMAKE                   cmake to build whisper with (default: cmake)
#   WHISPER_SOURCE_DIR      a whisper.cpp checkout to build from (offline)
#
# Nothing here deletes files: earlier outputs are moved aside.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=share/build.sh
. "$here/share/build.sh"

command=all
version=0.0.0
out=""
release=0
skip_rust=0
skip_daemon=0
skip_whisper=0
bundle_id="$BUNDLE_ID_DEFAULT"
test_env=()
while [ $# -gt 0 ]; do
  case "$1" in
    build | sign | notarize-app | dmg | notarize-dmg | verify | all) command="$1" ;;
    --version) version="$2"; shift ;;
    --out) out="$2"; shift ;;
    --release) release=1 ;;
    --skip-rust) skip_rust=1 ;;
    --skip-daemon) skip_daemon=1 ;;
    --skip-whisper) skip_whisper=1 ;;
    --bundle-id) bundle_id="$2"; shift ;;
    --test-env) test_env+=("$2"); shift ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

check_version "$version"
build="$(build_number "$version")"
out="${out:-$DESKTOP_DIR/target/macos/Conduit-$version}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
app="$out/Conduit.app"
dmg="$out/Conduit-$version.dmg"
identity="${CONDUIT_SIGN_IDENTITY:--}"
feed_url="$(appcast_url)"
# The signing team and kind (SIGN_TEAM, SIGN_KIND: lib.sh).
signing_identity "$identity"
team="$SIGN_TEAM"
# The widget's app group: release.env's, with the signing team's prefix.
# A local test bundle (--bundle-id) keeps to a group of its own, away from
# the release app's snapshot: <team>.<test id> when team-signed (macOS
# lets an app use a group prefixed with its own team without a profile).
group="$(widget_group "$team")"
if [ "$bundle_id" != "$BUNDLE_ID_DEFAULT" ]; then
  group="${team:+$team.}$bundle_id"
fi

if [ "$release" = 1 ]; then
  [ "$bundle_id" = "$BUNDLE_ID_DEFAULT" ] || die "--bundle-id is for local tests only"
  [ ${#test_env[@]} -eq 0 ] || die "--test-env is for local tests only"
  [ "$SIGN_KIND" != development ] ||
    die "--release needs a Developer ID Application identity, not an Apple Development one"
fi
if [ "$SIGN_KIND" = development ] && [ "$bundle_id" = "$BUNDLE_ID_DEFAULT" ]; then
  die "an Apple Development identity signs test bundles only: pass --bundle-id <a test id>, never $BUNDLE_ID_DEFAULT"
fi

# Fails in --release mode, warns otherwise.
need() {
  if [ "$release" = 1 ]; then die "$1"; else warn "$1"; fi
}

notary_args=()
notary_credentials() {
  notary_args=()
  if [ -n "${CONDUIT_NOTARY_PROFILE:-}" ]; then
    notary_args=(--keychain-profile "$CONDUIT_NOTARY_PROFILE")
  elif [ -n "${CONDUIT_NOTARY_KEY_FILE:-}" ] && [ -n "${CONDUIT_NOTARY_KEY_ID:-}" ] &&
    [ -n "${CONDUIT_NOTARY_ISSUER:-}" ]; then
    notary_args=(--key "$CONDUIT_NOTARY_KEY_FILE" --key-id "$CONDUIT_NOTARY_KEY_ID"
      --issuer "$CONDUIT_NOTARY_ISSUER")
  fi
  [ ${#notary_args[@]} -gt 0 ]
}

# --- build -----------------------------------------------------------------

build_rust() {
  local binary="$DESKTOP_DIR/target/$RUST_TARGET/release/conduit-desktop"
  if [ "$skip_rust" = 1 ]; then
    [ -f "$binary" ] || die "--skip-rust: no $binary"
    log "reusing $binary"
  else
    log "cargo build --release --target $RUST_TARGET (version $version, build $build)"
    (cd "$DESKTOP_DIR" &&
      MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" CONDUIT_VERSION="$version" CONDUIT_BUILD="$build" \
        cargo build --release --locked --target "$RUST_TARGET" -p conduit-desktop)
  fi
  rust_binary="$binary"
}

# The Dart packages' generated code (*.g.dart, *.freezed.dart) is not
# committed; generate it when the core's is missing.
dart_codegen() {
  if find "$REPO_ROOT/packages/conduit_core/lib" -name '*.g.dart' -print -quit | grep -q .; then
    return
  fi
  log "generating Dart code (build_runner)"
  (cd "$REPO_ROOT" && flutter pub get)
  local dir
  for dir in "$REPO_ROOT"/packages/* "$REPO_ROOT"/apps/*; do
    if [ -f "$dir/pubspec.yaml" ] && grep -q '^  build_runner:' "$dir/pubspec.yaml"; then
      log "build_runner in ${dir#"$REPO_ROOT"/}"
      (cd "$dir" && dart run build_runner build)
    fi
  done
}

build_daemon() {
  daemon_bundle="$REPO_ROOT/apps/daemon/build/cli/macos_$ARCH/bundle"
  if [ "$skip_daemon" = 1 ]; then
    [ -x "$daemon_bundle/bin/conduitd" ] || die "--skip-daemon: no $daemon_bundle/bin/conduitd"
    log "reusing $daemon_bundle"
    return
  fi
  dart_codegen
  log "dart build cli (apps/daemon)"
  (cd "$REPO_ROOT/apps/daemon" && dart build cli)
  [ -x "$daemon_bundle/bin/conduitd" ] || die "dart build cli left no $daemon_bundle/bin/conduitd"
}

# libconduit_whisper: whisper.cpp (pinned in the CMake file) and its C face,
# for conduitd's local speech recognition.
build_whisper() {
  local dir="$DESKTOP_DIR/target/whisper/macos_$ARCH"
  whisper_lib="$dir/libconduit_whisper.dylib"
  if [ "$skip_whisper" = 1 ]; then
    [ -f "$whisper_lib" ] || die "--skip-whisper: no $whisper_lib"
    # One built for a newer macOS than the bundle's (another checkout's, say)
    # would not load there, and verify refuses it: build it instead.
    local minos
    minos="$(vtool -show-build "$whisper_lib" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    if [ -n "$minos" ] && [ "$(printf '%s\n%s\n' "$minos" "$MACOS_MIN" | sort -V | tail -1)" != "$MACOS_MIN" ]; then
      die "--skip-whisper: $whisper_lib needs macOS $minos, the bundle $MACOS_MIN (build it: leave out --skip-whisper)"
    fi
    log "reusing $whisper_lib"
    return
  fi
  local cmake="${CMAKE:-cmake}"
  command -v "$cmake" >/dev/null || die "cmake is needed for the whisper library (set CMAKE=/path/to/cmake)"
  local source_args=()
  if [ -n "${WHISPER_SOURCE_DIR:-}" ]; then
    source_args=("-DFETCHCONTENT_SOURCE_DIR_WHISPER=$WHISPER_SOURCE_DIR")
  fi
  log "building libconduit_whisper (cmake)"
  "$cmake" -S "$REPO_ROOT/apps/daemon/native/whisper" -B "$dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    ${source_args[@]+"${source_args[@]}"} >/dev/null
  "$cmake" --build "$dir" --config Release --parallel >/dev/null
  [ -f "$whisper_lib" ] || die "the whisper build left no $whisper_lib"
}

# The desktop widget: ConduitWidget.appex and libconduit_widget.dylib.
build_widget() {
  widget_dir="$DESKTOP_DIR/target/widget/macos_$ARCH"
  log "building the desktop widget (app group $group)"
  "$PACKAGING_DIR/widget/build.sh" --out "$widget_dir" --bundle-id "$bundle_id" \
    --app-group "$group" --version "$version" --build "$build" --min "$MACOS_MIN"
}

# Thins a universal Mach-O to this build's architecture (Sparkle ships
# universal binaries; the app is Apple Silicon only).
thin() {
  local f="$1"
  if [ "$(lipo -archs "$f" 2>/dev/null | wc -w | tr -d ' ')" -gt 1 ]; then
    lipo "$f" -thin "$ARCH" -output "$f.thin"
    mv "$f.thin" "$f"
  fi
}

assemble() {
  move_aside "$out"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" \
    "$app/Contents/PlugIns"
  log "assembling $app"

  cp "$rust_binary" "$app/Contents/MacOS/Conduit"
  sed -e "s/@BUNDLE_ID@/$bundle_id/" \
    -e 's/@BUNDLE_NAME@/Conduit/' \
    -e 's/@EXECUTABLE@/Conduit/' \
    -e "s/@VERSION@/$version/" \
    -e "s/@BUILD@/$build/" \
    "$PACKAGING_DIR/Info.plist" >"$app/Contents/Info.plist"
  printf 'APPL????' >"$app/Contents/PkgInfo"

  # The Share extension (Contents/PlugIns/ConduitShare.appex) and the
  # Services menu titles in every language (share/build.sh).
  share_build "$app" "$bundle_id" Conduit "$version" "$build"
  services_strings "$app"
  # The privacy prompts (microphone, speech recognition, local network,
  # location) in every language.
  python3 "$PACKAGING_DIR/native_strings.py" infoplist "$REPO_ROOT/lib/l10n" \
    "$app/Contents/Info.plist" "$app/Contents/Resources" >&2

  # conduitd: the `dart build cli` bundle (bin/conduitd, lib/libsqlite3)
  # plus the whisper library next to libsqlite3, where conduitd looks.
  ditto "$daemon_bundle" "$app/Contents/Resources/conduitd"
  cp "$whisper_lib" "$app/Contents/Resources/conduitd/lib/"
  # The models.dev logo catalog direct models' logos are picked from;
  # conduitd looks for it beside its bin/ (the app has the SVGs built in).
  mkdir -p "$app/Contents/Resources/conduitd/model_logos"
  cp "$DESKTOP_DIR/../assets/model_logos/catalog.json" "$app/Contents/Resources/conduitd/model_logos/"

  # The icon: an asset catalog for macOS 26+ and the .icns for 14 and 15
  # (both from icon.sh; Info.plist names them).
  local icon
  for icon in AppIcon.icns Assets.car; do
    if [ -f "$PACKAGING_DIR/$icon" ]; then
      cp "$PACKAGING_DIR/$icon" "$app/Contents/Resources/$icon"
    else
      need "no packaging/macos/$icon: make it with icon.sh from AppIcon-master.png"
    fi
  done
  # The widget: its extension, and the library the app tells WidgetKit
  # through (dlopen'ed from Frameworks).
  ditto "$widget_dir/ConduitWidget.appex" "$app/Contents/PlugIns/ConduitWidget.appex"
  cp "$widget_dir/libconduit_widget.dylib" "$app/Contents/Frameworks/"

  # App Intents (Shortcuts, Siri, Spotlight): Resources/Metadata.appintents
  # and each locale's strings (intents.sh), for this bundle id.
  MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" "$PACKAGING_DIR/intents.sh" bundle "$app" \
    --bundle-id "$bundle_id"
  # The open-source notices, generated for what this bundle ships; fails
  # when a licence is missing (packaging/notices/README.md).
  "$DESKTOP_DIR/packaging/notices/notices.sh" --out "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"

  local plist="$app/Contents/Info.plist"
  # Where the widget's snapshot goes (shell/widget.rs reads it).
  set_plist "Add :ConduitAppGroup string $group" "$plist"

  # Sparkle, only with a public key: Sparkle refuses to start without one.
  if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    local sparkle
    sparkle="$(sparkle_dir)"
    ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
    local f
    while IFS= read -r f; do thin "$f"; done < <(macho_files "$app/Contents/Frameworks/Sparkle.framework")
    set_plist "Add :SUFeedURL string $feed_url" "$plist"
    set_plist "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$plist"
    # Check daily without the first-run "check automatically?" prompt;
    # the user can turn it off in Settings › About.
    set_plist "Add :SUEnableAutomaticChecks bool true" "$plist"
    set_plist "Add :SUScheduledCheckInterval integer 86400" "$plist"
    # Check the EdDSA signature before unpacking a download.
    set_plist "Add :SUVerifyUpdateBeforeExtraction bool true" "$plist"
    log "Sparkle $SPARKLE_VERSION embedded; feed $feed_url"
  else
    need "SPARKLE_PUBLIC_ED_KEY is not set: no Sparkle and no updates in this bundle"
  fi

  if [ ${#test_env[@]} -gt 0 ]; then
    warn "test bundle: LSEnvironment ${test_env[*]}"
    set_plist "Add :LSEnvironment dict" "$plist"
    local kv
    for kv in "${test_env[@]}"; do
      set_plist "Add :LSEnvironment:${kv%%=*} string ${kv#*=}" "$plist"
    done
  fi
  plutil -lint -s "$plist"
}

do_build() {
  build_rust
  build_daemon
  build_whisper
  build_widget
  assemble
}

# --- sign ------------------------------------------------------------------

do_sign() {
  [ -d "$app" ] || die "no $app (run build first)"
  local adhoc=0 ts=(--timestamp)
  if [ "$identity" = "-" ]; then
    adhoc=1
    ts=(--timestamp=none)
    need "no CONDUIT_SIGN_IDENTITY: ad-hoc signature (runs here only; Gatekeeper rejects it elsewhere)"
  elif [ "$SIGN_KIND" = development ]; then
    # As Xcode signs Debug builds: a development signature is never
    # notarized, so it needs no secure timestamp (nor Apple's server).
    ts=(--timestamp=none)
    warn "Apple Development signature (team $team): a local test build; Gatekeeper rejects it elsewhere"
  fi
  local ent="$out/entitlements"
  mkdir -p "$ent"
  cp "$PACKAGING_DIR/Conduit.entitlements" "$ent/Conduit.entitlements"
  cp "$PACKAGING_DIR/conduitd.entitlements" "$ent/conduitd.entitlements"
  cp "$PACKAGING_DIR/widget/ConduitWidget.entitlements" "$ent/ConduitWidget.entitlements"
  # The app and the widget share the snapshot's app group, named for the
  # team signing now (a release builds before its identity is imported).
  local appex="$app/Contents/PlugIns/ConduitWidget.appex" e p
  for p in "$app/Contents/Info.plist" "$appex/Contents/Info.plist"; do
    set_plist "Set :ConduitAppGroup $group" "$p" 2>/dev/null ||
      set_plist "Add :ConduitAppGroup string $group" "$p"
  done
  log "widget app group $group"
  for e in Conduit ConduitWidget; do
    set_plist "Add :com.apple.security.application-groups array" "$ent/$e.entitlements"
    set_plist "Add :com.apple.security.application-groups:0 string $group" "$ent/$e.entitlements"
  done
  embed_profiles "$app" "$bundle_id" "$team" "$ent"
  share_entitlements "$bundle_id" "$ent/Share.entitlements"
  if [ "$adhoc" = 1 ]; then
    # No team ID to match: let the ad-hoc binaries load their own libraries.
    set_plist "Add :com.apple.security.cs.disable-library-validation bool true" "$ent/Conduit.entitlements"
    set_plist "Add :com.apple.security.cs.disable-library-validation bool true" "$ent/conduitd.entitlements"
  fi
  sign() { codesign --force --sign "$identity" ${ts[@]+"${ts[@]}"} --options runtime "$@"; }

  # The team, never the identity: a name names its holder.
  log "signing ($([ "$adhoc" = 1 ] && echo ad-hoc || echo "team $team, $SIGN_KIND"))"
  local daemon="$app/Contents/Resources/conduitd" lib
  for lib in "$daemon"/lib/*.dylib; do sign "$lib"; done
  sign --identifier "$bundle_id.conduitd" --entitlements "$ent/conduitd.entitlements" "$daemon/bin/conduitd"

  local fw="$app/Contents/Frameworks/Sparkle.framework"
  if [ -d "$fw" ]; then
    # Sparkle's documented order for Developer ID apps.
    sign "$fw/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
    sign "$fw/Versions/B/Autoupdate"
    sign "$fw/Versions/B/Updater.app"
    sign "$fw"
  fi
  sign "$app/Contents/Frameworks/libconduit_widget.dylib"
  sign --entitlements "$ent/ConduitWidget.entitlements" "$appex"
  # The extension before the app that contains it; sandboxed, with the one
  # folder it hands shares through.
  sign --entitlements "$ent/Share.entitlements" "$app/Contents/PlugIns/$SHARE_APPEX"
  sign --entitlements "$ent/Conduit.entitlements" "$app"
  codesign --verify --deep --strict "$app"
}

# --- notarize --------------------------------------------------------------

notarize() {
  local file="$1" report="$2"
  log "notarizing $(basename "$file") (this waits for Apple)"
  xcrun notarytool submit "$file" ${notary_args[@]+"${notary_args[@]}"} --wait \
    --output-format json >"$report" || true
  local status id
  status="$(plutil -extract status raw -o - "$report" 2>/dev/null || echo unknown)"
  id="$(plutil -extract id raw -o - "$report" 2>/dev/null || echo "")"
  if [ "$status" != "Accepted" ]; then
    cat "$report" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" ${notary_args[@]+"${notary_args[@]}"} >&2 || true
    die "notarization of $(basename "$file") ended '$status'"
  fi
  log "notarized (submission $id)"
}

skip_notarization() {
  if [ "$identity" = "-" ]; then
    need "notarization skipped: an ad-hoc build cannot be notarized (set CONDUIT_SIGN_IDENTITY)"
    return 0
  fi
  if [ "$SIGN_KIND" = development ]; then
    warn "notarization skipped: an Apple Development build cannot be notarized (Developer ID only)"
    return 0
  fi
  if ! notary_credentials; then
    need "notarization skipped: set CONDUIT_NOTARY_PROFILE, or CONDUIT_NOTARY_KEY_FILE + CONDUIT_NOTARY_KEY_ID + CONDUIT_NOTARY_ISSUER"
    return 0
  fi
  return 1
}

do_notarize_app() {
  skip_notarization && return 0
  local zip="$out/Conduit-$version-notarize.zip"
  move_aside "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip" "$out/notary-app.json"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
}

# --- dmg -------------------------------------------------------------------

do_dmg() {
  [ -d "$app" ] || die "no $app (run build and sign first)"
  local stage="$out/dmg-root"
  move_aside "$stage"
  move_aside "$dmg"
  mkdir -p "$stage"
  ditto "$app" "$stage/Conduit.app"
  ln -s /Applications "$stage/Applications"
  log "creating $(basename "$dmg")"
  # hdiutil sometimes fails with "Resource busy" on a hosted CI runner (its
  # disk image service still holds a mount); a later try succeeds.
  local try
  for try in 1 2 3; do
    hdiutil create -quiet -volname "Conduit" -srcfolder "$stage" -fs HFS+ -format ULFO "$dmg" && break
    [ "$try" -lt 3 ] || die "hdiutil create failed 3 times"
    warn "hdiutil create failed (try $try of 3); trying again in 10 s"
    move_aside "$dmg"
    sleep 10
  done
  if [ "$identity" = "-" ]; then
    :
  elif [ "$SIGN_KIND" = development ]; then
    codesign --force --sign "$identity" --timestamp=none "$dmg"
  else
    codesign --force --sign "$identity" --timestamp "$dmg"
  fi
}

do_notarize_dmg() {
  skip_notarization && return 0
  notarize "$dmg" "$out/notary-dmg.json"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
}

# --- verify ----------------------------------------------------------------

do_verify() {
  [ -d "$app" ] || die "no $app"
  local plist="$app/Contents/Info.plist" failed=0
  fail() {
    printf '\033[31mFAIL\033[0m %s\n' "$*"
    failed=1
  }
  ok() { printf 'ok   %s\n' "$*"; }

  plutil -lint "$plist" >/dev/null && ok "plutil -lint Info.plist" || fail "plutil -lint Info.plist"
  local v
  v="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")"
  [ "$v" = "$MACOS_MIN" ] && ok "LSMinimumSystemVersion $v" || fail "LSMinimumSystemVersion $v (want $MACOS_MIN)"
  v="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$plist")"
  [ "$v" = "conduit" ] && ok "URL scheme conduit://" || fail "URL scheme '$v'"
  v="$(plutil -extract CFBundleDocumentTypes raw -o - "$plist")"
  [ "$v" = "2" ] && ok "CFBundleDocumentTypes: 2 (documents, images)" || fail "CFBundleDocumentTypes: $v"
  if share_verify "$app" "$(plutil -extract CFBundleIdentifier raw -o - "$plist")"; then
    ok "Share extension: embedded, sandboxed, signed; Services: 2 items, 14 languages"
  else
    failed=1
  fi
  if v="$(python3 "$PACKAGING_DIR/native_strings.py" infoplist --verify "$REPO_ROOT/lib/l10n" "$app" 2>&1)"; then
    ok "privacy prompts: ${v#native_strings: ok: }"
  else
    fail "privacy prompts: $v"
  fi
  if codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null |
    grep -q 'com.apple.security.personal-information.location'; then
    ok "Location entitlement (hardened runtime)"
  else
    fail "no location entitlement: CoreLocation is refused under the hardened runtime"
  fi
  if "$PACKAGING_DIR/intents.sh" verify "$app" >"$out/intents-verify.txt" 2>&1; then
    ok "App Intents: $(sed -n 's/^native_strings: ok: //p' "$out/intents-verify.txt")"
  else
    fail "App Intents (intents.sh verify)"
    sed 's/^/     /' "$out/intents-verify.txt"
  fi
  if [ -s "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" ]; then
    ok "THIRD_PARTY_NOTICES.md: $(grep -c '' "$app/Contents/Resources/THIRD_PARTY_NOTICES.md") lines"
  else
    fail "no THIRD_PARTY_NOTICES.md in Resources"
  fi
  # No test harness in the binary (the `harness` cargo feature), and its
  # flags refused.
  if "$PACKAGING_DIR/harness_check.sh" "$app" "$out/harness-check" >"$out/harness-check.txt" 2>&1; then
    grep -E '^(ok|note)' "$out/harness-check.txt" | sed 's/^ok   /ok   release build: /'
  else
    fail "the test harness is in the release build (harness_check.sh)"
    sed 's/^/     /' "$out/harness-check.txt"
  fi
  v="$(plutil -extract CFBundleIconFile raw -o - "$plist")"
  if [ -f "$app/Contents/Resources/$v.icns" ]; then ok "icon $v.icns (macOS 14/15)"; else
    if [ "$release" = 1 ]; then fail "no $v.icns"; else printf 'warn no %s.icns in Resources\n' "$v"; fi
  fi
  v="$(plutil -extract CFBundleIconName raw -o - "$plist")"
  local car_info=""
  if [ -f "$app/Contents/Resources/Assets.car" ]; then
    car_info="$(xcrun assetutil --info "$app/Contents/Resources/Assets.car" 2>/dev/null || true)"
  fi
  if grep -Fq "\"Name\" : \"$v\"" <<<"$car_info"; then
    ok "icon $v in Assets.car (macOS 26+)"
  else
    if [ "$release" = 1 ]; then fail "no $v in Resources/Assets.car"; else printf 'warn no %s in Assets.car\n' "$v"; fi
  fi
  printf '     version %s (%s), bundle id %s\n' \
    "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" \
    "$(plutil -extract CFBundleVersion raw -o - "$plist")" \
    "$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
  if plutil -extract SUPublicEDKey raw -o - "$plist" >/dev/null 2>&1; then
    printf '     Sparkle feed %s\n' "$(plutil -extract SUFeedURL raw -o - "$plist")"
  else
    printf '     no Sparkle (no updater)\n'
  fi

  local f archs minos bad_arch=0 bad_os=0 count=0
  while IFS= read -r f; do
    count=$((count + 1))
    archs="$(lipo -archs "$f")"
    [ "$archs" = "$ARCH" ] || {
      fail "$(basename "$f") is $archs"
      bad_arch=1
    }
    minos="$(vtool -show-build "$f" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    if [ -n "$minos" ] && [ "$(printf '%s\n%s\n' "$minos" "$MACOS_MIN" | sort -V | tail -1)" != "$MACOS_MIN" ]; then
      fail "$(basename "$f") needs macOS $minos"
      bad_os=1
    fi
  done < <(macho_files "$app")
  [ "$bad_arch" = 0 ] && ok "lipo: all $count Mach-O files are $ARCH only"
  [ "$bad_os" = 0 ] && ok "minimum OS of every Mach-O <= $MACOS_MIN"
  lipo -info "$app/Contents/MacOS/Conduit"

  # conduitd's libraries may only link the system and themselves.
  local dep
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/* | /System/* | @rpath/* | @loader_path/* | @executable_path/*) ;;
      *) fail "conduitd links $dep" ;;
    esac
  done < <(for f in "$app/Contents/Resources/conduitd/bin/conduitd" "$app"/Contents/Resources/conduitd/lib/*.dylib; do
    otool -L "$f" | tail -n +2 | awk '{print $1}'
  done)

  # The desktop widget.
  local appex="$app/Contents/PlugIns/ConduitWidget.appex" wplist ents
  wplist="$appex/Contents/Info.plist"
  if [ -f "$wplist" ]; then
    v="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$wplist")"
    [ "$v" = "com.apple.widgetkit-extension" ] && ok "widget: a WidgetKit extension" || fail "widget: extension point '$v'"
    v="$(plutil -extract CFBundleIdentifier raw -o - "$wplist")"
    [ "$v" = "$(plutil -extract CFBundleIdentifier raw -o - "$plist").widget" ] &&
      ok "widget: bundle id $v" || fail "widget: bundle id $v"
    v="$(plutil -extract ConduitAppGroup raw -o - "$wplist")"
    [ "$v" = "$(plutil -extract ConduitAppGroup raw -o - "$plist" 2>/dev/null)" ] &&
      ok "widget: app group $v (app and widget)" || fail "widget: app group $v differs from the app's"
    ents="$(codesign -d --entitlements - --xml "$appex" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)"
    grep -q '"com.apple.security.app-sandbox":true' <<<"$ents" && grep -Fq "\"$v\"" <<<"$ents" &&
      ok "widget: sandboxed, entitled to the group" || fail "widget entitlements: $ents"
    ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)"
    grep -Fq "\"$v\"" <<<"$ents" && ok "app: entitled to the group" || fail "app entitlements lack $v"
    nm -gU "$app/Contents/Frameworks/libconduit_widget.dylib" 2>/dev/null |
      grep -q '_conduit_widget_reload_all' && ok "widget: libconduit_widget.dylib exports its functions" ||
      fail "widget: libconduit_widget.dylib"
    if [ -f "$app/Contents/embedded.provisionprofile" ] && [ -f "$appex/Contents/embedded.provisionprofile" ]; then
      ok "provisioning profiles embedded (the widget can be listed)"
    else
      printf 'note no provisioning profiles: macOS will not list the widget in its gallery\n'
    fi
  else
    fail "no PlugIns/ConduitWidget.appex"
  fi

  if codesign --verify --deep --strict --verbose=2 "$app" 2>"$out/codesign-verify.txt"; then
    ok "codesign --verify --deep --strict"
  else
    fail "codesign --verify --deep --strict"
  fi
  sed 's/^/     /' "$out/codesign-verify.txt"
  codesign -dv "$app" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier|Runtime)' |
    redact_authorities | sed 's/^/     /'
  # Every nested binary under the app's own team (library validation and
  # App Intents go by it); ad-hoc: none anywhere.
  local signature app_team app_kind others
  signature="$(signature_of "$app")"
  app_team="${signature%% *}"
  app_kind="${signature#* }"
  macho_teams "$app" >"$out/teams.txt"
  others="$(awk -v t="$app_team" '$1 != t' "$out/teams.txt")"
  if [ -n "$others" ]; then
    fail "Mach-O files signed for another team than the app's ($app_team):"
    sed 's/^/     /' <<<"$others"
  elif [ "$app_team" = "-" ]; then
    ok "no TeamIdentifier on any of the $(wc -l <"$out/teams.txt" | tr -d ' ') Mach-O files ($app_kind)"
  else
    ok "TeamIdentifier $app_team on all $(wc -l <"$out/teams.txt" | tr -d ' ') Mach-O files ($app_kind)"
  fi
  codesign -d --entitlements - --xml "$app/Contents/Resources/conduitd/bin/conduitd" 2>/dev/null |
    plutil -convert json -o - - 2>/dev/null | sed 's/^/     conduitd entitlements: /'
  echo

  local spctl_out
  spctl_out="$(spctl -a -vv -t exec "$app" 2>&1)" && ok "spctl (Gatekeeper) accepts the app" || {
    if [ "$app_kind" = adhoc ] && [ "$release" = 0 ]; then
      printf 'note spctl rejects the ad-hoc app, as expected:\n'
    elif [ "$app_kind" = development ] && [ "$release" = 0 ]; then
      printf 'note spctl rejects the Apple Development app (not notarized), as expected:\n'
    else
      fail "spctl rejects the app"
    fi
  }
  printf '%s\n' "$spctl_out" | redact_authorities | sed -E 's/^(origin=[^:]*): .*/\1: …/' | sed 's/^/     /'
  if [ -f "$dmg" ]; then
    # A release's DMG is what users download: Gatekeeper must accept it.
    spctl_out="$(spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1)" &&
      ok "spctl accepts the DMG" || {
      if [ "$release" = 1 ]; then
        fail "spctl rejects the DMG"
      else
        printf 'note spctl on the DMG:\n'
      fi
    }
    printf '%s\n' "$spctl_out" | redact_authorities | sed -E 's/^(origin=[^:]*): .*/\1: …/' | sed 's/^/     /'
  fi

  printf '\nsizes:\n'
  du -sh "$app" | sed 's/^/     /'
  du -sh "$app/Contents/MacOS/Conduit" "$app/Contents/Resources/conduitd" | sed 's/^/     /'
  [ -d "$app/Contents/Frameworks/Sparkle.framework" ] &&
    du -sh "$app/Contents/Frameworks/Sparkle.framework" | sed 's/^/     /'
  [ -f "$dmg" ] && du -h "$dmg" | sed 's/^/     /'
  [ "$failed" = 0 ] || die "verification failed"
}

case "$command" in
  build) do_build ;;
  sign) do_sign ;;
  notarize-app) do_notarize_app ;;
  dmg) do_dmg ;;
  notarize-dmg) do_notarize_dmg ;;
  verify) do_verify ;;
  all)
    do_build
    do_sign
    do_notarize_app
    do_dmg
    do_notarize_dmg
    do_verify
    ;;
esac
log "done: $out"
