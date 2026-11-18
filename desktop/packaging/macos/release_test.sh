#!/bin/bash
# Checks the release scripts' safeguards against synthetic feeds and stub
# `gh`/`git` commands: no network, no real release, no signing key.
#
#   desktop/packaging/macos/release_test.sh
#
# * check_appcast.py refuses a feed that drops an earlier item, an enclosure
#   without an EdDSA signature or with the wrong length or URL, a build that
#   is not the newest, and an item on a channel (one stable feed); it
#   accepts a correct feed and a patch release.
# * release_exists / feed_exists answer yes or no, and stop on any other
#   answer (a failed lookup is never "none yet").
# * publish-appcast.sh keeps the live appcast.xml when the new upload fails
#   or the new file cannot take its name, keeps the last one as
#   appcast.previous.xml when it succeeds, and stops on a feed release whose
#   appcast.xml is missing beside an appcast.previous.xml.
# * verify_enclosure accepts the DMG an item's signed enclosure describes
#   and refuses another file, another length or another key (with a
#   throwaway key made here; skipped without an Ed25519 openssl).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/conduit-release-test.XXXXXX")"
failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
expect() { # expect 0|1 label command...
  local want="$1" label="$2"
  shift 2
  "$@" >"$tmp/out.txt" 2>&1
  local rc=$?
  if { [ "$want" = 0 ] && [ "$rc" = 0 ]; } || { [ "$want" = 1 ] && [ "$rc" != 0 ]; }; then
    pass "$label"
  else
    fail "$label (exit $rc)"
    sed 's/^/      /' "$tmp/out.txt"
  fi
}

# ── check_appcast.py ────────────────────────────────────────────────────────
dmg="$tmp/Conduit-1.3.0.dmg"
printf 'synthetic dmg bytes' >"$dmg"
size="$(wc -c <"$dmg" | tr -d ' ')"
sig="$(python3 -c 'import base64; print(base64.b64encode(bytes(range(64))).decode())')"
url="https://example.org/releases/download/desktop-v1.3.0/Conduit-1.3.0.dmg"
item() { # build short url length signature channel
  local channel=""
  [ -n "$6" ] && channel="<sparkle:channel>$6</sparkle:channel>"
  printf '<item><title>%s</title><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString>%s<enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s"/></item>\n' \
    "$2" "$1" "$2" "$channel" "$3" "$4" "$5"
}
feed() { # file items...
  local f="$1"
  shift
  {
    printf '<?xml version="1.0"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Conduit</title>\n'
    printf '%s' "$@"
    printf '</channel></rss>\n'
  } >"$f"
}
old_item="$(item 1020099 1.2.0 https://example.org/Conduit-1.2.0.dmg 10 "$sig" "")"
new_item="$(item 1030099 1.3.0 "$url" "$size" "$sig" "")"
feed "$tmp/old.xml" "$old_item"
check() { python3 -I "$here/check_appcast.py" --old "$tmp/old.xml" --dmg "$dmg" --version 1.3.0 --build 1030099 --url "$url" --new "$@"; }

feed "$tmp/good.xml" "$new_item" "$old_item"
expect 0 "a feed with every earlier item and a signed new one is accepted" check "$tmp/good.xml"
feed "$tmp/dropped.xml" "$new_item"
expect 1 "a feed that drops an earlier item is refused" check "$tmp/dropped.xml"
feed "$tmp/unsigned.xml" "$(item 1030099 1.3.0 "$url" "$size" "" "")" "$old_item"
expect 1 "an enclosure without an EdDSA signature is refused" check "$tmp/unsigned.xml"
feed "$tmp/length.xml" "$(item 1030099 1.3.0 "$url" 999 "$sig" "")" "$old_item"
expect 1 "an enclosure of the wrong length is refused" check "$tmp/length.xml"
feed "$tmp/url.xml" "$(item 1030099 1.3.0 https://example.org/other.dmg "$size" "$sig" "")" "$old_item"
expect 1 "an enclosure at another URL is refused" check "$tmp/url.xml"
feed "$tmp/older.xml" "$new_item" "$old_item" "$(item 1040099 1.4.0 https://example.org/x.dmg 1 "$sig" "")"
expect 1 "a build older than one already in the feed is refused" check "$tmp/older.xml"
patch_url="https://example.org/releases/download/desktop-v1.2.1/Conduit-1.2.1.dmg"
feed "$tmp/patch-old.xml" "$old_item"
feed "$tmp/patch.xml" "$(item 1020199 1.2.1 "$patch_url" "$size" "$sig" "")" "$old_item"
expect 0 "a patch release 1.2.1 on top of 1.2.0 is accepted" \
  python3 -I "$here/check_appcast.py" --old "$tmp/patch-old.xml" --dmg "$dmg" --version 1.2.1 \
  --build 1020199 --url "$patch_url" --new "$tmp/patch.xml"
