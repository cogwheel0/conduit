#!/bin/bash
# Checks the release scripts' safeguards against synthetic feeds, Sparkle
# keys made here, and stub `gh`/`git` commands: no real release, no real
# key. On macOS it also runs the pinned Sparkle's own tools (downloaded once,
# checksum-verified, as bundle.sh does) on synthetic apps and DMGs. It needs
# an openssl that does Ed25519, as the release does.
#
#   desktop/packaging/macos/release_test.sh
#
# * check_appcast.py refuses a feed that drops an earlier item, an enclosure
#   without an EdDSA signature or with the wrong length or URL, a build that
#   is not the newest, and an item on a channel (one stable feed); it
#   accepts a correct feed and a patch release.
# * release_exists / feed_exists answer yes or no, and stop on any other
#   answer (a failed lookup is never "none yet").
# * publish-appcast.sh publishes only a feed signed with
#   SPARKLE_PUBLIC_ED_KEY: an unsigned one, one changed after it was signed,
#   or one signed with another key stops before any upload. It keeps the
#   live appcast.xml when the new upload fails or the new file cannot take
#   its name, keeps the last one as appcast.previous.xml when it succeeds,
#   and stops on a feed release whose appcast.xml is missing beside an
#   appcast.previous.xml.
# * a rename or delete GitHub applied whose reply was lost is judged by the
#   file's real state, so the publication completes or is put back.
# * publish-appcast.sh --os windows|linux publishes that OS's feed beside
#   the Mac's under its own names, only signed with its own key
#   (WINDOWS_PUBLIC_ED_KEY, LINUX_PUBLIC_ED_KEY), keeps the last one as
#   appcast-<os>.previous.xml, stops on a half-stopped publication of it,
#   never makes the feed release, and never touches the Mac's files.
# * a feed already live, byte for byte (a re-run after a publication that
#   stopped part way), is left as it is, its last copy kept, for every OS.
# * winlinux_feed_state says live or new for each OS's feed, and stops on
#   a half-stopped publication or a lookup that fails; feed_signing_key
#   names the key the published feed is signed with (the current one, or
#   the retired one after a key swap), and stops on a feed neither signed
#   and on a retired key left set once it is no longer needed.
# * a binary built with the test harness is never signed for distribution,
#   and a step takes only the bundle id it was asked for.
# * no entitlements file bundle.sh signs with grants get-task-allow (a
#   debugger's entitlement), read as the property list holds it: set true
#   (an XML-escaped key too) it is refused; set false, absent or only in a
#   comment it is not; a file that is no property list is refused.
#   sign-dev.sh's dev copy sets it Boolean true, and is refused.
# * verify_enclosure accepts the DMG an item's signed enclosure describes
#   and refuses another file, another length or another key.
# * release_app_key gives the app the next key only for the one tag both
#   rotation variables name, and stops on any other combination; for the
#   Windows and Linux keys it names their own variables.
# * verify_feed, the feed job's check, gives Sparkle's own verdict
#   (`sign_update --verify`) on feeds sign_update signs: a good one, one
#   changed after it was signed, one signed with another key, an unsigned
#   one (macOS).
# * appcast.sh, through the pinned generate_appcast, on synthetic DMGs: a
#   release; a key rotation's bridge release (an app carrying the next key)
#   only with --next-public-key naming that key, its update and feed signed
#   with the current key; the release after it, with the keys swapped,
#   keeping the bridge's item; an attach hdiutil fails once is tried
#   again, one that keeps failing stops with hdiutil's message, and a
#   volume still busy at detach does not stop the release (macOS).
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
# files live in $STUB_ASSETS (one file per asset, named "<id> <name>"); the
# feed release's state (none, draft, published) is in $STUB_STATE (no file:
# published). STUB_UPLOAD, STUB_PUBLISH=fail and STUB_DOWNLOAD=other|fail
# make those steps fail, or read back other bytes or nothing.
echo "gh $*" >>"$STUB_LOG"
if [ "$1" = api ] && [[ "$*" == *"/releases?per_page"* ]]; then
  [ "${STUB_LOOKUP:-ok}" = 500 ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
  state="$(cat "$STUB_STATE" 2>/dev/null || echo published)"
  [ "$state" = none ] || echo "$state"
  exit 0
fi
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
    *"/releases/assets/"*)
      id="${2##*/}"
      file="$(ls "$STUB_ASSETS" | awk -v id="$id" '$1 == id')"
      [ -n "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      echo "${file#* }"
      ;;
    *'select(.name == '*)
      want="$*"
      want="${want#*select(.name == \"}"
      want="${want%%\"*}"
      ls "$STUB_ASSETS" | awk -v n="$want" '$2 == n {print $1}'
      ;;
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
    DELETE)
      mv "$STUB_ASSETS/$file" "$STUB_MOVED/deleted-$file"
      # STUB_LOST_DELETE=1: the file is deleted, but the reply is lost.
      [ "${STUB_LOST_DELETE:-}" = 1 ] && { echo "connection reset" >&2; exit 1; }
      ;;
    PATCH)
      name="${6#name=}"
      # STUB_RENAME_FAIL=<glob>: renaming a file whose name matches fails.
      # shellcheck disable=SC2254
      case "${file#* }" in ${STUB_RENAME_FAIL:-//none//}) echo "rename failed" >&2; exit 1 ;; esac
      mv "$STUB_ASSETS/$file" "$STUB_ASSETS/$id $name"
      # STUB_LOST_REPLY=<name>: a rename to <name> is done, but its reply is
      # lost (gh fails although GitHub applied it).
      [ "${STUB_LOST_REPLY:-}" = "$name" ] && { echo "connection reset" >&2; exit 1; }
      ;;
  esac
  exit 0
fi
if [ "$1 $2" = "release upload" ]; then
  [ "${STUB_UPLOAD:-ok}" = fail ] && { echo "upload failed" >&2; exit 1; }
  name="$(basename "$4")"
  existing="$(ls "$STUB_ASSETS" | awk -v n="$name" '$2 == n')"
  if [ -n "$existing" ]; then
    [[ " $* " == *" --clobber "* ]] || { echo "already exists" >&2; exit 1; }
    mv "$STUB_ASSETS/$existing" "$STUB_MOVED/replaced-$existing"
  fi
  # Ids from a counter that starts past the fixtures' (5, 7, 9): unique and
  # the same on every run.
  id=$(( $(cat "$STUB_IDS" 2>/dev/null || echo 1000) + 1 ))
  echo "$id" >"$STUB_IDS"
  cp "$4" "$STUB_ASSETS/$id $name"
  exit 0
fi
if [ "$1 $2" = "release download" ]; then
  pattern="" dir=""
  while [ $# -gt 0 ]; do
    case "$1" in -p) pattern="$2"; shift ;; -D) dir="$2"; shift ;; esac
    shift
  done
  [ "${STUB_DOWNLOAD:-}" = fail ] && { echo "gh: download failed" >&2; exit 1; }
  file="$(ls "$STUB_ASSETS" | awk -v n="$pattern" '$2 == n')"
  [ -n "$file" ] || { echo "no asset $pattern" >&2; exit 1; }
  if [ "${STUB_DOWNLOAD:-}" = other ]; then printf 'other bytes' >"$dir/$pattern"; else cp "$STUB_ASSETS/$file" "$dir/$pattern"; fi
  exit 0
