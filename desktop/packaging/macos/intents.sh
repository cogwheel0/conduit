#!/bin/bash
# Conduit's App Intents (Shortcuts, Siri, Spotlight): the Swift layer in
# crates/app/intents, built outside Xcode.
#
#   intents.sh compile OUT_DIR
#       Swift -> OUT_DIR/libconduit_intents.a, and the compiler's constant
#       values (OUT_DIR/ConduitIntents.swiftconstvalues) that Apple's
#       metadata extractor reads. crates/app/build.rs runs this on macOS,
#       and the Rust binary links the library.
#   intents.sh bundle APP [--bundle-id ID]
#       Into APP/Contents/Resources: Metadata.appintents (Apple's
#       `appintentsmetadataprocessor`, as Xcode's "Extract App Intents
#       Metadata" step runs it), and each locale's Localizable.strings and
#       AppShortcuts.strings made from lib/l10n/desktop (native_strings.py
#       intents, which refuses a string with no desktop ARB key). bundle.sh and
#       crates/app/run.sh run this before signing.
#   intents.sh verify APP
#       The bundle's metadata names the eight actions, the chat entity and
#       its query, and the App Shortcuts; every locale has its strings.
#
# Environment: MACOSX_DEPLOYMENT_TARGET (default MACOS_MIN from
# release.env); CONDUIT_INTENTS_ARCH (default ARCH).
#
# The system lists the actions once Launch Services has launched the bundle
# (an ad-hoc signature is enough for that); running them needs a signature
# with a team ID (Apple Development or Developer ID): linkd refuses the
# app's runtime registration otherwise. See docs/BUILDING-DESKTOP.md.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

INTENTS_DIR="$DESKTOP_DIR/crates/app/intents"
MODULE=ConduitIntents
min="${MACOSX_DEPLOYMENT_TARGET:-$MACOS_MIN}"
arch="${CONDUIT_INTENTS_ARCH:-$ARCH}"
triple="$arch-apple-macos$min"

# The protocols whose conformances the compiler records constant values
# for: Xcode's default list (SWIFT_EMIT_CONST_VALUE_PROTOCOLS).
PROTOCOLS='["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]'

sources() {
  find "$INTENTS_DIR" -maxdepth 1 -name '*.swift' | sort
}

sdk_path() { xcrun --sdk macosx --show-sdk-path; }

toolchain_dir() {
  local swiftc
  swiftc="$(xcrun --sdk macosx --find swiftc)"
  (cd "$(dirname "$swiftc")/../.." && pwd)
}

do_compile() {
  local out="$1"
  mkdir -p "$out"
  printf '%s\n' "$PROTOCOLS" >"$out/protocols.json"
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(sources)
  # Absolute source paths: the constant values record them, and the
  # metadata extractor matches them against --source-file-list.
  xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-name "$MODULE" -target "$triple" -sdk "$(sdk_path)" \
    -O -wmo -c "${files[@]}" \
    -import-objc-header "$INTENTS_DIR/ConduitIntentsBridge.h" \
    -o "$out/$MODULE.o" \
    -emit-const-values-path "$out/$MODULE.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$out/protocols.json"
  libtool -static -no_warning_for_no_symbols -o "$out/libconduit_intents.a.new" "$out/$MODULE.o"
  mv -f "$out/libconduit_intents.a.new" "$out/libconduit_intents.a"
}

xcode_build_version() {
  plutil -extract ProductBuildVersion raw -o - "$(xcode-select -p)/../version.plist" 2>/dev/null ||
    echo unknown
}

do_bundle() {
  local app="$1" bundle_id="$2"
  [ -d "$app/Contents" ] || die "no app at $app"
  local res="$app/Contents/Resources"
  mkdir -p "$res"
  # Reused (and overwritten) by every bundle: target/ is ignored.
  local work="$DESKTOP_DIR/target/intents/bundle-$arch"
  do_compile "$work"
  sources >"$work/sources.txt"
  printf '%s\n' "$work/$MODULE.swiftconstvalues" >"$work/constvalues.txt"
  local binary
  binary="$app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")"
  local binary_args=()
  [ -f "$binary" ] && binary_args=(--binary-file "$binary")
  log "App Intents metadata ($bundle_id)"
  xcrun appintentsmetadataprocessor \
    --output "$res" \
    --toolchain-dir "$(toolchain_dir)" \
    --module-name "$MODULE" \
    --sdk-root "$(sdk_path)" \
    --xcode-version "$(xcode_build_version)" \
    --platform-family macOS \
    --deployment-target "$min" \
    --bundle-identifier "$bundle_id" \
    --target-triple "$triple" \
    ${binary_args[@]+"${binary_args[@]}"} \
    --source-file-list "$work/sources.txt" \
    --swift-const-vals-list "$work/constvalues.txt" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --no-app-shortcuts-localization 2>"$work/metadata.log" ||
    {
      cat "$work/metadata.log" >&2
      die "App Intents metadata extraction failed"
    }
  [ -f "$res/Metadata.appintents/extract.actionsdata" ] ||
    die "the metadata extractor wrote no Metadata.appintents"
  python3 "$here/native_strings.py" intents "$res" "$REPO_ROOT/lib/l10n" "$INTENTS_DIR"
}

do_verify() {
  local app="$1"
  python3 "$here/native_strings.py" intents --verify "$app/Contents/Resources" \
    "$REPO_ROOT/lib/l10n" "$INTENTS_DIR"
}

command="${1:-}"
shift || true
case "$command" in
  compile)
    [ $# -eq 1 ] || die "usage: intents.sh compile OUT_DIR"
    do_compile "$1"
    ;;
  bundle)
    [ $# -ge 1 ] || die "usage: intents.sh bundle APP [--bundle-id ID]"
    app="$1"
    shift
    bundle_id=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --bundle-id) bundle_id="$2"; shift ;;
        *) die "unknown argument: $1" ;;
      esac
      shift
    done
    [ -n "$bundle_id" ] ||
      bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
    do_bundle "$app" "$bundle_id"
    ;;
  verify)
    [ $# -eq 1 ] || die "usage: intents.sh verify APP"
    do_verify "$1"
    ;;
  -h | --help | "") sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $command (see --help)" ;;
esac
