#!/bin/bash
# Checks the Windows and Linux update feeds' scripts (winlinux_feed.py,
# winlinux-appcast.sh) against synthetic installers and keys made here: no
# real release, no real key, no network (every feed starts from a file or
# --fresh). Signatures are judged by lib.sh's verify_feed and
# verify_enclosure, the checks release_test.sh holds to Sparkle's own
# verdict, so a feed these scripts make is one the Mac's checks accept. It
# needs an openssl that does Ed25519, as the release does.
#
#   desktop/packaging/winlinux_feed_test.sh
#
# * A Windows release: the item is the installer (its length, URL,
#   windows-x64, WinSparkle's installer arguments) signed with the key,
#   and the feed is signed; the next release keeps the first item, puts its
#   own on top, and the feed has one signature block, the new one.
# * A Linux release: the item names the release page and nothing to
#   download; the next one keeps it.
# * Refused by verify_feed: a feed changed after it was signed, one signed
#   with another key, an unsigned one. Refused by verify_enclosure: another
#   installer, another key.
# * Refused by winlinux-appcast.sh before anything is written: a private
#   key that isn't <OS>_PUBLIC_ED_KEY's, no key, a beta, a version not newer
#   than the feed's newest or already in it, a Windows release without its
#   installer or with another version's, a Linux release with one.
# * A key rotation's bridge release: --next-public-key signs with the
#   current key and needs <OS>_PUBLIC_ED_KEY; the same key, or no key, is
#   refused.
# * winlinux_feed.py check refuses a feed that drops an earlier item or
#   changes one (its enclosure, its signature), an unsigned enclosure, the
#   wrong length, an item on a channel, two signature blocks.
# * winlinux-appcast.sh refuses a feed or an installer inside --work, which
#   it moves aside first, and moves nothing.
# * It adds a release only to a feed signed with the key that signs this
#   release, or the one --feed-public-key names (the release after a key
#   swap): a feed changed after it was signed, unsigned, or signed with
#   another key is refused. So is a feed with an <item> outside its
#   <channel>, which the apps never read, and check refuses one too.
# * Sparkle's own sign_update accepts the signatures these scripts make, and
#   refuses a changed feed (macOS).
# * The fixture the Linux app's tests read (crates/app/src/updates/
#   fixtures) passes verify_feed with its public key: the app's verifier
#   and lib.sh's agree on one file.
# * winlinux_feed.py url names each feed beside the Mac's appcast.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed-test.XXXXXX")"
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
# The last command's output says $2 (a refusal for the right reason).
says() {
  if grep -qF -- "$2" "$tmp/out.txt"; then pass "$1"; else fail "$1 (no '$2')"; sed 's/^/      /' "$tmp/out.txt"; fi
}

openssl_path="$(bash -c ". '$here/macos/lib.sh'; ed25519_openssl")" || {
  echo "winlinux_feed_test: needs an openssl that does Ed25519, as the release does (brew install openssl@3, or set OPENSSL)"
  exit 1
}
export OPENSSL="$openssl_path"
for k in a b; do
  "$openssl_path" genpkey -algorithm ed25519 -outform DER -out "$tmp/key-$k.der" 2>/dev/null
done
public_of() { "$openssl_path" pkey -inform DER -in "$1" -pubout -outform DER | tail -c 32 | base64; }
private_of() { tail -c 32 "$1" | base64; } # the seed, as generate_keys -x exports it
key_a="$(public_of "$tmp/key-a.der")"
key_b="$(public_of "$tmp/key-b.der")"
feed_check() { bash -c ". '$here/macos/lib.sh'; verify_feed \"\$@\"" _ "$@"; }
sign_feed() { # unsigned signed key.der: appends the block Sparkle's signAppcast writes
  "$openssl_path" pkeyutl -sign -inkey "$3" -keyform DER -rawin -in "$1" -out "$tmp/feed.sig" || return 1
  {
    cat "$1"
    printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' \
      "$(base64 <"$tmp/feed.sig" | tr -d '\n')" "$(wc -c <"$1" | tr -d ' ')"
  } >"$2"
}
enclosure() { bash -c ". '$here/macos/lib.sh'; verify_enclosure \"\$@\"" _ "$@"; }
appcast() { "$here/winlinux-appcast.sh" "$@"; }
feed_py() { python3 -I "$here/winlinux_feed.py" "$@"; }
items_of() { # feed: "short build" a line
  python3 -I - "$1" <<'EOF'
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
data = open(sys.argv[1], "rb").read()
for item in ET.fromstring(data[: data.rfind(b"<!-- sparkle-signatures:")]).iter("item"):
    print(item.findtext(S + "shortVersionString"), item.findtext(S + "version"))
EOF
}