fi
if [ "$1 $2" = "release edit" ]; then
  if [[ " $* " == *" --draft=false "* ]]; then
    [ "${STUB_PUBLISH:-ok}" = fail ] && { echo "publish failed" >&2; exit 1; }
    echo published >"$STUB_STATE"
  fi
  exit 0
fi
if [ "$1 $2" = "release create" ]; then
  if [[ " $* " == *" --draft "* ]]; then echo draft >"$STUB_STATE"; else echo published >"$STUB_STATE"; fi
  exit 0
fi
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
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/gh.log" STUB_ASSETS="$tmp/assets" \
  STUB_STATE="$tmp/feed-state" STUB_MOVED="$tmp/moved-assets" STUB_IDS="$tmp/stub-ids"
mkdir -p "$STUB_ASSETS" "$STUB_MOVED"
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

# ── Sparkle keys made here, and feeds signed with them ──────────────────────
openssl_path="$(bash -c ". '$here/lib.sh'; ed25519_openssl")" || {
  echo "release_test: needs an openssl that does Ed25519, as the release does (brew install openssl@3, or set OPENSSL)"
  exit 1
}
for k in a b c; do
  "$openssl_path" genpkey -algorithm ed25519 -outform DER -out "$tmp/key-$k.der" 2>/dev/null
done
public_of() { "$openssl_path" pkey -inform DER -in "$1" -pubout -outform DER | tail -c 32 | base64; }
private_of() { tail -c 32 "$1" | base64; } # the seed, as generate_keys -x exports it
key_a="$(public_of "$tmp/key-a.der")"
key_b="$(public_of "$tmp/key-b.der")"
key_c="$(public_of "$tmp/key-c.der")"
sign_feed() { # unsigned signed key.der: appends the block Sparkle's signAppcast writes
  "$openssl_path" pkeyutl -sign -inkey "$3" -keyform DER -rawin -in "$1" -out "$tmp/feed.sig" || return 1
  {
    cat "$1"
    printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' \
      "$(base64 <"$tmp/feed.sig" | tr -d '\n')" "$(wc -c <"$1" | tr -d ' ')"
  } >"$2"
}
feed_check() { bash -c ". '$here/lib.sh'; verify_feed \"\$@\"" _ "$@"; }
cp "$tmp/good.xml" "$tmp/good-unsigned.xml"
sign_feed "$tmp/good-unsigned.xml" "$tmp/good.xml" "$tmp/key-a.der"
sign_feed "$tmp/good-unsigned.xml" "$tmp/good-other-key.xml" "$tmp/key-b.der"
sed 's#desktop-v1.3.0#desktop-v6.6.6#' "$tmp/good.xml" >"$tmp/good-changed.xml"
export SPARKLE_PUBLIC_ED_KEY="$key_a"

# ── release_app_key ─────────────────────────────────────────────────────────
app_key() { # want label tag current next rotation-tag
  local want="$1" label="$2" got rc
  shift 2
  got="$(bash -c ". '$here/lib.sh'; release_app_key \"\$@\"" _ "$@" 2>"$tmp/out.txt")"
  rc=$?
  if { [ "$want" = stop ] && [ "$rc" != 0 ] && [ -z "$got" ]; } ||
    { [ "$want" != stop ] && [ "$rc" = 0 ] && [ "$got" = "$want" ]; }; then
    pass "$label"
  else
    fail "$label (got '$got', exit $rc)"
    sed 's/^/      /' "$tmp/out.txt"
  fi
}
app_key "$key_a" "without rotation variables the app carries the signing key" desktop-v1.3.0 "$key_a" "" ""
app_key "$key_b" "the tag both rotation variables name carries the next key" desktop-v1.3.0 "$key_a" "$key_b" desktop-v1.3.0
app_key stop "the next key without the rotation tag stops" desktop-v1.3.0 "$key_a" "$key_b" ""
app_key stop "the rotation tag without the next key stops" desktop-v1.3.0 "$key_a" "" desktop-v1.3.0
app_key stop "rotation variables left set for an earlier tag stop the next release" desktop-v1.4.0 "$key_a" "$key_b" desktop-v1.3.0
app_key stop "a next key that is the signing key's stops" desktop-v1.3.0 "$key_a" "$key_a" desktop-v1.3.0
app_key stop "a next key that is not a key stops" desktop-v1.3.0 "$key_a" "not-a-key" desktop-v1.3.0
# The Windows and Linux keys rotate by the same rule, under their own names.
app_key "$key_b" "a Windows bridge release carries the next Windows key" \
  desktop-v1.3.0 "$key_a" "$key_b" desktop-v1.3.0 WINDOWS
app_key stop "a Windows rotation tag without the next Windows key stops" \
  desktop-v1.3.0 "$key_a" "" desktop-v1.3.0 WINDOWS
if grep -q 'WINDOWS_NEXT_PUBLIC_ED_KEY and WINDOWS_KEY_ROTATION_TAG' "$tmp/out.txt" && ! grep -q SPARKLE "$tmp/out.txt"; then
  pass "and the stop names the Windows variables, not Sparkle's"
else
  fail "a Windows rotation's stop said: $(cat "$tmp/out.txt")"
fi
app_key stop "Linux rotation variables left set for an earlier tag stop the next release" \
  desktop-v1.4.0 "$key_a" "$key_b" desktop-v1.3.0 LINUX
grep -q 'LINUX_KEY_ROTATION_TAG names desktop-v1.3.0' "$tmp/out.txt" &&
  pass "and the stop names LINUX_KEY_ROTATION_TAG" || fail "a Linux rotation's stop said: $(cat "$tmp/out.txt")"

# ── publish-appcast.sh (release-asset) ──────────────────────────────────────
printf '<rss/>\n' >"$tmp/live.xml"
cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
# Refused before any gh call: nothing is uploaded, the live feed stays.
gh_calls() { if [ -f "$STUB_LOG" ]; then wc -l <"$STUB_LOG" | tr -d ' '; else echo 0; fi; }
refused() { # label feed [env...]
  local label="$1" xml="$2" before
  shift 2
  before="$(gh_calls)"
  expect 1 "$label" env "$@" APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$xml" --push
  if grep -q 'SPARKLE_PUBLIC_ED_KEY' "$tmp/out.txt" && [ "$(gh_calls)" = "$before" ] &&
    [ "$(ls "$STUB_ASSETS")" = "7 appcast.xml" ]; then
    pass "$label: refused for its signature, before anything reached GitHub"
  else
    fail "$label: $(tail -1 "$tmp/out.txt"); gh calls $before -> $(gh_calls); files: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
  fi
}
refused "an unsigned feed is never published" "$tmp/good-unsigned.xml"
refused "a feed changed after it was signed is never published" "$tmp/good-changed.xml"
refused "a feed signed with another key is never published" "$tmp/good-other-key.xml"
refused "a feed is never published without SPARKLE_PUBLIC_ED_KEY" "$tmp/good.xml" -u SPARKLE_PUBLIC_ED_KEY
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
aside=0
mkdir -p "$tmp/moved" && mv "$STUB_ASSETS" "$tmp/moved/assets-1" && mkdir -p "$STUB_ASSETS"
cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
expect 1 "a new appcast that cannot take the live name stops" env STUB_RENAME_FAIL='appcast.next*' \
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

