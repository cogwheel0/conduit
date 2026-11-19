#!/bin/bash
# Adds a release to Sparkle's appcast with generate_appcast, signing the
# update and the feed with the private EdDSA key from the environment.
#
#   desktop/packaging/macos/appcast.sh --dmg PATH --version V [options]
#
# The current appcast is fetched from the feed URL (release.env, or
# CONDUIT_APPCAST_URL), the new DMG is added next to it, and
# generate_appcast writes the result to <work>/appcast.xml, keeping the
# items already there. Conduit Desktop has one channel, the default
# (stable) one: a -beta.N version is refused. Nothing is uploaded here; see
# publish-appcast.sh.
#
# Before it returns, the result is checked:
#   - check_appcast.py: the feed keeps every earlier item, and the new one
#     is the DMG's length, at its URL, signed and the newest build;
#   - the private key's public half is SPARKLE_PUBLIC_ED_KEY (when set) and
#     the SUPublicEDKey of the app in the DMG, so no release can ship an
#     update its installed copies would refuse;
#   - the new item is version V with build `build_number V`, at the
#     download URL prefix, with an EdDSA signature that sign_update
#     verifies against the DMG, sparkle:minimumSystemVersion MACOS_MIN and
#     sparkle:hardwareRequirements arm64 (from the app's Info.plist and
#     architecture);
#   - the feed itself carries a valid signature (the app requires one:
#     SURequireSignedFeed), and no item is on a channel.
#
# Options:
#   --dmg PATH              the notarized DMG (the update archive)
#   --version V             its version (1.2.0)
#   --work DIR              working folder (default: next to the DMG, appcast/)
#   --download-url-prefix U where the DMG will be downloaded from (default:
#                           the version's GitHub release,
#                           https://github.com/<repo>/releases/download/desktop-v<V>/)
#   --existing FILE         start from this appcast instead of fetching one
#   --fresh                 start a new appcast (first release only)
#   --allow-new             start a new appcast when the feed answers 404
#                           (CI: the first release); any other failure to
#                           fetch it still stops
#
# Environment:
#   SPARKLE_ED_PRIVATE_KEY  the private EdDSA key (base64, as Sparkle's
#                           generate_keys -x exports it). Required; it goes
#                           to Sparkle's tools on stdin, never in argv.
#   SPARKLE_PUBLIC_ED_KEY   the public key the release was built with
#                           (optional here; checked against the private one)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

dmg=""
version=""
work=""
prefix=""
existing=""
fresh=0
allow_new=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dmg) dmg="$2"; shift ;;
    --version) version="$2"; shift ;;
    --work) work="$2"; shift ;;
    --download-url-prefix) prefix="$2"; shift ;;
    --existing) existing="$2"; shift ;;
    --fresh) fresh=1 ;;
    --allow-new) allow_new=1 ;;
    -h | --help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[ -f "$dmg" ] || die "--dmg: no such file '$dmg'"
check_version "$version"
refuse_beta_release "$version"
[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || die "SPARKLE_ED_PRIVATE_KEY is not set"
work="${work:-$(cd "$(dirname "$dmg")" && pwd)/appcast}"
prefix="${prefix:-https://github.com/$RELEASE_REPO/releases/download/desktop-v$version/}"
case "$prefix" in */) ;; *) prefix="$prefix/" ;; esac
feed="$(appcast_url)"
sparkle="$(sparkle_dir)"

# The key pair: the private key must belong to the public key the app was
# built with, or every installed copy refuses the update.
public="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | sparkle_public_key)"
[ -n "$public" ] || die "SPARKLE_ED_PRIVATE_KEY is not a Sparkle EdDSA private key (base64)"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ] && [ "$public" != "$SPARKLE_PUBLIC_ED_KEY" ]; then
  die "SPARKLE_ED_PRIVATE_KEY does not belong to SPARKLE_PUBLIC_ED_KEY"
fi
mount="$(mktemp -d "${TMPDIR:-/tmp}/conduit-appcast-dmg.XXXXXX")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
app_plist="$mount/Conduit.app/Contents/Info.plist"
app_key="$(plutil -extract SUPublicEDKey raw -o - "$app_plist" 2>/dev/null || true)"
app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist" 2>/dev/null || true)"
app_min="$(plutil -extract LSMinimumSystemVersion raw -o - "$app_plist" 2>/dev/null || true)"
hdiutil detach -quiet "$mount"
[ -n "$app_key" ] || die "the app in $(basename "$dmg") has no SUPublicEDKey (built without SPARKLE_PUBLIC_ED_KEY)"
[ "$app_key" = "$public" ] || die "the app in $(basename "$dmg") was built for another Sparkle key than SPARKLE_ED_PRIVATE_KEY's"
[ "$app_version" = "$version" ] || die "the app in $(basename "$dmg") is $app_version, not $version"
[ "$app_min" = "$MACOS_MIN" ] || die "the app in $(basename "$dmg") needs macOS $app_min, not $MACOS_MIN"
log "Sparkle key pair matches the app in $(basename "$dmg")"

move_aside "$work"
mkdir -p "$work"
if [ -n "$existing" ]; then
  cp "$existing" "$work/appcast.xml"
  log "starting from $existing"
