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
# * a rename or delete GitHub applied whose reply was lost is judged by the
#   file's real state, so the publication completes or is put back.
# * a binary built with the test harness is never signed for distribution,
#   and a step takes only the bundle id it was asked for.
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
# files live in $STUB_ASSETS (one file per asset, named "<id> <name>"); the
# feed release's state (none, draft, published) is in $STUB_STATE (no file:
# published). STUB_UPLOAD, STUB_PUBLISH=fail and STUB_DOWNLOAD=other make
# those steps fail or read back other bytes.
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
    "$tmp/signed.xml" 1030099 "$dmg" "$key"
  if [ -z "$(ls "$tmp/no-scratch-cwd")" ]; then
    pass "a failed scratch folder writes nothing where the check runs"
  else
    fail "a failed scratch folder wrote: $(ls "$tmp/no-scratch-cwd" | tr '\n' ' ')"
  fi
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
