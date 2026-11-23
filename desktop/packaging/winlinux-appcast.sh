#!/bin/bash
# Adds a release to the Windows or the Linux update feed, as appcast.sh
# does to the Mac's: the item and the feed signed with that OS's private
# EdDSA key from the environment.
#
#   desktop/packaging/winlinux-appcast.sh --os windows|linux --version V [options]
#
# The feeds live beside the Mac's appcast.xml (release.env's hosting):
# appcast-windows.xml, which WinSparkle reads, and appcast-linux.xml, which
# the Linux app's update notice reads. Both are Sparkle appcasts signed as
# the Mac's is (winlinux_feed.py writes them). The current feed is fetched
# from its URL (winlinux_feed.py url), V's item is added on top and the
# result goes to <work>/appcast-<os>.xml, keeping the items already there.
# One channel, the default (stable) one: a -beta.N version is refused.
# Nothing is uploaded here; publishing is the release workflow's.
#
# Before it returns, the result is checked:
#   - winlinux_feed.py check: the feed keeps every earlier item, and the
#     new one is V's build, the newest, on no channel, with one signature
#     block; Windows: its enclosure is the installer's length, at its URL,
#     signed, for windows-x64 with WinSparkle's installer arguments;
#   - the private key's public half is <OS>_PUBLIC_ED_KEY (when set);
#   - lib.sh verify_enclosure (Windows): the item's signature is the
#     installer's, by that public key, as WinSparkle checks it;
#   - lib.sh verify_feed: the feed's own signature, as the Mac's feed job
#     checks it and the Linux notice requires it (WinSparkle reads the feed
#     without checking it).
#
# Options:
#   --os windows|linux
#   --version V             the release (1.2.0)
#   --installer FILE        Windows: Conduit-V-windows-x64-setup.exe
#   --work DIR              working folder (default: desktop/target/feeds/<os>-V)
#   --download-url-prefix U Windows: where the installer will be downloaded
#                           from (default: the version's GitHub release)
#   --existing FILE         start from this feed instead of fetching one
#   --fresh                 start a new feed (that OS's first release only)
#   --allow-new             start a new feed when its URL answers 404 (CI:
#                           the first release); any other failure stops
#   --feed-public-key K     the key the current feed is signed with, when
#                           it isn't the one that signs this release: the
#                           first release after a key swap names the retired
#                           key (docs/RELEASING-DESKTOP.md). A release is
#                           added only to a feed that key signed.
#   --next-public-key K     a key rotation's bridge release
#                           (docs/RELEASING-DESKTOP.md, "Rotating the Windows
#                           and Linux keys"): the app built for this release
#                           trusts K, the next public key. The item and the
#                           feed are still signed with <OS>_ED_PRIVATE_KEY,
#                           which must belong to <OS>_PUBLIC_ED_KEY (required
#                           then).
#
# Environment (<OS> is WINDOWS or LINUX):
#   <OS>_ED_PRIVATE_KEY     the private EdDSA key (base64, as Sparkle's
#                           generate_keys -x exports it). Required; it goes
#                           to openssl on stdin, never in argv.
#   <OS>_PUBLIC_ED_KEY      the public key installed copies have, which
#                           signs the release (checked against the private
#                           one; optional, but required with
#                           --next-public-key)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=macos/lib.sh
. "$here/macos/lib.sh"

os=""
version=""
installer=""
work=""
prefix=""
existing=""
fresh=0
allow_new=0
next_key=""
feed_key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --os) os="$2"; shift ;;
    --version) version="$2"; shift ;;
    --installer) installer="$2"; shift ;;
    --work) work="$2"; shift ;;
    --download-url-prefix) prefix="$2"; shift ;;
    --existing) existing="$2"; shift ;;
    --fresh) fresh=1 ;;
    --allow-new) allow_new=1 ;;
    --next-public-key) next_key="$2"; shift ;;
    --feed-public-key) feed_key="$2"; shift ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
case "$os" in
  windows) OS=WINDOWS ;;
  linux) OS=LINUX ;;
  *) die "--os windows or --os linux" ;;
esac
check_version "$version"
refuse_beta_release "$version"
private_var="${OS}_ED_PRIVATE_KEY"
public_var="${OS}_PUBLIC_ED_KEY"
private="${!private_var:-}"
expected="${!public_var:-}"
[ -n "$private" ] || die "$private_var is not set"
if [ "$os" = windows ]; then
  [ -f "$installer" ] || die "--installer: no such file '$installer'"
  [ "$(basename "$installer")" = "Conduit-$version-windows-x64-setup.exe" ] ||
    die "--installer $(basename "$installer") is not Conduit-$version-windows-x64-setup.exe"
  installer="$(cd "$(dirname "$installer")" && pwd)/$(basename "$installer")"
  prefix="${prefix:-https://github.com/$RELEASE_REPO/releases/download/desktop-v$version/}"
  case "$prefix" in */) ;; *) prefix="$prefix/" ;; esac
