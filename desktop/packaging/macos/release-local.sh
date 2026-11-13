#!/bin/bash
# The release path on this Mac with a Developer ID certificate, on a test
# bundle id: build, sign inside out, notarize and staple the app, make,
# sign, notarize and staple the DMG, then check what Gatekeeper will see.
# One command for the first run with a new certificate or new notarization
# credentials, before any tag is pushed (docs/RELEASING-DESKTOP.md).
#
#   desktop/packaging/macos/release-local.sh --identity SHA1 --keychain-profile NAME [options]
#
#   --identity SHA1          the Developer ID Application identity, by its
#                            SHA-1 (security find-identity -v -p codesigning)
#   --keychain-profile NAME  a `xcrun notarytool store-credentials NAME`
#                            profile in the login keychain
#   --version V              default 0.0.1
#   --bundle-id ID           default app.cogwheel.conduit.desktop.rehearsal
#                            (the release id is refused: a local build never
#                            carries it)
#   --out DIR                default desktop/target/macos/rehearsal-<V>
#   --skip-rust, --skip-daemon, --skip-whisper
#                            passed to bundle.sh build
#   --launch                 also smoke.sh --launch (opens the app briefly on
#                            a throwaway profile)
#
# The Sparkle key: SPARKLE_PUBLIC_ED_KEY when set, else a throwaway key
# made for this run beside <out> (never the keychain, never the release
# key: this build is not for distribution). The app's data stays in
# <out>.profile (LSEnvironment), apart from the real app's.
#
# Prints certificate kinds and team IDs, never certificate holder names.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

identity=""
profile=""
version=0.0.1
bundle_id=app.cogwheel.conduit.desktop.rehearsal
out=""
launch=0
build_flags=()
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) identity="$2"; shift ;;
    --keychain-profile) profile="$2"; shift ;;
    --version) version="$2"; shift ;;
    --bundle-id) bundle_id="$2"; shift ;;
    --out) out="$2"; shift ;;
    --skip-rust | --skip-daemon | --skip-whisper) build_flags+=("$1") ;;
    --launch) launch=1 ;;
    -h | --help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[ -n "$identity" ] || die "--identity SHA1 is required (security find-identity -v -p codesigning)"
[ -n "$profile" ] || die "--keychain-profile NAME is required (xcrun notarytool store-credentials NAME …)"
[ "$bundle_id" != "$BUNDLE_ID_DEFAULT" ] || die "a local build never carries $BUNDLE_ID_DEFAULT; pass a test id"
check_version "$version"
out="${out:-$DESKTOP_DIR/target/macos/rehearsal-$version}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
app="$out/Conduit.app"
dmg="$out/Conduit-$version.dmg"

log "1/6 the identity"
signing_identity "$identity"
[ "$SIGN_KIND" = distribution ] || die "the identity is $SIGN_KIND, not Developer ID Application"
probe="$(mktemp -d "${TMPDIR:-/tmp}/conduit-identity.XXXXXX")"
cp /usr/bin/true "$probe/probe"
codesign --force --sign "$identity" --timestamp=none "$probe/probe" >/dev/null 2>&1
leaf="$(codesign -dv --verbose=2 "$probe/probe" 2>&1 | awk 'sub(/^Authority=/, "") && !n++')"
case "$leaf" in
  "Developer ID Application:"*) ;;
  *) die "the identity's certificate is not a Developer ID Application one ($(redact_authorities <<<"Authority=$leaf"))" ;;
esac
log "Developer ID Application, team $SIGN_TEAM"

log "2/6 the notarization profile"
xcrun notarytool history --keychain-profile "$profile" --output-format json >"$probe/history.json" 2>"$probe/history.err" ||
  {
    sed 's/^/    /' "$probe/history.err" >&2
    die "notarytool could not sign in with keychain profile '$profile'"
  }
log "notarytool signs in with profile '$profile'"

if [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  keydir="$out.sparkle-throwaway"
  mkdir -p "$keydir"
  (umask 077 && openssl genpkey -algorithm ed25519 -outform DER -out "$keydir/key.der")
  SPARKLE_PUBLIC_ED_KEY="$(openssl pkey -inform DER -in "$keydir/key.der" -pubout -outform DER | tail -c 32 | base64)"
  log "a throwaway Sparkle key for this build: $keydir"
fi
export SPARKLE_PUBLIC_ED_KEY
# Never the real feed: a local rehearsal must not read the release appcast.
export CONDUIT_APPCAST_URL="${CONDUIT_APPCAST_URL:-http://127.0.0.1:9/appcast.xml}"

log "3/6 bundle.sh all --rehearsal (build, sign, notarize and staple the app, DMG, notarize and staple it, verify)"
CONDUIT_SIGN_IDENTITY="$identity" CONDUIT_NOTARY_PROFILE="$profile" \
  "$here/bundle.sh" all --rehearsal --version "$version" --bundle-id "$bundle_id" --out "$out" \
  --test-env CONDUIT_FLAVOR=dev --test-env "CONDUIT_USER_DATA=$out.profile/user-data" \
  --test-env "CONDUIT_LOGS=$out.profile/logs" ${build_flags[@]+"${build_flags[@]}"}

log "4/6 Gatekeeper (spctl -a -vv)"
spctl -a -vv -t exec "$app" 2>&1 | redact_authorities | sed -E 's/^(origin=[^:]*): .*/\1: …/'
spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 | redact_authorities |
  sed -E 's/^(origin=[^:]*): .*/\1: …/'
spctl -a -t exec "$app" 2>/dev/null || die "Gatekeeper rejects the app"
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || die "Gatekeeper rejects the DMG"
spctl -a -vv -t exec "$app" 2>&1 | grep -q 'source=Notarized Developer ID' ||
  die "Gatekeeper accepts the app, but not as Notarized Developer ID"

log "5/6 codesign --verify --deep --strict, stapled tickets"
codesign --verify --deep --strict --verbose=2 "$app"
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"

if [ "$launch" = 1 ]; then
  log "6/6 smoke.sh --launch"
  "$here/smoke.sh" "$app" --launch
else
  log "6/6 smoke.sh"
  "$here/smoke.sh" "$app"
fi
log "release path verified with Developer ID (team $SIGN_TEAM): $out"
