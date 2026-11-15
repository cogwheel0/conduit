#!/bin/bash
# Adds a release to Sparkle's appcast with generate_appcast, signing the
# update with the private EdDSA key from the environment.
#
#   desktop/packaging/macos/appcast.sh --dmg PATH --version V [options]
#
# The current appcast is fetched from the feed URL (release.env, or
# CONDUIT_APPCAST_URL), the new DMG is added next to it, and
# generate_appcast writes the result to <work>/appcast.xml, keeping the
# items already there. A version with a -beta.N suffix goes on the `beta`
# channel (<sparkle:channel>beta</sparkle:channel>), which only copies with
# Settings › About › "Receive beta updates" on are offered; the rest go on
# the default channel, which everyone gets. Nothing is uploaded here; see
# publish-appcast.sh.
#
# Options:
#   --dmg PATH              the notarized DMG (the update archive)
#   --version V             its version (1.2.0, 1.3.0-beta.2)
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
#                           to generate_appcast on stdin, never in argv.
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
    -h | --help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[ -f "$dmg" ] || die "--dmg: no such file '$dmg'"
check_version "$version"
[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || die "SPARKLE_ED_PRIVATE_KEY is not set"
work="${work:-$(cd "$(dirname "$dmg")" && pwd)/appcast}"
prefix="${prefix:-https://github.com/$RELEASE_REPO/releases/download/desktop-v$version/}"
case "$prefix" in */) ;; *) prefix="$prefix/" ;; esac
feed="$(appcast_url)"
sparkle="$(sparkle_dir)"

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
channel=default
if is_beta "$version"; then
  args+=(--channel beta)
  channel=beta
fi
log "generate_appcast: $(basename "$dmg") on the $channel channel"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sparkle/bin/generate_appcast" "${args[@]}" "$work"
xmllint --noout "$work/appcast.xml"

# Nothing is published unless the feed keeps every earlier item and the new
# one is signed, the DMG's length, at its URL and the newest build.
beta=()
if is_beta "$version"; then beta=(--beta); fi
build="$(build_number "$version")"
python3 -I "$here/check_appcast.py" --new "$work/appcast.xml" ${old[@]+"${old[@]}"} --dmg "$dmg" \
  --version "$version" --build "$build" --url "$prefix$(basename "$dmg")" ${beta[@]+"${beta[@]}"} ||
  die "the new appcast is not safe to publish"
signature="$(python3 -I "$here/check_appcast.py" --signature-of "$build" --new "$work/appcast.xml")"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
  "$sparkle/bin/sign_update" --verify --ed-key-file - "$dmg" "$signature" ||
  die "the DMG's EdDSA signature does not verify"
log "the new item's signature verifies"

log "items in $work/appcast.xml:"
python3 -I - "$work/appcast.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    get = lambda tag: (item.findtext(f"sparkle:{tag}", namespaces=ns) or "").strip()
    enc = item.find("enclosure")
    url = enc.get("url") if enc is not None else "?"
    signed = enc is not None and enc.get("{%s}edSignature" % ns["sparkle"]) is not None
    print(f"  {get('shortVersionString'):<16} build {get('version'):<10} channel {get('channel') or 'default':<8} "
          f"signed {signed}  {url}")
EOF
echo "$work/appcast.xml"