else
  [ -z "$installer" ] || die "--installer: the Linux feed names the release page, not a download"
  [ -z "$prefix" ] || die "--download-url-prefix: the Linux feed names the release page, not a download"
fi
feed_name="appcast-$os.xml"
feed="$(python3 -I "$here/winlinux_feed.py" url "$os")"
work="${work:-$DESKTOP_DIR/target/feeds/$os-$version}"
export OPENSSL
OPENSSL="$(ed25519_openssl)"

# The key pair: the private key must belong to the public key installed
# copies have, or WinSparkle refuses the update and the notice the feed.
public="$(printf '%s' "$private" | sparkle_public_key)"
[ -n "$public" ] || die "$private_var is not an EdDSA private key (base64)"
if [ -n "$expected" ] && [ "$public" != "$expected" ]; then
  die "$private_var does not belong to $public_var"
fi
if [ -n "$next_key" ]; then
  [ -n "$expected" ] ||
    die "--next-public-key needs $public_var, the key installed copies have now, which signs this release"
  is_ed25519_public_key "$next_key" || die "--next-public-key is not an EdDSA public key (base64 of 32 bytes)"
  [ "$next_key" != "$public" ] || die "--next-public-key is $private_var's own public key: nothing to rotate"
  warn "key rotation: the $os app of $version trusts the next public key; its item and the feed are signed with $private_var, which installed copies have now"
fi
if [ -n "$feed_key" ]; then
  is_ed25519_public_key "$feed_key" || die "--feed-public-key is not an EdDSA public key (base64 of 32 bytes)"
else
  feed_key="$public"
fi

# Inputs inside --work would be moved aside with it before they are read.
for input in "$existing" "$installer"; do
  [ -n "$input" ] || continue
  if python3 -I -c 'import os, sys; w, p = map(os.path.realpath, sys.argv[1:]); sys.exit(os.path.commonpath([w, p]) != w)' \
    "$work" "$input"; then
    die "$input is inside --work $work, which is moved aside first: put it elsewhere"
  fi
done

move_aside "$work"
mkdir -p "$work"
old_file=""
if [ -n "$existing" ]; then
  cp "$existing" "$work/previous-$feed_name"
  old_file="$work/previous-$feed_name"
  log "starting from $existing"
elif [ "$fresh" = 1 ]; then
  log "starting a new $os feed"
else
  # A missing feed (404) is that OS's first release; any other failure
  # stops here, so a network error never replaces the feed with a new one.
  code="$(curl -sSL --retry 3 -o "$work/previous-$feed_name" -w '%{http_code}' "$feed" || true)"
  case "$code" in
    200)
      old_file="$work/previous-$feed_name"
      log "fetched the current $os feed from $feed"
      ;;
    404)
      mv "$work/previous-$feed_name" "$work/not-found.html" 2>/dev/null || true
      [ "$allow_new" = 1 ] || die "no feed at $feed (HTTP 404). For that OS's first release pass --fresh."
      log "no feed at $feed yet (HTTP 404): starting a new one"
      ;;
    *) die "could not fetch $feed (HTTP $code)" ;;
  esac
fi

out="$work/$feed_name"
args=(add --os "$os" --version "$version" --out "$out")
checks=(check --os "$os" --feed "$out" --version "$version")
if [ -n "$old_file" ]; then
  args+=(--old "$old_file" --old-public-key "$feed_key")
  checks+=(--old "$old_file")
fi
if [ "$os" = windows ]; then
  args+=(--installer "$installer" --download-url-prefix "$prefix")
  checks+=(--installer "$installer" --url "$prefix$(basename "$installer")")
fi
# The key stays in the environment: the command line is safe to print.
log "winlinux_feed.py$(printf ' %q' "${args[@]}")"
python3 -I "$here/winlinux_feed.py" "${args[@]}" || die "winlinux_feed.py could not add $version"

# Nothing is published unless the feed keeps every earlier item and the new
# one is right; then the signatures, by the public key alone.
python3 -I "$here/winlinux_feed.py" "${checks[@]}" || die "the new $os feed is not safe to publish"
if [ "$os" = windows ]; then
  verify_enclosure "$out" "$(build_number "$version")" "$installer" "$public" ||
    die "the new item's EdDSA signature does not verify against $(basename "$installer")"
fi
verify_feed "$out" "$public" || die "the $os feed's own signature does not pass verify_feed"
log "new $os item $version (build $(build_number "$version")): signed; feed signature verifies"

log "items in $out:"
python3 -I - "$out" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
data = open(sys.argv[1], "rb").read()
cut = data.rfind(b"<!-- sparkle-signatures:")
for item in ET.fromstring(data[:cut] if cut >= 0 else data).iter("item"):
    get = lambda tag: (item.findtext(f"sparkle:{tag}", namespaces=ns) or "").strip()
    enc = item.find("enclosure")
    where = enc.get("url") if enc is not None else (item.findtext("link") or "?").strip()
    print(f"  {get('shortVersionString'):<10} build {get('version'):<9} {where}")
EOF
echo "$out"