# The first publication: a draft first, published only once its appcast.xml
# is uploaded and read back, so a failure leaves nothing live and the next
# run takes the draft over.
fresh_feed() { # state
  aside=$((aside + 1)) && mv "$STUB_ASSETS" "$tmp/moved/assets-r$aside" && mkdir -p "$STUB_ASSETS"
  echo "$1" >"$STUB_STATE"
}
feed_state() { cat "$STUB_STATE"; }
first() { env APPCAST_HOSTING=release-asset STUB_LOOKUP=404 "$@" "$here/publish-appcast.sh" "$tmp/good.xml" --push; }
fresh_feed none
expect 1 "a first publication whose upload fails stops" first STUB_UPLOAD=fail
if [ "$(feed_state)" = draft ] && ! ls "$STUB_ASSETS" | grep -q ' appcast.xml$'; then
  pass "a failed first upload leaves only a draft, nothing live"
else
  fail "after a failed first upload the feed release is $(feed_state) with: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
expect 0 "the next run takes the draft over and publishes it" first
if [ "$(feed_state)" = published ] && cmp -s "$STUB_ASSETS/$(ls "$STUB_ASSETS" | awk '$2 == "appcast.xml"')" "$tmp/good.xml"; then
  pass "the retried first publication is live with the new appcast.xml"
else
  fail "after the retry the feed release is $(feed_state) with: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
fresh_feed none
expect 1 "a first publication that cannot publish its draft stops" first STUB_PUBLISH=fail
[ "$(feed_state)" = draft ] && pass "a draft that could not be published stays a draft" ||
  fail "after a failed publish the feed release is $(feed_state)"
expect 0 "the next run publishes the draft" first
fresh_feed none
expect 1 "a first appcast that reads back as other bytes stops" first STUB_DOWNLOAD=other
[ "$(feed_state)" = draft ] && pass "an appcast that reads back wrong is never published" ||
  fail "after a wrong read-back the feed release is $(feed_state)"
fresh_feed published

# A request GitHub applied whose reply was lost: the file's real name
# decides, so the publication goes on (or is put back) by what happened.
lost() { # env... : a published feed with live 7 and an older previous 5
  aside=$((aside + 1)) && mv "$STUB_ASSETS" "$tmp/moved/assets-r$aside" && mkdir -p "$STUB_ASSETS"
  echo published >"$STUB_STATE"
  cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
  printf '<rss/>older\n' >"$STUB_ASSETS/5 appcast.previous.xml"
  env APPCAST_HOSTING=release-asset "$@" "$here/publish-appcast.sh" "$tmp/good.xml" --push
}
live_is() { # file: appcast.xml holds it, and the old live one is appcast.previous.xml
  cmp -s "$STUB_ASSETS/$(ls "$STUB_ASSETS" | awk '$2 == "appcast.xml"')" "$1" &&
    ls "$STUB_ASSETS" | grep -qx '7 appcast.previous.xml'
}
expect 0 "a promotion GitHub applied, its reply lost, completes" lost STUB_LOST_REPLY=appcast.xml
live_is "$tmp/good.xml" && pass "after a lost promotion reply the new appcast is live" ||
  fail "after a lost promotion reply the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
expect 0 "a set-aside GitHub applied, its reply lost, goes on" lost STUB_LOST_REPLY=appcast.previous.xml
live_is "$tmp/good.xml" && pass "after a lost set-aside reply the new appcast is live" ||
  fail "after a lost set-aside reply the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
expect 0 "a delete GitHub applied, its reply lost, goes on" lost STUB_LOST_DELETE=1
live_is "$tmp/good.xml" && pass "after a lost delete reply the new appcast is live" ||
  fail "after a lost delete reply the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
lost STUB_RENAME_FAIL='appcast.next*' STUB_LOST_REPLY=appcast.xml >"$tmp/out.txt" 2>&1
if grep -q 'the live one is unchanged' "$tmp/out.txt" && ls "$STUB_ASSETS" | grep -qx '7 appcast.xml'; then
  pass "a restoration GitHub applied, its reply lost, reports the live feed unchanged"
else
  fail "after a lost restoration reply: $(tail -1 "$tmp/out.txt"); files: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi

# A publication run by hand alongside (outside CI's queue) has its own
# staged file: this run promotes only the file it uploaded, and leaves the
# other's alone.
aside=$((aside + 1)) && mv "$STUB_ASSETS" "$tmp/moved/assets-r$aside" && mkdir -p "$STUB_ASSETS"
echo published >"$STUB_STATE"
cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
printf '<rss/>another run\n' >"$STUB_ASSETS/9 appcast.next.xml"
expect 0 "a publication beside another run's staged file goes through" env APPCAST_HOSTING=release-asset \
  "$here/publish-appcast.sh" "$tmp/good.xml" --push
if cmp -s "$STUB_ASSETS/$(ls "$STUB_ASSETS" | awk '$2 == "appcast.xml"')" "$tmp/good.xml" &&
  [ -f "$STUB_ASSETS/9 appcast.next.xml" ]; then
  pass "only this run's upload is promoted; the other run's staged file stays"
else
  fail "beside another run's staged file the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi

# ── the Windows and Linux feeds on the feed release ─────────────────────────
# Each OS's feed lives beside the Mac's appcast.xml on the same published
# feed release, under its own names, checked with its own key; the Mac's
# files are never touched.
feed_release() { # files...: a published feed release holding these ("<id> <name>" each)
  aside=$((aside + 1)) && mv "$STUB_ASSETS" "$tmp/moved/assets-r$aside" && mkdir -p "$STUB_ASSETS"
  echo published >"$STUB_STATE"
  local f
  for f in "$@"; do cp "$tmp/live.xml" "$STUB_ASSETS/$f"; done
}
asset_named() { ls "$STUB_ASSETS" | awk -v n="$1" '$2 == n'; }
mac_untouched() { [ "$(asset_named appcast.xml)" = "7 appcast.xml" ] && cmp -s "$STUB_ASSETS/7 appcast.xml" "$tmp/live.xml" &&
  [ -z "$(asset_named appcast.previous.xml)" ]; }