feed "$tmp/twice.xml" "$new_item" "$new_item" "$old_item"
expect 1 "two items for the new build are refused" check "$tmp/twice.xml"
feed "$tmp/channel.xml" "$(item 1030099 1.3.0 "$url" "$size" "$sig" beta)" "$old_item"
expect 1 "a release on a channel is refused" check "$tmp/channel.xml"

# ── release_exists / feed_exists ────────────────────────────────────────────
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/bin/bash
# A stub gh: STUB_LOOKUP=ok|404|500 answers release lookups; a release's
# files live in $STUB_ASSETS (one file per asset, named "<id> <name>").
echo "gh $*" >>"$STUB_LOG"
case "$1 $2" in
  "api repos/"*)
    if [ "$2" = "-X" ]; then :; fi
    ;;
esac
if [ "$1" = api ] && [ "$2" != "-X" ]; then
  case "${STUB_LOOKUP:-ok}" in
    404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    500) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
  esac
  case "$*" in
    *'select(.name == "appcast.next.xml")'*) ls "$STUB_ASSETS" | awk '$2 == "appcast.next.xml" {print $1}' ;;
    *".assets[]"*) ls "$STUB_ASSETS" ;;
    *) echo 42 ;;
  esac
  exit 0
fi
if [ "$1" = api ] && [ "$2" = "-X" ]; then
  id="${4##*/}"
  file="$(ls "$STUB_ASSETS" | awk -v id="$id" '$1 == id')"
  [ -n "$file" ] || exit 1
  case "$3" in
    DELETE) rm "$STUB_ASSETS/$file" ;;
    PATCH)
      name="${6#name=}"
      # STUB_RENAME_FAIL=<name>: renaming the file now called <name> fails.
      [ "${STUB_RENAME_FAIL:-}" = "${file#* }" ] && { echo "rename failed" >&2; exit 1; }
      mv "$STUB_ASSETS/$file" "$STUB_ASSETS/$id $name"
      ;;
  esac
  exit 0
fi
if [ "$1 $2" = "release upload" ]; then
  [ "${STUB_UPLOAD:-ok}" = fail ] && { echo "upload failed" >&2; exit 1; }
  name="$(basename "$4")"
  ls "$STUB_ASSETS" | awk -v n="$name" '$2 == n' | grep -q . && { echo "already exists" >&2; exit 1; }
  cp "$4" "$STUB_ASSETS/$RANDOM $name"
  exit 0
fi
if [ "$1 $2" = "release create" ]; then exit 0; fi
if [ "$1 $2" = "auth setup-git" ]; then exit 0; fi
echo "stub gh: unexpected $*" >&2
exit 2
STUB
cat >"$tmp/bin/git" <<'STUB'
#!/bin/bash
# A stub git: ls-remote exits with $STUB_GIT.
[ "$1" = ls-remote ] && exit "${STUB_GIT:-0}"
exit 3
STUB
chmod +x "$tmp/bin/gh" "$tmp/bin/git"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/gh.log" STUB_ASSETS="$tmp/assets"
mkdir -p "$STUB_ASSETS"
lookup() { # lookup want mode function [hosting]
  local want="$1" mode="$2" fn="$3" hosting="${4:-release-asset}" got
  got="$(STUB_LOOKUP="$mode" STUB_GIT="$mode" bash -c ". '$here/lib.sh'; APPCAST_HOSTING=$hosting; $fn" 2>/dev/null)"
  local rc=$?
  if [ "$want" = stop ]; then
    if [ "$rc" != 0 ] && [ -z "$got" ]; then pass "$fn stops when the lookup fails ($hosting, $mode)"; else fail "$fn on $mode gave '$got' (exit $rc)"; fi
  elif [ "$got" = "$want" ]; then
    pass "$fn says $want ($hosting, $mode)"
  else
    fail "$fn on $mode gave '$got', not $want"
  fi
}
lookup yes ok "release_exists desktop-v1.3.0"
lookup no 404 "release_exists desktop-v1.3.0"
lookup stop 500 "release_exists desktop-v1.3.0"
lookup no 404 feed_exists
lookup stop 500 feed_exists
lookup yes 0 feed_exists branch
lookup no 2 feed_exists branch
lookup stop 128 feed_exists branch