elif [ "$fresh" = 1 ]; then
  log "starting a new appcast"
else
  # A missing feed (404) is the first release; any other failure stops
  # here, so a network error never replaces the feed with a new one.
  code="$(curl -sSL --retry 3 -o "$work/appcast.xml" -w '%{http_code}' "$feed" || true)"
  case "$code" in
    200) log "fetched the current appcast from $feed" ;;
    404)
      mv "$work/appcast.xml" "$work/not-found.html" 2>/dev/null || true
      [ "$allow_new" = 1 ] || die "no appcast at $feed (HTTP 404). For the very first release pass --fresh."
      log "no appcast at $feed yet (HTTP 404): starting a new one"
      ;;
    *) die "could not fetch $feed (HTTP $code)" ;;
  esac
fi

# The feed as it was, to check the new one against (never drop an item).
old=()
if [ -f "$work/appcast.xml" ]; then
  cp "$work/appcast.xml" "$work/previous-appcast.xml"
  old=(--old "$work/previous-appcast.xml")
fi
cp "$dmg" "$work/"
# -o: generate_appcast reads and writes this file, whatever SUFeedURL names.
args=(-o "$work/appcast.xml" --ed-key-file - --download-url-prefix "$prefix"
  --link "https://github.com/$RELEASE_REPO/releases"
  --full-release-notes-url "https://github.com/$RELEASE_REPO/releases/tag/desktop-v$version"
  --maximum-versions 0)
log "generate_appcast: $(basename "$dmg")"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sparkle/bin/generate_appcast" "${args[@]}" "$work"
xmllint --noout "$work/appcast.xml"

# Nothing is published unless the feed keeps every earlier item and the new
# one is signed, the DMG's length, at its URL and the newest build.
build="$(build_number "$version")"
python3 -I "$here/check_appcast.py" --new "$work/appcast.xml" ${old[@]+"${old[@]}"} --dmg "$dmg" \
  --version "$version" --build "$build" --url "$prefix$(basename "$dmg")" ||
  die "the new appcast is not safe to publish"
# The new item, as Sparkle will read it.
signature="$(python3 -I - "$work/appcast.xml" "$version" "$(build_number "$version")" \
  "$prefix$(basename "$dmg")" "$MACOS_MIN" <<'EOF'
import sys, xml.etree.ElementTree as ET
path, version, build, url, min_os = sys.argv[1:]
S = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ns = {"sparkle": S}
items = list(ET.parse(path).getroot().iter("item"))
def get(item, tag):
    return (item.findtext(f"sparkle:{tag}", namespaces=ns) or "").strip()
problems = []
for item in items:
    if get(item, "channel"):
        problems.append(f"item {get(item, 'shortVersionString')} is on channel '{get(item, 'channel')}'")
new = [i for i in items if get(i, "version") == build]
if len(new) != 1:
    sys.exit(f"appcast: expected one item with sparkle:version {build}, found {len(new)}")
item = new[0]
enc = item.find("enclosure")
checks = {
    "shortVersionString": (get(item, "shortVersionString"), version),
    "minimumSystemVersion": (get(item, "minimumSystemVersion"), min_os),
    "hardwareRequirements": (get(item, "hardwareRequirements"), "arm64"),
    "enclosure url": (enc.get("url") if enc is not None else "", url),
}
for name, (got, want) in checks.items():
    if got != want:
        problems.append(f"new item {name} is '{got}', want '{want}'")
sig = enc.get(f"{{{S}}}edSignature") if enc is not None else None
if not sig:
    problems.append("new item has no sparkle:edSignature")
if problems:
    sys.exit("appcast: " + "; ".join(problems))
print(sig)
EOF
)"
# The signature verifies against the DMG with the key the app carries.
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
  "$sparkle/bin/sign_update" --verify --ed-key-file - "$work/$(basename "$dmg")" "$signature" >/dev/null ||
  die "the new item's EdDSA signature does not verify against $(basename "$dmg")"
# The feed is signed (the app requires it) and the signature verifies.
grep -q 'sparkle-signatures' "$work/appcast.xml" ||
  die "generate_appcast did not sign the feed (does the app set SURequireSignedFeed?)"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
  "$sparkle/bin/sign_update" --verify --ed-key-file - "$work/appcast.xml" >/dev/null ||
  die "the appcast's own signature does not verify"
log "new item $version (build $(build_number "$version")): signed, minimumSystemVersion $MACOS_MIN, arm64; feed signature verifies"

log "items in $work/appcast.xml:"
python3 -I - "$work/appcast.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    get = lambda tag: (item.findtext(f"sparkle:{tag}", namespaces=ns) or "").strip()
    enc = item.find("enclosure")
    url = enc.get("url") if enc is not None else "?"
    signed = enc is not None and enc.get("{%s}edSignature" % ns["sparkle"]) is not None
    print(f"  {get('shortVersionString'):<10} build {get('version'):<9} macOS {get('minimumSystemVersion') or '?':<6} "
          f"{get('hardwareRequirements') or 'any':<6} signed {signed}  {url}")
EOF
echo "$work/appcast.xml"