export WINDOWS_ED_PRIVATE_KEY LINUX_ED_PRIVATE_KEY WINDOWS_PUBLIC_ED_KEY LINUX_PUBLIC_ED_KEY
WINDOWS_ED_PRIVATE_KEY="$(private_of "$tmp/key-a.der")"
WINDOWS_PUBLIC_ED_KEY="$key_a"
LINUX_ED_PRIVATE_KEY="$(private_of "$tmp/key-a.der")"
LINUX_PUBLIC_ED_KEY="$key_a"
installer() { # version: a synthetic installer of that version, made once
  local f="$tmp/dist/Conduit-$1-windows-x64-setup.exe"
  mkdir -p "$tmp/dist"
  [ -f "$f" ] || printf 'synthetic installer %s' "$1" >"$f"
  printf '%s\n' "$f"
}

# ── Windows ───────────────────────────────────────────────────────────────────
expect 0 "a first Windows release makes a new feed" \
  appcast --os windows --version 1.3.0 --installer "$(installer 1.3.0)" --fresh --work "$tmp/w1"
w1="$tmp/w1/appcast-windows.xml"
expect 0 "its feed passes verify_feed with the key" feed_check "$w1" "$key_a"
expect 0 "its item is the installer, signed with the key (verify_enclosure)" \
  enclosure "$w1" 1030099 "$(installer 1.3.0)" "$key_a"
expect 0 "its enclosure is for windows-x64 with WinSparkle's installer arguments" \
  grep -q 'sparkle:os="windows-x64" sparkle:installerArguments="/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1"' "$w1"
expect 0 "its enclosure is at the version's GitHub release" \
  grep -q 'url="https://github.com/[^"]*/releases/download/desktop-v1.3.0/Conduit-1.3.0-windows-x64-setup.exe"' "$w1"
expect 0 "the next Windows release starts from the published feed" \
  appcast --os windows --version 1.4.0 --installer "$(installer 1.4.0)" --existing "$w1" --work "$tmp/w2"
w2="$tmp/w2/appcast-windows.xml"
expect 0 "the new item is first and the earlier one is kept" \
  test "$(items_of "$w2" | tr '\n' ' ')" = "1.4.0 1040099 1.3.0 1030099 "
expect 0 "the feed has one signature block, the new one (verify_feed)" feed_check "$w2" "$key_a"
expect 0 "  and only one" test "$(grep -c 'sparkle-signatures' "$w2")" = 1
expect 0 "the kept item still describes its installer" enclosure "$w2" 1030099 "$(installer 1.3.0)" "$key_a"
expect 1 "an installer other than the item's is refused (verify_enclosure)" \
  enclosure "$w2" 1040099 "$(installer 1.3.0)" "$key_a"
expect 1 "the installer checked with another key is refused (verify_enclosure)" \
  enclosure "$w2" 1040099 "$(installer 1.4.0)" "$key_b"

# ── Linux ─────────────────────────────────────────────────────────────────────
expect 0 "a first Linux release makes a new feed" appcast --os linux --version 1.3.0 --fresh --work "$tmp/l1"
l1="$tmp/l1/appcast-linux.xml"
expect 0 "its feed passes verify_feed with the key" feed_check "$l1" "$key_a"
expect 0 "its item names the release page" \
  grep -q '<link>https://github.com/[^<]*/releases/tag/desktop-v1.3.0</link>' "$l1"
expect 1 "  and nothing to download" grep -q '<enclosure' "$l1"
expect 0 "the next Linux release keeps the first" \
  appcast --os linux --version 1.3.1 --existing "$l1" --work "$tmp/l2"
expect 0 "  both items, the new one first" \
  test "$(items_of "$tmp/l2/appcast-linux.xml" | tr '\n' ' ')" = "1.3.1 1030199 1.3.0 1030099 "
