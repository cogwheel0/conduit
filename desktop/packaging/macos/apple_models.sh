#!/bin/bash
# Apple's on-device Foundation Models for the Mac app: the Swift engine in
# crates/app/apple, built outside Xcode.
#
#   apple_models.sh compile OUT_DIR
#       Swift -> OUT_DIR/libconduit_apple_models.a. crates/app/build.rs runs
#       this on macOS, and the Rust binary links the library
#       (src/shell/apple_models.rs calls it). Also writes
#       OUT_DIR/sdk-gaps.txt: what `sdk-gaps` prints, which build.rs turns
#       into cargo warnings.
#   apple_models.sh sdk-gaps [--github]
#       What a build with the active SDK leaves out of the engine, one line
#       each; nothing with macOS 27's SDK (Xcode 27 or later). macOS 26's
#       SDK (Xcode 26) builds the engine without the parts that need 27's
#       (the Swift file's `#if canImport(FoundationModels, _version: 2.0)`,
#       the condition tested here). With --github (the workflows), as one
#       `::warning::` annotation and in the job summary instead.
#
# FoundationModels exists from macOS 26, and the app runs from MACOS_MIN:
# the compiler weak-imports every symbol newer than the target, and its
# automatic `-framework FoundationModels` is dropped here so build.rs can
# link the framework weakly (`-weak_framework`). On an older macOS the
# framework is simply absent and the engine says the model is unsupported.
#
# Private Cloud Compute is never compiled in: FoundationModels traps on the
# first request of a binary without its entitlement, and this build has
# none (see the Swift file's header).
#
# Environment: MACOSX_DEPLOYMENT_TARGET (default MACOS_MIN from
# release.env); CONDUIT_APPLE_ARCH (default ARCH).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

APPLE_DIR="$DESKTOP_DIR/crates/app/apple"
MODULE=ConduitAppleModels
min="${MACOSX_DEPLOYMENT_TARGET:-$MACOS_MIN}"
arch="${CONDUIT_APPLE_ARCH:-$ARCH}"
triple="$arch-apple-macos$min"

sdk_path() { xcrun --sdk macosx --show-sdk-path; }

# Whether the active SDK's FoundationModels is macOS 27's (module version
# 2), tested exactly as ConduitAppleModels.swift tests it.
has_macos27_models() {
  printf '#if !canImport(FoundationModels, _version: 2.0)\n#error("older SDK")\n#endif\n' |
    xcrun --sdk macosx swiftc -typecheck -target "$triple" -sdk "$(sdk_path)" - >/dev/null 2>&1
}

do_sdk_gaps() {
  has_macos27_models && return 0
  local sdk why
  sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo '?')"
  why="built with the macOS $sdk SDK; macOS 27's comes with Xcode 27 or later"
  printf '%s\n' \
    "Apple On-Device replies on macOS 27 report no token usage ($why)" \
    "Apple On-Device failures in macOS 27's error types (context size, rate limit, refusal, timeout, guardrail, unsupported content, model not ready, busy, decoding) read as a generic failure ($why)"
}

# The gaps on a GitHub Actions run: one warning annotation (lines joined
# as the workflow command escapes a newline) and a section of the job
# summary. Says so in the log when there are none.
annotate_sdk_gaps() {
  local gaps xcode
  gaps="$(do_sdk_gaps)"
  # awk reads to the end: `head -1` can close the pipe before xcodebuild's
  # second line, and xcodebuild aborts on the broken pipe (exit 134 under
  # pipefail).
  xcode="$(xcodebuild -version 2>/dev/null | awk 'NR == 1' || true)"
  if [ -z "$gaps" ]; then
    printf '%s, macOS %s SDK: the Apple models engine is complete\n' \
      "${xcode:-Xcode}" "$(xcrun --sdk macosx --show-sdk-version)"
    return 0
  fi
  local title="${xcode:-This Xcode} builds without macOS 27 features"
  title="${title//%/%25}" title="${title//:/%3A}" title="${title//,/%2C}"
  printf '::warning title=%s::%s\n' "$title" \
    "$(awk '{gsub(/%/, "%25"); printf "%s- %s", (NR > 1 ? "%0A" : ""), $0}' <<<"$gaps")"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { printf '### %s builds without macOS 27 features\n\n' "${xcode:-This Xcode}"
      sed 's/^/- /' <<<"$gaps"; } >>"$GITHUB_STEP_SUMMARY"
  fi
}

do_compile() {
  local out="$1"
  mkdir -p "$out"
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$APPLE_DIR" -maxdepth 1 -name '*.swift' | sort)
  [ "${#files[@]}" -gt 0 ] || die "no Swift sources in $APPLE_DIR"
  xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-name "$MODULE" -target "$triple" \
    -sdk "$(sdk_path)" \
    -O -wmo -c "${files[@]}" \
    -Xfrontend -disable-autolink-framework -Xfrontend FoundationModels \
    -o "$out/$MODULE.o"
  libtool -static -no_warning_for_no_symbols \
    -o "$out/libconduit_apple_models.a.new" "$out/$MODULE.o"
  mv -f "$out/libconduit_apple_models.a.new" "$out/libconduit_apple_models.a"
  do_sdk_gaps >"$out/sdk-gaps.txt"
}

case "${1:-}" in
  compile)
    [ -n "${2:-}" ] || die "usage: apple_models.sh compile OUT_DIR | sdk-gaps"
    do_compile "$2"
    ;;
  sdk-gaps)
    case "${2:-}" in
      "") do_sdk_gaps ;;
      --github) annotate_sdk_gaps ;;
      *) die "usage: apple_models.sh sdk-gaps [--github]" ;;
    esac
    ;;
  *)
    die "usage: apple_models.sh compile OUT_DIR | sdk-gaps [--github]"
    ;;
esac