sign_feed "$tmp/good-unsigned.xml" "$tmp/good-key-c.xml" "$tmp/key-c.der"
export WINDOWS_PUBLIC_ED_KEY="$key_b" LINUX_PUBLIC_ED_KEY="$key_c"
publish_os() { # os feed [env options and assignments...]
  local os="$1" xml="$2"
  shift 2
  # env takes its options (-u) before any assignment.
  env "$@" APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$xml" --push --os "$os"
}

feed_release "7 appcast.xml"
before="$(gh_calls)"
expect 1 "a Windows feed signed with another key (the Mac's) is never published" publish_os windows "$tmp/good.xml"
if grep -q 'WINDOWS_PUBLIC_ED_KEY' "$tmp/out.txt" && [ "$(gh_calls)" = "$before" ] && [ "$(ls "$STUB_ASSETS")" = "7 appcast.xml" ]; then
  pass "it is refused for its signature by WINDOWS_PUBLIC_ED_KEY, before anything reached GitHub"
else
  fail "a Windows feed signed with the Mac's key: $(tail -1 "$tmp/out.txt"); gh calls $before -> $(gh_calls); files: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
before="$(gh_calls)"
expect 1 "a Windows feed is never published without WINDOWS_PUBLIC_ED_KEY" \
  publish_os windows "$tmp/good-other-key.xml" -u WINDOWS_PUBLIC_ED_KEY
if grep -q 'WINDOWS_PUBLIC_ED_KEY is not set' "$tmp/out.txt" && [ "$(gh_calls)" = "$before" ]; then
  pass "it is refused for the missing key, before anything reached GitHub"
else
  fail "a Windows feed without WINDOWS_PUBLIC_ED_KEY: $(tail -1 "$tmp/out.txt"); gh calls $before -> $(gh_calls)"
fi
expect 0 "the first Windows feed joins the published feed release" publish_os windows "$tmp/good-other-key.xml"
if cmp -s "$STUB_ASSETS/$(asset_named appcast-windows.xml)" "$tmp/good-other-key.xml" && mac_untouched &&
  [ -z "$(asset_named appcast-windows.previous.xml)" ] && [ "$(ls "$STUB_ASSETS" | wc -l | tr -d ' ')" = 2 ]; then
  pass "appcast-windows.xml is live beside the Mac's appcast.xml, which is untouched"
else
  fail "after the first Windows feed the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
first_windows="$(asset_named appcast-windows.xml)"
sed 's#desktop-v1.3.0#desktop-v1.3.1#' "$tmp/good-unsigned.xml" >"$tmp/next-unsigned.xml"
sign_feed "$tmp/next-unsigned.xml" "$tmp/next-other-key.xml" "$tmp/key-b.der"
expect 0 "the next Windows feed replaces it" publish_os windows "$tmp/next-other-key.xml"
if [ "$(asset_named appcast-windows.previous.xml)" = "${first_windows%% *} appcast-windows.previous.xml" ] &&
  cmp -s "$STUB_ASSETS/$(asset_named appcast-windows.xml)" "$tmp/next-other-key.xml" && mac_untouched; then
  pass "the last Windows feed is kept as appcast-windows.previous.xml, and the Mac's files are untouched"
else
  fail "after the next Windows feed the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
expect 0 "a Linux feed signed with LINUX_PUBLIC_ED_KEY is published as appcast-linux.xml" \
  publish_os linux "$tmp/good-key-c.xml"
cmp -s "$STUB_ASSETS/$(asset_named appcast-linux.xml)" "$tmp/good-key-c.xml" && mac_untouched &&
  pass "appcast-linux.xml is live, the Mac's untouched" ||
  fail "after the Linux feed the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
feed_release "7 appcast.xml" "9 appcast-windows.previous.xml"
expect 1 "appcast-windows.previous.xml without appcast-windows.xml stops publishing" \
  publish_os windows "$tmp/good-other-key.xml"
[ "$(ls "$STUB_ASSETS" | tr '\n' ' ')" = "7 appcast.xml 9 appcast-windows.previous.xml " ] &&
  pass "a half-stopped Windows publication is left for a person to put back" ||
  fail "after a half-stopped Windows publication the files are: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
feed_release
echo draft >"$STUB_STATE"
expect 1 "a Windows feed never makes the feed release (the Mac's publication does)" \
  publish_os windows "$tmp/good-other-key.xml"
if [ "$(cat "$STUB_STATE")" = draft ] && [ -z "$(ls "$STUB_ASSETS")" ]; then
  pass "the draft feed release stays as it was, with nothing uploaded"
else
  fail "a Windows feed on a draft feed release left it $(cat "$STUB_STATE") with: $(ls "$STUB_ASSETS" | tr '\n' ' ')"
fi
expect 1 "an unknown OS is refused" publish_os beos "$tmp/good.xml"
feed_release "7 appcast.xml"
before="$(gh_calls)"
expect 0 "without --push it only says what it would do" \
  env APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$tmp/good-other-key.xml" --os windows
grep -q 'appcast-windows.xml' "$tmp/out.txt" && [ "$(gh_calls)" = "$before" ] &&
  pass "and it names appcast-windows.xml, with no call to GitHub" || fail "a Windows dry publication: $(cat "$tmp/out.txt")"

# A re-run of the feed job after a publication that stopped part way (the
# Mac's feed live, Windows' not yet): a feed that is already live, byte for
# byte, is left as it is, its last copy kept, and the rest go on.
already_live() { # label name feed [publish-appcast.sh args...]
  local label="$1" name="$2" xml="$3" base="${2%.xml}"
  shift 3
  feed_release
  [ "$name" = appcast.xml ] || cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
  cp "$xml" "$STUB_ASSETS/11 $name"
  printf '<rss/>older\n' >"$STUB_ASSETS/12 $base.previous.xml"
  local files uploads
  files="$(ls "$STUB_ASSETS" | tr '\n' ' ')"
  uploads="$(grep -c '^gh release upload' "$STUB_LOG")"
  expect 0 "$label" env APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$xml" --push "$@"
  if [ "$(ls "$STUB_ASSETS" | tr '\n' ' ')" = "$files" ] && cmp -s "$STUB_ASSETS/11 $name" "$xml" &&
    grep -qx '<rss/>older' "$STUB_ASSETS/12 $base.previous.xml" && grep -q 'already live' "$tmp/out.txt" &&
    [ "$(grep -c '^gh release upload' "$STUB_LOG")" = "$uploads" ]; then
    pass "$label: nothing uploaded or renamed, the last copy kept"
  else
    fail "$label: files $(ls "$STUB_ASSETS" | tr '\n' ' '); $(tail -1 "$tmp/out.txt")"
  fi
}
already_live "the Mac's feed already live is left as it is" appcast.xml "$tmp/good.xml"
already_live "a Windows feed already live is left as it is" appcast-windows.xml "$tmp/good-other-key.xml" --os windows
# A live feed that cannot be read back stops the run, nothing changed:
# replacing it then could set an identical copy aside over the last one.
read_back_fails() { # label name feed [publish-appcast.sh args...]
  local label="$1" name="$2" xml="$3" base="${2%.xml}"
  shift 3
  feed_release
  [ "$name" = appcast.xml ] || cp "$tmp/live.xml" "$STUB_ASSETS/7 appcast.xml"
  cp "$xml" "$STUB_ASSETS/11 $name"
  printf '<rss/>older\n' >"$STUB_ASSETS/12 $base.previous.xml"
  local files uploads
  files="$(ls "$STUB_ASSETS" | tr '\n' ' ')"
  uploads="$(grep -c '^gh release upload' "$STUB_LOG")"
  expect 1 "$label" env STUB_DOWNLOAD=fail APPCAST_HOSTING=release-asset "$here/publish-appcast.sh" "$xml" --push "$@"
  if [ "$(ls "$STUB_ASSETS" | tr '\n' ' ')" = "$files" ] && grep -qx '<rss/>older' "$STUB_ASSETS/12 $base.previous.xml" &&
    grep -q "could not read back the live $name" "$tmp/out.txt" &&
    [ "$(grep -c '^gh release upload' "$STUB_LOG")" = "$uploads" ]; then
    pass "$label: nothing uploaded or renamed, the last copy kept"
  else
    fail "$label: files $(ls "$STUB_ASSETS" | tr '\n' ' '); $(tail -1 "$tmp/out.txt")"
  fi
}
read_back_fails "a live Mac feed that cannot be read back stops the run" appcast.xml "$tmp/good.xml"
read_back_fails "a live Windows feed that cannot be read back stops the run" appcast-windows.xml "$tmp/good-other-key.xml" --os windows