expect 0 "  and the feed verifies" feed_check "$tmp/l2/appcast-linux.xml" "$key_a"

# ── signatures verify_feed refuses ────────────────────────────────────────────
sed 's#desktop-v1.4.0#desktop-v6.6.6#' "$w2" >"$tmp/changed.xml"
expect 1 "a feed changed after it was signed is refused" feed_check "$tmp/changed.xml" "$key_a"
expect 1 "a feed signed with another key is refused" feed_check "$w2" "$key_b"
python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(d[: d.rfind(b"<!-- sparkle-signatures:")])' \
  "$w2" "$tmp/unsigned.xml"
expect 1 "an unsigned feed is refused" feed_check "$tmp/unsigned.xml" "$key_a"

# ── winlinux-appcast.sh refuses before writing a feed ─────────────────────────
refused() { # label reason args...
  local label="$1" reason="$2"
  shift 2
  expect 1 "$label" appcast "$@"
  says "  ($reason)" "$reason"
}
WINDOWS_PUBLIC_ED_KEY="$key_b" expect 1 "a private key that isn't WINDOWS_PUBLIC_ED_KEY's is refused" \
  appcast --os windows --version 1.5.0 --installer "$(installer 1.5.0)" --existing "$w2" --work "$tmp/r1"
says "  (it says so)" "does not belong to WINDOWS_PUBLIC_ED_KEY"
LINUX_ED_PRIVATE_KEY="" expect 1 "no private key is refused" \
  appcast --os linux --version 1.5.0 --existing "$l1" --work "$tmp/r2"
says "  (it says so)" "LINUX_ED_PRIVATE_KEY is not set"
refused "a beta is refused" "is a beta" --os linux --version 1.5.0-beta.1 --existing "$l1" --work "$tmp/r3"
refused "a version not newer than the feed's newest is refused" "is not newer than build 1040099" \
  --os windows --version 1.3.5 --installer "$(installer 1.3.5)" --existing "$w2" --work "$tmp/r4"
refused "a version already in the feed is refused" "already has build 1040099" \
  --os windows --version 1.4.0 --installer "$(installer 1.4.0)" --existing "$w2" --work "$tmp/r5"
refused "a Windows release without its installer is refused" "--installer: no such file" \
  --os windows --version 1.5.0 --existing "$w2" --work "$tmp/r6"
refused "another version's installer is refused" "is not Conduit-1.5.0-windows-x64-setup.exe" \
  --os windows --version 1.5.0 --installer "$(installer 1.4.0)" --existing "$w2" --work "$tmp/r7"
refused "a Linux release with an installer is refused" "names the release page, not a download" \
  --os linux --version 1.5.0 --installer "$(installer 1.5.0)" --existing "$l1" --work "$tmp/r8"
expect 1 "  and none of them wrote a feed" bash -c "ls '$tmp'/r[1-8]/appcast-*.xml 2>/dev/null | grep -q ."
# Inputs inside --work, which is moved aside before anything is read.
mkdir -p "$tmp/inside"
cp "$l1" "$tmp/inside/appcast-linux.xml"
refused "a feed inside --work is refused" "is inside --work" \
  --os linux --version 1.5.0 --existing "$tmp/inside/appcast-linux.xml" --work "$tmp/inside/../inside"
cp "$(installer 1.5.0)" "$tmp/inside/"
refused "an installer inside --work is refused" "is inside --work" \
  --os windows --version 1.5.0 --installer "$tmp/inside/Conduit-1.5.0-windows-x64-setup.exe" \
  --existing "$w2" --work "$tmp/inside"
expect 0 "  and nothing was moved" \
  bash -c "[ -f '$tmp/inside/appcast-linux.xml' ] && ! ls -d '$tmp'/inside.old-* 2>/dev/null | grep -q ."

# ── only on top of a feed signed with a trusted key ──────────────────────────
refused "a release on top of a feed changed after it was signed is refused" "is not signed with" \
  --os windows --version 1.5.0 --installer "$(installer 1.5.0)" --existing "$tmp/changed.xml" --work "$tmp/t1"
refused "a release on top of an unsigned feed is refused" "is not signed" \
  --os windows --version 1.5.0 --installer "$(installer 1.5.0)" --existing "$tmp/unsigned.xml" --work "$tmp/t2"