# ── publish-appcast.sh (release-asset) ──────────────────────────────────────
printf '<rss/>\n' >"$tmp/live.xml"
cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
expect 1 "a failed upload stops" env STUB_UPLOAD=fail APPCAST_HOSTING=release-asset \
  "$here/publish-appcast.sh" "$tmp/good.xml" --push
if ls "$STUB_ASSETS" | grep -qx '7 appcast.xml'; then
  pass "a failed upload leaves the live appcast.xml in place"
else
  fail "a failed upload lost the live appcast.xml: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
expect 0 "a good upload goes through" env APPCAST_HOSTING=release-asset \
  "$here/publish-appcast.sh" "$tmp/good.xml" --push
names="$(ls "$STUB_ASSETS" | awk '{print $2}' | sort | tr '\n' ' ')"
if [ "$names" = "appcast.previous.xml appcast.xml " ] && cmp -s "$STUB_ASSETS/7 appcast.previous.xml" "$tmp/live.xml"; then
  pass "the last appcast is kept as appcast.previous.xml"
else
  fail "after a good upload the files are: $names"
fi
expect 1 "a feed release that cannot be read stops publishing" env STUB_LOOKUP=500 \
  APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$tmp/good.xml" --push
# The new file uploaded, but it cannot take the live name: the live one is
# put back.
mkdir -p "$tmp/moved" && mv "$STUB_ASSETS" "$tmp/moved/assets-1" && mkdir -p "$STUB_ASSETS"
cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
expect 1 "a new appcast that cannot take the live name stops" env STUB_RENAME_FAIL=appcast.next.xml \
  APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$tmp/good.xml" --push
if ls "$STUB_ASSETS" | grep -qx '7 appcast.xml'; then
  pass "the live appcast.xml is put back when the new one cannot take its name"
else
  fail "after a failed rename the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
# A publication that stopped half way: never published over.
mv "$STUB_ASSETS" "$tmp/moved/assets-2" && mkdir -p "$STUB_ASSETS"
cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.previous.xml"
expect 1 "appcast.previous.xml without appcast.xml stops publishing" env \
  APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$tmp/good.xml" --push
if [ "$(ls "$STUB_ASSETS")" = "7 appcast.previous.xml" ]; then
  pass "a half-stopped publication is left for a person to put back"
else
  fail "after a half-stopped publication the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi

# ── verify_enclosure ────────────────────────────────────────────────────────
if openssl_path="$(bash -c ". '$here/lib.sh'; ed25519_openssl" 2>/dev/null)"; then
  "$openssl_path" genpkey -algorithm ed25519 -outform DER -out "$tmp/throwaway.der" 2>/dev/null
  "$openssl_path" genpkey -algorithm ed25519 -outform DER -out "$tmp/other.der" 2>/dev/null
  public_of() { "$openssl_path" pkey -inform DER -in "$1" -pubout -outform DER | tail -c 32 | base64; }
  key="$(public_of "$tmp/throwaway.der")"
  other_key="$(public_of "$tmp/other.der")"
  "$openssl_path" pkeyutl -sign -inkey "$tmp/throwaway.der" -keyform DER -rawin -in "$dmg" \
    -out "$tmp/dmg.sig"
  signed="$(base64 <"$tmp/dmg.sig" | tr -d '\n')"
  feed "$tmp/signed.xml" "$(item 1030099 1.3.0 "$url" "$size" "$signed" "")" "$old_item"
  enclosure() { bash -c ". '$here/lib.sh'; verify_enclosure \"\$@\"" _ "$@"; }
  expect 0 "the DMG its signed enclosure describes is accepted" \
    enclosure "$tmp/signed.xml" 1030099 "$dmg" "$key"
  printf 'swapped dmg bytes!!' >"$tmp/swapped.dmg"
  expect 1 "another DMG of the same length is refused" \
    enclosure "$tmp/signed.xml" 1030099 "$tmp/swapped.dmg" "$key"
  printf 'synthetic dmg bytes, longer' >"$tmp/longer.dmg"
  expect 1 "a DMG of another length is refused" \
    enclosure "$tmp/signed.xml" 1030099 "$tmp/longer.dmg" "$key"
  expect 1 "a signature made with another key is refused" \
    enclosure "$tmp/signed.xml" 1030099 "$dmg" "$other_key"
  expect 1 "no public key refuses" enclosure "$tmp/signed.xml" 1030099 "$dmg" ""
else
  echo "skip  verify_enclosure (no openssl with Ed25519 here)"
fi

echo
if [ "$failures" = 0 ]; then
  echo "release_test: all checks passed"
else
  echo "release_test: $failures failed"
  exit 1
fi