# winlinux_feed_state: what the release workflow adds an OS's release to.
# `live` once its feed is published, `new` for its first release; it stops
# when it cannot tell, and on a publication that stopped half way.
feed_state_of() { # want label os [env...]
  local want="$1" label="$2" os="$3" got rc
  shift 3
  got="$(env "$@" bash -c ". '$here/lib.sh'; APPCAST_HOSTING=release-asset; winlinux_feed_state \"\$1\"" _ "$os" 2>"$tmp/out.txt")"
  rc=$?
  if { [ "$want" = stop ] && [ "$rc" != 0 ] && [ -z "$got" ]; } ||
    { [ "$want" != stop ] && [ "$rc" = 0 ] && [ "$got" = "$want" ]; }; then
    pass "$label"
  else
    fail "$label (got '$got', exit $rc)"
    sed 's/^/      /' "$tmp/out.txt"
  fi
}
feed_release "7 appcast.xml"
feed_state_of new "Windows' first release: the feed release has no appcast-windows.xml yet" windows
feed_release "7 appcast.xml" "11 appcast-windows.xml"
feed_state_of live "a published appcast-windows.xml is Windows' live feed" windows
feed_state_of new "Linux's first release, beside a live Windows feed" linux
feed_release "7 appcast.xml" "12 appcast-linux.previous.xml"
feed_state_of stop "appcast-linux.previous.xml without appcast-linux.xml is never a first release" linux
grep -q 'appcast-linux.previous.xml' "$tmp/out.txt" && pass "and the stop says why" ||
  fail "a half-stopped Linux feed's stop said: $(cat "$tmp/out.txt")"
feed_state_of new "no feed release at all is a first release" windows STUB_LOOKUP=404
feed_state_of stop "a feed release that cannot be read stops" windows STUB_LOOKUP=500
feed_state_of stop "an OS that has no feed stops" macos

# feed_signing_key: the key the published Windows or Linux feed is signed
# with, which winlinux-appcast.sh checks it with before adding to it.
signing_key() { # want label feed current retired
  local want="$1" label="$2" got rc
  shift 2
  got="$(bash -c ". '$here/lib.sh'; feed_signing_key \"\$1\" windows \"\$2\" \"\$3\"" _ "$@" 2>"$tmp/out.txt")"
  rc=$?
  if { [ "$want" = stop ] && [ "$rc" != 0 ] && [ -z "$got" ]; } ||
    { [ "$want" != stop ] && [ "$rc" = 0 ] && [ "$got" = "$want" ]; }; then
    pass "$label"
  else
    fail "$label (got '$got', exit $rc)"
    sed 's/^/      /' "$tmp/out.txt"
  fi
}
signing_key "$key_a" "a feed signed with the current key is added to with it" "$tmp/good.xml" "$key_a" ""
signing_key "$key_b" "the first release after a key swap reads the feed with the retired key" \
  "$tmp/good-other-key.xml" "$key_a" "$key_b"
signing_key stop "a feed the current key didn't sign, with no retired key, stops" "$tmp/good-other-key.xml" "$key_a" ""
grep -q 'WINDOWS_RETIRED_PUBLIC_ED_KEY' "$tmp/out.txt" && pass "and the stop names WINDOWS_RETIRED_PUBLIC_ED_KEY" ||
  fail "a feed signed with another key said: $(cat "$tmp/out.txt")"
signing_key stop "a retired key left set once the feed is signed with the current key stops" \
  "$tmp/good.xml" "$key_a" "$key_b"
grep -q 'left over' "$tmp/out.txt" && pass "and the stop says it is left over" ||
  fail "a left-over retired key said: $(cat "$tmp/out.txt")"
signing_key stop "a feed signed with neither key stops" "$tmp/good-key-c.xml" "$key_a" "$key_b"
signing_key stop "a retired key that is not a key stops" "$tmp/good-other-key.xml" "$key_a" "not-a-key"
signing_key stop "a retired key that is the current key stops" "$tmp/good.xml" "$key_a" "$key_a"
signing_key stop "an unsigned feed stops" "$tmp/good-unsigned.xml" "$key_a" "$key_b"