(
  export LINUX_ED_PRIVATE_KEY="$(private_of "$tmp/key-b.der")" LINUX_PUBLIC_ED_KEY="$key_b"
  appcast --os linux --version 1.3.0 --fresh --work "$tmp/by-b"
) >/dev/null 2>&1
refused "a release on top of a feed signed with another key is refused" "is not signed with" \
  --os linux --version 1.4.0 --existing "$tmp/by-b/appcast-linux.xml" --work "$tmp/t3"
expect 0 "--feed-public-key names the key the feed is signed with (the release after a swap)" \
  appcast --os linux --version 1.4.0 --existing "$tmp/by-b/appcast-linux.xml" --work "$tmp/t4" \
  --feed-public-key "$key_b"
expect 0 "  and the new feed is signed with this release's key" feed_check "$tmp/t4/appcast-linux.xml" "$key_a"
# An earlier release under <metadata>, outside the channel the apps read.
python3 -I -c '
import sys
d = open(sys.argv[1], encoding="utf-8").read()
d = d[: d.rfind("<!-- sparkle-signatures:")]
moved = d[d.index("    <item>") : d.index("</item>") + len("</item>")]
d = d.replace(moved, "").replace("  <channel>", "  <metadata>\n" + moved + "\n  </metadata>\n  <channel>", 1)
open(sys.argv[2], "w", encoding="utf-8").write(d)
' "$l1" "$tmp/misplaced-unsigned.xml"
sign_feed "$tmp/misplaced-unsigned.xml" "$tmp/misplaced.xml" "$tmp/key-a.der"
expect 0 "  (the misplaced feed is signed with the trusted key)" feed_check "$tmp/misplaced.xml" "$key_a"
refused "a release on top of a feed with an <item> outside its <channel> is refused" "outside <channel>" \
  --os linux --version 1.4.0 --existing "$tmp/misplaced.xml" --work "$tmp/t5"
expect 1 "check refuses an <item> outside the <channel>" \
  feed_py check --os linux --feed "$tmp/misplaced.xml" --version 1.3.0
expect 1 "  and none of them wrote a feed" bash -c "ls '$tmp'/t[1235]/appcast-*.xml 2>/dev/null | grep -q ."

# ── a key rotation's bridge release ───────────────────────────────────────────
expect 0 "a bridge release (--next-public-key) is signed with the current key" \
  appcast --os linux --version 1.4.0 --existing "$tmp/l2/appcast-linux.xml" --work "$tmp/bridge" \
  --next-public-key "$key_b"
says "  (and says it's a key rotation)" "key rotation"
expect 0 "  its feed verifies with the current key" feed_check "$tmp/bridge/appcast-linux.xml" "$key_a"
refused "--next-public-key naming the current key is refused" "nothing to rotate" \
  --os linux --version 1.5.0 --existing "$l1" --work "$tmp/r9" --next-public-key "$key_a"
refused "--next-public-key that isn't a key is refused" "is not an EdDSA public key" \
  --os linux --version 1.5.0 --existing "$l1" --work "$tmp/r10" --next-public-key AAAA
LINUX_PUBLIC_ED_KEY="" expect 1 "--next-public-key without LINUX_PUBLIC_ED_KEY is refused" \
  appcast --os linux --version 1.5.0 --existing "$l1" --work "$tmp/r11" --next-public-key "$key_b"
says "  (it says so)" "needs LINUX_PUBLIC_ED_KEY"