# ── the test harness and the bundle in --out ────────────────────────────────
# A binary built with the `harness` feature carries lib.rs's HARNESS_MARKER;
# it is never signed for distribution, whatever the flags. Synthetic
# binaries: one with the marker among other bytes, one without.
printf 'MZ\0\0 code bytes conduit-desktop: test harness build \0\1\2' >"$tmp/harness-bin"
printf 'MZ\0\0 code bytes conduit-desktop \0\1\2' >"$tmp/release-bin"
harness() { bash -c ". '$here/lib.sh'; refuse_harness_distribution \"\$@\"" _ "$@"; }
expect 1 "a harness binary is refused for distribution signing" harness "$tmp/harness-bin" distribution
expect 0 "a harness binary may be signed with Apple Development" harness "$tmp/harness-bin" development
expect 0 "a harness binary may be signed ad hoc" harness "$tmp/harness-bin" adhoc
expect 0 "a binary without the harness may be signed for distribution" harness "$tmp/release-bin" distribution
expect 1 "a missing binary is refused" harness "$tmp/no-such-bin" distribution
debug_ents() { bash -c ". '$here/lib.sh'; refuse_debug_entitlements \"\$@\"" _ "$@"; }
grants() { bash -c ". '$here/lib.sh'; grants_debugger \"\$1\"" _ "$1"; }
if [ -x /usr/bin/plutil ] && [ -x /usr/libexec/PlistBuddy ]; then
  for f in Conduit.entitlements conduitd.entitlements widget/ConduitWidget.entitlements \
    share/Share.entitlements; do
    expect 0 "release entitlements $f grant no debugger" debug_ents "$here/$f"
  done
  ents() { # file body: an entitlements plist around body
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' '<dict>' "$2" '</dict>' '</plist>' >"$1"
  }
  ents "$tmp/ent-true" '<key>com.apple.security.get-task-allow</key><true/>'
  ents "$tmp/ent-false" '<key>com.apple.security.get-task-allow</key><false/>'
  ents "$tmp/ent-comment" '<!-- com.apple.security.get-task-allow --><key>com.apple.security.app-sandbox</key><true/>'
  ents "$tmp/ent-escaped" '<key>com.apple.security.get&#45;task&#45;allow</key><true/>'
  ents "$tmp/ent-none" '<key>com.apple.security.app-sandbox</key><true/>'
  printf 'not a property list\n' >"$tmp/ent-broken"
  expect 1 "entitlements granting get-task-allow are refused" debug_ents "$tmp/ent-true"
  expect 0 "get-task-allow set false is not refused" debug_ents "$tmp/ent-false"
  expect 0 "get-task-allow named only in a comment is not refused" debug_ents "$tmp/ent-comment"
  expect 1 "an XML-escaped get-task-allow set true is refused" debug_ents "$tmp/ent-escaped"
  expect 0 "entitlements without get-task-allow are not refused" debug_ents "$tmp/ent-none"
  expect 1 "entitlements that are no property list are refused" debug_ents "$tmp/ent-broken"
  bash -c ". '$here/lib.sh'; dev_entitlements \"\$1\" \"\$2\"" _ \
    "$here/Conduit.entitlements" "$tmp/dev.entitlements"
  expect 0 "sign-dev.sh's dev copy sets get-task-allow to Boolean true" grants "$tmp/dev.entitlements"
  expect 1 "a dev copy is refused where a release signs" debug_ents "$tmp/dev.entitlements"
else
  echo "skip  entitlements checks (no plutil or PlistBuddy here)"
fi
if command -v plutil >/dev/null; then
  app_with() { # app id [version] [LSEnvironment]
    mkdir -p "$1/Contents"
    plutil -create xml1 "$1/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string "${3:-1.3.0}" "$1/Contents/Info.plist"
    [ -z "${4:-}" ] || plutil -insert LSEnvironment -dictionary "$1/Contents/Info.plist"
  }
  bundle() { bash -c ". '$here/lib.sh'; check_bundle \"\$@\"" _ "$@"; }
  app_with "$tmp/release.app" app.cogwheel.conduit.desktop
  app_with "$tmp/test.app" app.cogwheel.conduit.desktop.mytest 1.3.0 env
  expect 1 "a rehearsal never re-signs a release app as a test bundle" \
    bundle "$tmp/release.app" app.cogwheel.conduit.desktop.mytest 0 1.3.0
  expect 0 "a rehearsal takes its own test bundle" \
    bundle "$tmp/test.app" app.cogwheel.conduit.desktop.mytest 0 1.3.0
  expect 1 "a release step never takes a test bundle" \
    bundle "$tmp/test.app" app.cogwheel.conduit.desktop 1 1.3.0
  expect 0 "a release step takes the release build" \
    bundle "$tmp/release.app" app.cogwheel.conduit.desktop 1 1.3.0
  expect 1 "a release step refuses another version" \
    bundle "$tmp/release.app" app.cogwheel.conduit.desktop 1 1.4.0
  app_with "$tmp/release-env.app" app.cogwheel.conduit.desktop 1.3.0 env
  expect 1 "a release step refuses a release build with a test environment" \
    bundle "$tmp/release-env.app" app.cogwheel.conduit.desktop 1 1.3.0
else
  echo "skip  check_bundle (no plutil here)"
fi

# ── the openssl the scripts use ─────────────────────────────────────────────
# A stand-in for OpenSSL 1.1.1: it makes Ed25519 keys but cannot sign or
# verify raw input. It is never the one chosen.
cat >"$tmp/openssl-111" <<'STUB'
#!/bin/bash
case "$1" in genpkey) exit 0 ;; *) exit 1 ;; esac
STUB
chmod +x "$tmp/openssl-111"
if chosen="$(OPENSSL="$tmp/openssl-111" bash -c ". '$here/lib.sh'; ed25519_openssl" 2>/dev/null)"; then
  [ "$chosen" != "$tmp/openssl-111" ] && pass "an openssl that cannot sign raw Ed25519 is passed over" ||
    fail "an openssl that cannot sign raw Ed25519 was chosen"
else
  if OPENSSL="$tmp/openssl-111" bash -c ". '$here/lib.sh'; ed25519_openssl" 2>&1 | grep -q 'Ed25519 signing'; then
    pass "with no openssl that signs raw Ed25519 here, it says so"
  else
    fail "ed25519_openssl failed without saying why"
  fi
fi

# ── verify_enclosure ────────────────────────────────────────────────────────
"$openssl_path" pkeyutl -sign -inkey "$tmp/key-a.der" -keyform DER -rawin -in "$dmg" \
  -out "$tmp/dmg.sig"
signed="$(base64 <"$tmp/dmg.sig" | tr -d '\n')"
feed "$tmp/signed.xml" "$(item 1030099 1.3.0 "$url" "$size" "$signed" "")" "$old_item"
enclosure() { bash -c ". '$here/lib.sh'; verify_enclosure \"\$@\"" _ "$@"; }
expect 0 "the DMG its signed enclosure describes is accepted" \
  enclosure "$tmp/signed.xml" 1030099 "$dmg" "$key_a"
printf 'swapped dmg bytes!!' >"$tmp/swapped.dmg"
expect 1 "another DMG of the same length is refused" \
  enclosure "$tmp/signed.xml" 1030099 "$tmp/swapped.dmg" "$key_a"
printf 'synthetic dmg bytes, longer' >"$tmp/longer.dmg"
expect 1 "a DMG of another length is refused" \
  enclosure "$tmp/signed.xml" 1030099 "$tmp/longer.dmg" "$key_a"
expect 1 "a signature made with another key is refused" \
  enclosure "$tmp/signed.xml" 1030099 "$dmg" "$key_b"
expect 1 "no public key refuses" enclosure "$tmp/signed.xml" 1030099 "$dmg" ""
# mktemp fails for the enclosure's scratch folder only (openssl's probe
# still works): verification fails, and writes nothing where it runs.
mkdir -p "$tmp/no-scratch-bin" "$tmp/no-scratch-cwd"
cat >"$tmp/no-scratch-bin/mktemp" <<'STUB'
#!/bin/bash
case "$*" in *conduit-enclosure*) echo "mktemp: cannot create" >&2; exit 1 ;; esac
exec /usr/bin/mktemp "$@"
STUB
chmod +x "$tmp/no-scratch-bin/mktemp"
expect 1 "an enclosure check whose scratch folder cannot be made fails" \
  env PATH="$tmp/no-scratch-bin:$PATH" bash -c "cd '$tmp/no-scratch-cwd' && . '$here/lib.sh' && verify_enclosure \"\$@\"" _ \
  "$tmp/signed.xml" 1030099 "$dmg" "$key_a"
if [ -z "$(ls "$tmp/no-scratch-cwd")" ]; then
  pass "a failed scratch folder writes nothing where the check runs"
else
  fail "a failed scratch folder wrote: $(ls "$tmp/no-scratch-cwd" | tr '\n' ' ')"
fi

# ── verify_feed, against the pinned Sparkle ─────────────────────────────────
# Sparkle's tools are macOS binaries. sign_update --verify gives Sparkle's
# own verdict, but needs the private key, which the feed job never has:
# verify_feed must agree with it on every feed here.
if [ "$(uname -s)" = Darwin ]; then
  if sparkle="$(bash -c ". '$here/lib.sh'; sparkle_dir")"; then
    sparkle_sign() { # feed key.der: sign_update signs FEED in place
      private_of "$2" | "$sparkle/bin/sign_update" --ed-key-file - "$1" >/dev/null
    }
    agree() { # want label feed: verify_feed with key a, and Sparkle with key a
      expect "$1" "$2 (verify_feed)" feed_check "$3" "$key_a"
      expect "$1" "$2 (Sparkle's sign_update --verify)" \
        bash -c "printf '%s' \"\$1\" | '$sparkle/bin/sign_update' --verify --ed-key-file - \"\$2\"" _ \
        "$(private_of "$tmp/key-a.der")" "$3"
    }
    cp "$tmp/good-unsigned.xml" "$tmp/sparkle-signed.xml"
    sparkle_sign "$tmp/sparkle-signed.xml" "$tmp/key-a.der"
    agree 0 "a feed sign_update signed with the trusted key is accepted" "$tmp/sparkle-signed.xml"
    sed 's#desktop-v1.3.0#desktop-v6.6.6#' "$tmp/sparkle-signed.xml" >"$tmp/sparkle-changed.xml"
    agree 1 "a feed sign_update signed, then changed, is refused" "$tmp/sparkle-changed.xml"
    cp "$tmp/good-unsigned.xml" "$tmp/sparkle-other-key.xml"
    sparkle_sign "$tmp/sparkle-other-key.xml" "$tmp/key-b.der"
    agree 1 "a feed sign_update signed with another key is refused" "$tmp/sparkle-other-key.xml"
    agree 1 "an unsigned feed is refused" "$tmp/good-unsigned.xml"
    # Sparkle reads the last signature block: one appended by another key
    # over a signed feed is the one checked.
    sign_feed "$tmp/sparkle-signed.xml" "$tmp/sparkle-appended.xml" "$tmp/key-b.der"
    agree 1 "a second signature block by another key is refused" "$tmp/sparkle-appended.xml"
    # The fixture publish-appcast.sh is tested with: signed here as Sparkle
    # signs a feed, and Sparkle agrees.
    agree 0 "a feed signed here in Sparkle's format is accepted" "$tmp/good.xml"
    expect 1 "verify_feed without a public key refuses" feed_check "$tmp/sparkle-signed.xml" ""
  else
    fail "the pinned Sparkle could not be fetched (lib.sh sparkle_dir)"
    sparkle=""
  fi
else
  echo "skip  verify_feed against Sparkle and appcast.sh (Sparkle's tools need macOS)"
  sparkle=""
fi