# ── winlinux_feed.py check ────────────────────────────────────────────────────
check_w() { feed_py check --os windows --version 1.4.0 --installer "$(installer 1.4.0)" "$@"; }
expect 0 "check accepts the second Windows feed" check_w --feed "$w2" --old "$w1"
feed_drop="$tmp/dropped.xml"
python3 -I - "$w2" "$feed_drop" <<'EOF'
import re, sys
d = open(sys.argv[1], encoding="utf-8").read()
d = d[: d.rfind("<!-- sparkle-signatures:")]
d = re.sub(r"\s*<item>(?:(?!</item>).)*desktop-v1\.3\.0.*?</item>", "", d, flags=re.S)
open(sys.argv[2], "w", encoding="utf-8").write(d + "<!-- sparkle-signatures:\nedSignature: x\nlength: 1\n-->\n")
EOF
expect 1 "check refuses a feed that drops an earlier item" check_w --feed "$feed_drop" --old "$w1"
# The 1.3.0 item's signature gone; everything else, the 1.4.0 item too, as signed.
python3 -I -c '
import re, sys
d = open(sys.argv[1], encoding="utf-8").read()
old = re.search(r"<item>(?:(?!</item>).)*desktop-v1\.3\.0.*?</item>", d, flags=re.S).group(0)
d = d.replace(old, re.sub(r" sparkle:edSignature=\"[^\"]*\"", "", old))
open(sys.argv[2], "w", encoding="utf-8").write(d)
' "$w2" "$tmp/changed-old-item.xml"
expect 1 "check refuses a feed that changes an earlier item" check_w --feed "$tmp/changed-old-item.xml" --old "$w1"
sed 's#sparkle:edSignature="[^"]*"/>#/>#' "$w2" >"$tmp/no-item-signature.xml"
expect 1 "check refuses an unsigned enclosure" check_w --feed "$tmp/no-item-signature.xml"
sed 's#length="[0-9]*"#length="1"#' "$w2" >"$tmp/length.xml"
expect 1 "check refuses the wrong length" check_w --feed "$tmp/length.xml"
sed 's#<sparkle:version>1040099</sparkle:version>#&<sparkle:channel>beta</sparkle:channel>#' "$w2" >"$tmp/channel.xml"
expect 1 "check refuses an item on a channel" check_w --feed "$tmp/channel.xml"
cat "$w2" "$w2" >"$tmp/twice.xml"
expect 1 "check refuses two signature blocks" check_w --feed "$tmp/twice.xml"

# ── the fixture the app's tests read ─────────────────────────────────────────
fixtures="$here/../crates/app/src/updates/fixtures"
expect 0 "the app's fixture feed passes verify_feed with its public key" \
  feed_check "$fixtures/appcast-linux.xml" "$(cat "$fixtures/appcast-linux.public-key")"
expect 1 "  and not with another" feed_check "$fixtures/appcast-linux.xml" "$key_a"

# ── Sparkle's own verdict (macOS) ─────────────────────────────────────────────
# The pinned Sparkle's sign_update checks EdDSA signatures as WinSparkle
# does (Ed25519 over the raw file): it accepts the installer's and the
# feed's, and refuses a changed feed.
if [ "$(uname -s)" = Darwin ]; then
  if sparkle="$(bash -c ". '$here/macos/lib.sh'; sparkle_dir")"; then
    sparkle_verify() { # file [signature]
      private_of "$tmp/key-a.der" | "$sparkle/bin/sign_update" --verify --ed-key-file - "$@"
    }
    signature="$(python3 -I -c 'import re, sys; print(re.search(r"sparkle:edSignature=\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$w2")"
    expect 0 "Sparkle's sign_update accepts the installer's signature" \
      sparkle_verify "$(installer 1.4.0)" "$signature"
    expect 0 "Sparkle's sign_update accepts the Windows feed's signature" sparkle_verify "$w2"
    expect 0 "Sparkle's sign_update accepts the Linux feed's signature" sparkle_verify "$tmp/l2/appcast-linux.xml"
    expect 1 "Sparkle's sign_update refuses a feed changed after it was signed" sparkle_verify "$tmp/changed.xml"
  else
    fail "the pinned Sparkle could not be fetched (lib.sh sparkle_dir)"
  fi
else
  echo "skip  Sparkle's own verdict (Sparkle's tools need macOS)"
fi

# ── where the feeds live ──────────────────────────────────────────────────────
mac="$(bash -c ". '$here/macos/lib.sh'; CONDUIT_APPCAST_URL= appcast_url")"
expect 0 "the Windows feed is beside the Mac's appcast" \
  test "$(feed_py url windows)" = "${mac%/appcast.xml}/appcast-windows.xml"
expect 0 "the Linux feed is beside the Mac's appcast" \
  test "$(feed_py url linux)" = "${mac%/appcast.xml}/appcast-linux.xml"

echo
if [ "$failures" = 0 ]; then
  echo "winlinux_feed_test: all checks passed"
else
  echo "winlinux_feed_test: $failures failed"
  exit 1
fi