# ── appcast.sh, with generate_appcast: a release and a key rotation ─────────
# Synthetic apps, signed ad hoc (generate_appcast refuses a bundle whose
# signature does not verify), in DMGs made here. Key a is the current key,
# b the next one, c neither.
if [ -n "$sparkle" ]; then
  macos_min="$(bash -c ". '$here/lib.sh'; printf '%s' \"\$MACOS_MIN\"")"
  printf 'int main(void) { return 0; }\n' |
    xcrun clang -arch arm64 -mmacosx-version-min="$macos_min" -x c - -o "$tmp/stub-executable"
  dmg_with() { # dmg key version
    local src app
    src="$(mktemp -d "$tmp/app.XXXXXX")" && app="$src/Conduit.app" || return 1
    mkdir -p "$app/Contents/MacOS" "$(dirname "$1")"
    cp "$tmp/stub-executable" "$app/Contents/MacOS/Conduit"
    plutil -create xml1 "$app/Contents/Info.plist"
    local kv
    for kv in CFBundleIdentifier=app.example.release-test CFBundleExecutable=Conduit \
      CFBundlePackageType=APPL "CFBundleShortVersionString=$3" \
      "CFBundleVersion=$(bash -c ". '$here/lib.sh'; build_number $3")" \
      "LSMinimumSystemVersion=$macos_min" "SUPublicEDKey=$2"; do
      plutil -insert "${kv%%=*}" -string "${kv#*=}" "$app/Contents/Info.plist"
    done
    plutil -insert SURequireSignedFeed -bool true "$app/Contents/Info.plist"
    codesign --force --sign - "$app" 2>/dev/null || return 1
    # As in bundle.sh: hdiutil sometimes fails with "Resource busy" on a
    # hosted CI runner, and a later try succeeds.
    local try
    for try in 1 2 3; do
      hdiutil create -quiet -ov -srcfolder "$src" -format UDZO -volname Conduit "$1" && return 0
      sleep 5
    done
    return 1
  }
  dmg_with "$tmp/release/Conduit-1.3.0.dmg" "$key_a" 1.3.0 || fail "could not make the release's DMG"
  dmg_with "$tmp/bridge/Conduit-1.3.0.dmg" "$key_b" 1.3.0 || fail "could not make the bridge's DMG"
  dmg_with "$tmp/after/Conduit-1.4.0.dmg" "$key_b" 1.4.0 || fail "could not make the next release's DMG"
  appcast() { # private-key.der public-key work dmg version [appcast.sh options]
    local der="$1" public="$2" work="$3" dmg_file="$4" version="$5" rc
    shift 5
    local run=("$here/appcast.sh" --dmg "$dmg_file" --version "$version"
      --download-url-prefix https://example.org/releases/ --work "$work" "$@")
    SPARKLE_ED_PRIVATE_KEY="$(private_of "$der")" SPARKLE_PUBLIC_ED_KEY="$public" "${run[@]}"
    rc=$?
    [ "$rc" = 0 ] || printf 'appcast.sh exited %s: SPARKLE_PUBLIC_ED_KEY=%s%s\n' \
      "$rc" "$public" "$(printf ' %q' "${run[@]}")" >&2
    return "$rc"
  }
  expect 0 "a release whose app carries the signing key goes through generate_appcast" \
    appcast "$tmp/key-a.der" "$key_a" "$tmp/feed-release" "$tmp/release/Conduit-1.3.0.dmg" 1.3.0 --fresh
  expect 0 "its feed passes verify_feed with that key" feed_check "$tmp/feed-release/appcast.xml" "$key_a"
  expect 1 "and not with another key" feed_check "$tmp/feed-release/appcast.xml" "$key_b"
  expect 1 "an app built for the next key is refused without --next-public-key" \
    appcast "$tmp/key-a.der" "$key_a" "$tmp/feed-unasked" "$tmp/bridge/Conduit-1.3.0.dmg" 1.3.0 --fresh
  expect 1 "--next-public-key naming another key than the app's is refused" \
    appcast "$tmp/key-a.der" "$key_a" "$tmp/feed-wrong-next" "$tmp/bridge/Conduit-1.3.0.dmg" 1.3.0 --fresh \
    --next-public-key "$key_c"
  expect 1 "--next-public-key naming the signing key itself is refused" \
    appcast "$tmp/key-a.der" "$key_a" "$tmp/feed-same" "$tmp/release/Conduit-1.3.0.dmg" 1.3.0 --fresh \
    --next-public-key "$key_a"
  expect 1 "--next-public-key without SPARKLE_PUBLIC_ED_KEY is refused" \
    appcast "$tmp/key-a.der" "" "$tmp/feed-no-public" "$tmp/bridge/Conduit-1.3.0.dmg" 1.3.0 --fresh \
    --next-public-key "$key_b"
  expect 1 "--next-public-key that is not a key is refused" \
    appcast "$tmp/key-a.der" "$key_a" "$tmp/feed-not-key" "$tmp/bridge/Conduit-1.3.0.dmg" 1.3.0 --fresh \
    --next-public-key not-a-key
  expect 0 "a bridge release (its app carries the next key) goes through with --next-public-key" \
    appcast "$tmp/key-a.der" "$key_a" "$tmp/feed-bridge" "$tmp/bridge/Conduit-1.3.0.dmg" 1.3.0 --fresh \
    --next-public-key "$key_b"
  expect 0 "the bridge's update is signed with the current key" \
    enclosure "$tmp/feed-bridge/appcast.xml" 1030099 "$tmp/bridge/Conduit-1.3.0.dmg" "$key_a"
  expect 0 "the bridge's feed is signed with the current key" \
    feed_check "$tmp/feed-bridge/appcast.xml" "$key_a"
  expect 1 "and not with the next key" feed_check "$tmp/feed-bridge/appcast.xml" "$key_b"
  # The rotation done: the next key signs, and the feed keeps the bridge.
  expect 0 "the release after the bridge, signed with the next key, keeps the bridge's item" \
    appcast "$tmp/key-b.der" "$key_b" "$tmp/feed-after" "$tmp/after/Conduit-1.4.0.dmg" 1.4.0 \
    --existing "$tmp/feed-bridge/appcast.xml"
  expect 0 "its feed is signed with the next key" feed_check "$tmp/feed-after/appcast.xml" "$key_b"
  expect 1 "and not with the old one" feed_check "$tmp/feed-after/appcast.xml" "$key_a"

  # On a hosted runner hdiutil now and then fails to attach an image, or to
  # detach one a system service still reads; a later try, or -force,
  # succeeds. A stub hdiutil fails as the real one does (with -quiet it
  # says nothing) and otherwise runs it. Its `sleep` skips the wait.
  mkdir -p "$tmp/busy-bin"
  cat >"$tmp/busy-bin/hdiutil" <<'STUB'
#!/bin/bash
# STUB_ATTACH_FAILS=N: the first N attaches fail. STUB_DETACH=busy: a
# detach without -force fails, the volume busy. STUB_DETACH=stuck: every
# detach fails, -force or not (the volume is still let go, so the test
# leaves nothing mounted).
quiet() { case " $* " in *" -quiet "*) exec >/dev/null 2>&1 ;; esac; }
case "$1" in
  attach)
    n=$(($(cat "$STUB_ATTACHES" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STUB_ATTACHES"
    if [ "$n" -le "${STUB_ATTACH_FAILS:-0}" ]; then
      quiet "$@"
      echo "hdiutil: attach failed - Resource temporarily unavailable" >&2
      exit 1
    fi
    ;;
  detach)
    if [ "${STUB_DETACH:-}" = stuck ]; then
      /usr/bin/hdiutil detach -force "${@: -1}" >/dev/null 2>&1 || true
      quiet "$@"
      echo 'hdiutil: couldn'\''t unmount "disk9" - Resource busy' >&2
      exit 16
    fi
    if [ "${STUB_DETACH:-}" = busy ] && [[ " $* " != *" -force "* ]]; then
      quiet "$@"
      echo 'hdiutil: couldn'\''t unmount "disk9" - Resource busy' >&2
      exit 16
    fi
    ;;
esac
exec /usr/bin/hdiutil "$@"
STUB
  printf '#!/bin/bash\nexit 0\n' >"$tmp/busy-bin/sleep"
  chmod +x "$tmp/busy-bin/hdiutil" "$tmp/busy-bin/sleep"
  busy() { # work [VAR=value...]: the release through appcast.sh, with the stub hdiutil
    local work="$1"
    shift
    (
      export PATH="$tmp/busy-bin:$PATH" STUB_ATTACHES="$work.attaches" "$@"
      appcast "$tmp/key-a.der" "$key_a" "$work" "$tmp/release/Conduit-1.3.0.dmg" 1.3.0 --fresh
    )
  }
  expect 0 "an attach that fails once, as on a busy runner, is tried again" \
    busy "$tmp/feed-attach-once" STUB_ATTACH_FAILS=1
  expect 0 "and that release's feed passes verify_feed" \
    feed_check "$tmp/feed-attach-once/appcast.xml" "$key_a"
  expect 1 "an attach that keeps failing stops the release" \
    busy "$tmp/feed-attach-fails" STUB_ATTACH_FAILS=99
  if grep -q 'Resource temporarily unavailable' "$tmp/out.txt"; then
    pass "and says what hdiutil said"
  else
    fail "an attach that keeps failing stopped without hdiutil's message"
    sed 's/^/      /' "$tmp/out.txt"
  fi
  expect 0 "a volume still busy when it is detached does not stop the release" \
    busy "$tmp/feed-detach-busy" STUB_DETACH=busy
  expect 0 "and that release's feed passes verify_feed" \
    feed_check "$tmp/feed-detach-busy/appcast.xml" "$key_a"
  expect 0 "a volume that won't detach even with -force only warns" \
    busy "$tmp/feed-detach-stuck" STUB_DETACH=stuck
  if grep -q 'could not detach' "$tmp/out.txt" && grep -q 'Resource busy' "$tmp/out.txt"; then
    pass "and the warning says what hdiutil said"
  else
    fail "a detach that failed with -force gave no warning with hdiutil's message"
    sed 's/^/      /' "$tmp/out.txt"
  fi
  expect 0 "and that release's feed passes verify_feed" \
    feed_check "$tmp/feed-detach-stuck/appcast.xml" "$key_a"
fi

echo
if [ "$failures" = 0 ]; then
  echo "release_test: all checks passed"
else
  echo "release_test: $failures failed"
  exit 1
fi
