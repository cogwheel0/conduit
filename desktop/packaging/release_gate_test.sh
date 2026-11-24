#!/bin/bash
# Checks the publish gate (release_gate.sh) against synthetic releases signed
# with keys made here: no real release, no real key, no network. Feeds are
# made by winlinux-appcast.sh (Windows, Linux) and in Sparkle's format by
# hand (the Mac's), as release_test.sh makes them.
#
#   desktop/packaging/release_gate_test.sh
#
# * A complete release passes: every OS's files, each checksum file listing
#   exactly its OS's files, the three feeds signed with the keys installed
#   copies have, the version on top at its download URL.
# * Refused, saying what is wrong: any one file missing (each in turn), two
#   missing (both named); a file changed after its checksum; a checksum
#   file that leaves a file out or lists another; a checksum file or a
#   package that can't be read; a feed signed with another key, or unsigned;
#   a feed for another version; items at another download URL, or naming
#   another release's page; an installer that isn't the one its signed item
#   describes; notices made for another OS.
# * It cannot run (exit 2, which is never a refusal) without a public key
#   to check a feed with, or without the folder.
# * `assets` names each OS's files; `sums` writes a checksum file the gate
#   accepts.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/conduit-gate-test.XXXXXX")"
failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
expect() { # expect 0|1|2 label command... (1: any failure but 2)
  local want="$1" label="$2"
  shift 2
  "$@" >"$tmp/out.txt" 2>&1
  local rc=$?
  if { [ "$want" = 0 ] && [ "$rc" = 0 ]; } || { [ "$want" = 1 ] && [ "$rc" = 1 ]; } ||
    { [ "$want" = 2 ] && [ "$rc" = 2 ]; }; then
    pass "$label"
  else
    fail "$label (exit $rc, wanted $want)"
    sed 's/^/      /' "$tmp/out.txt"
  fi
}
# The last command's output says $2 (a refusal for the right reason).
says() {
  if grep -qF -- "$2" "$tmp/out.txt"; then pass "$1"; else fail "$1 (no '$2')"; sed 's/^/      /' "$tmp/out.txt"; fi
}

openssl_path="$(bash -c ". '$here/macos/lib.sh'; ed25519_openssl")" || {
  echo "release_gate_test: needs an openssl that does Ed25519, as the release does (brew install openssl@3, or set OPENSSL)"
  exit 1
}
export OPENSSL="$openssl_path"
for k in mac windows linux other; do
  "$openssl_path" genpkey -algorithm ed25519 -outform DER -out "$tmp/key-$k.der" 2>/dev/null
done
public_of() { "$openssl_path" pkey -inform DER -in "$1" -pubout -outform DER | tail -c 32 | base64; }
private_of() { tail -c 32 "$1" | base64; } # the seed, as generate_keys -x exports it
sign_file() { # file key.der: its Ed25519 signature, base64
  "$openssl_path" pkeyutl -sign -inkey "$2" -keyform DER -rawin -in "$1" -out "$tmp/file.sig" &&
    base64 <"$tmp/file.sig" | tr -d '\n'
}
sign_feed() { # unsigned signed key.der: appends the block Sparkle's signAppcast writes
  "$openssl_path" pkeyutl -sign -inkey "$3" -keyform DER -rawin -in "$1" -out "$tmp/feed.sig" || return 1
  {
    cat "$1"
    printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' \
      "$(base64 <"$tmp/feed.sig" | tr -d '\n')" "$(wc -c <"$1" | tr -d ' ')"
  } >"$2"
}
export SPARKLE_PUBLIC_ED_KEY WINDOWS_PUBLIC_ED_KEY LINUX_PUBLIC_ED_KEY
SPARKLE_PUBLIC_ED_KEY="$(public_of "$tmp/key-mac.der")"
WINDOWS_PUBLIC_ED_KEY="$(public_of "$tmp/key-windows.der")"
LINUX_PUBLIC_ED_KEY="$(public_of "$tmp/key-linux.der")"
repo="$(bash -c ". '$here/macos/lib.sh'; printf '%s' \"\$RELEASE_REPO\"")"
prefix="https://github.com/$repo/releases/download/desktop-v1.3.0/"
gate() { "$here/release_gate.sh" check --version 1.3.0 "$@"; }

# ── a complete release, as the workflow assembles it ──────────────────────────
r="$tmp/release"
mkdir -p "$r"
printf 'synthetic dmg bytes' >"$r/Conduit-1.3.0.dmg"
printf 'synthetic dSYMs zip' >"$r/Conduit-1.3.0-dSYMs.zip"
printf 'synthetic installer 1.3.0' >"$r/Conduit-1.3.0-windows-x64-setup.exe"
printf 'synthetic deb' >"$r/conduit-desktop_1.3.0-1_amd64.deb"
printf 'synthetic rpm' >"$r/conduit-desktop-1.3.0-1.x86_64.rpm"
for os in Windows Linux; do
  lower="$(printf '%s' "$os" | tr A-Z a-z)"
  printf '# Third-party notices: Conduit Desktop for %s\n\nA synthetic licence list.\n' "$os" \
    >"$r/THIRD_PARTY_NOTICES-$lower.md"
done
mac_feed() { # out dmg key.der [prefix]: the Mac's appcast, V on top of an earlier item
  local dmg="$2" at="${4:-$prefix}"
  cat >"$tmp/mac-unsigned.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Conduit</title>
    <item>
      <title>1.3.0</title>
      <sparkle:version>1030099</sparkle:version>
      <sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
      <enclosure url="${at}Conduit-1.3.0.dmg" length="$(wc -c <"$dmg" | tr -d ' ')" type="application/octet-stream" sparkle:edSignature="$(sign_file "$dmg" "$3")"/>
    </item>
    <item>
      <title>1.2.0</title>
      <sparkle:version>1020099</sparkle:version>
      <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
      <enclosure url="https://example.org/Conduit-1.2.0.dmg" length="7" type="application/octet-stream" sparkle:edSignature="$(sign_file "$dmg" "$3")"/>
    </item>
  </channel>
</rss>
EOF
  sign_feed "$tmp/mac-unsigned.xml" "$1" "$3"
}
feeds_made=0
winlinux_feed() { # out os key.der version [installer] [prefix]
  local out="$1" os="$2" key="$3" version="$4" installer="${5:-}" at="${6:-}" OS
  OS="$(printf '%s' "$os" | tr a-z A-Z)"
  feeds_made=$((feeds_made + 1))
  local args=(--os "$os" --version "$version" --fresh --work "$tmp/feed-work-$feeds_made")
  [ -z "$installer" ] || args+=(--installer "$installer")
  [ -z "$at" ] || args+=(--download-url-prefix "$at")
  (
    export "${OS}_ED_PRIVATE_KEY=$(private_of "$key")" "${OS}_PUBLIC_ED_KEY=$(public_of "$key")"
    "$here/winlinux-appcast.sh" "${args[@]}" >"$tmp/feed-made.txt" 2>&1
  ) || { cat "$tmp/feed-made.txt"; return 1; }
  cp "$(tail -1 "$tmp/feed-made.txt")" "$out"
}
write_sums() { # dir sums-file names...
  local d="$1" out="$2"
  shift 2
  (cd "$d" && shasum -a 256 "$@") >"$d/$out"
}
mac_sums() { write_sums "$1" SHA256SUMS.txt Conduit-1.3.0.dmg Conduit-1.3.0-dSYMs.zip appcast.xml; }
windows_sums() {
  write_sums "$1" SHA256SUMS-windows.txt Conduit-1.3.0-windows-x64-setup.exe appcast-windows.xml \
    THIRD_PARTY_NOTICES-windows.md
}
linux_sums() {
  write_sums "$1" SHA256SUMS-linux.txt conduit-desktop_1.3.0-1_amd64.deb \
    conduit-desktop-1.3.0-1.x86_64.rpm appcast-linux.xml THIRD_PARTY_NOTICES-linux.md
}
mac_feed "$r/appcast.xml" "$r/Conduit-1.3.0.dmg" "$tmp/key-mac.der" || fail "the Mac feed could not be made"
winlinux_feed "$r/appcast-windows.xml" windows "$tmp/key-windows.der" 1.3.0 \
  "$r/Conduit-1.3.0-windows-x64-setup.exe" || fail "the Windows feed could not be made"
winlinux_feed "$r/appcast-linux.xml" linux "$tmp/key-linux.der" 1.3.0 || fail "the Linux feed could not be made"
mac_sums "$r"
windows_sums "$r"
linux_sums "$r"
fresh() { # a copy of the complete release, to change
  local d
  d="$(mktemp -d "$tmp/copy.XXXXXX")" && cp -R "$r/." "$d/" && printf '%s\n' "$d"
}

expect 0 "a complete release passes" gate --dir "$r"
says "it says the release is complete" "passes desktop-v1.3.0"

# ── a missing file ────────────────────────────────────────────────────────────
for f in Conduit-1.3.0.dmg Conduit-1.3.0-dSYMs.zip appcast.xml SHA256SUMS.txt \
  Conduit-1.3.0-windows-x64-setup.exe appcast-windows.xml THIRD_PARTY_NOTICES-windows.md \
  SHA256SUMS-windows.txt conduit-desktop_1.3.0-1_amd64.deb conduit-desktop-1.3.0-1.x86_64.rpm \
  appcast-linux.xml THIRD_PARTY_NOTICES-linux.md SHA256SUMS-linux.txt; do
  d="$(fresh)"
  mkdir -p "$d.aside" && mv "$d/$f" "$d.aside/"
  expect 1 "a release without $f is refused" gate --dir "$d"
  says "and the refusal names $f as missing" "missing: $f"
done
d="$(fresh)"
mkdir -p "$d.aside" && mv "$d/Conduit-1.3.0.dmg" "$d/appcast-linux.xml" "$d.aside/"
expect 1 "a release missing two files is refused" gate --dir "$d"
says "and the refusal names the first" "missing: Conduit-1.3.0.dmg"
says "and the second" "missing: appcast-linux.xml"

# ── checksums ─────────────────────────────────────────────────────────────────
d="$(fresh)"
printf 'another dmg' >"$d/Conduit-1.3.0.dmg"
expect 1 "a DMG changed after its checksum is refused" gate --dir "$d"
says "and the refusal names it" "Conduit-1.3.0.dmg is not the file SHA256SUMS.txt records"
d="$(fresh)"
printf 'a changed deb' >"$d/conduit-desktop_1.3.0-1_amd64.deb"
expect 1 "a .deb changed after its checksum is refused" gate --dir "$d"
says "and the refusal names it" "conduit-desktop_1.3.0-1_amd64.deb is not the file SHA256SUMS-linux.txt records"
d="$(fresh)"
write_sums "$d" SHA256SUMS-linux.txt conduit-desktop_1.3.0-1_amd64.deb appcast-linux.xml THIRD_PARTY_NOTICES-linux.md
expect 1 "a checksum file that leaves the .rpm out is refused" gate --dir "$d"
says "and the refusal says so" "SHA256SUMS-linux.txt does not list conduit-desktop-1.3.0-1.x86_64.rpm"
d="$(fresh)"
write_sums "$d" SHA256SUMS-windows.txt Conduit-1.3.0-windows-x64-setup.exe appcast-windows.xml \
  THIRD_PARTY_NOTICES-windows.md appcast-linux.xml
expect 1 "a checksum file that lists another OS's file is refused" gate --dir "$d"
says "and the refusal says so" "SHA256SUMS-windows.txt lists appcast-linux.xml"
d="$(fresh)"
printf 'not a checksum line\n' >>"$d/SHA256SUMS.txt"
expect 1 "a checksum file with a line that isn't one is refused" gate --dir "$d"
says "and the refusal names the line" "SHA256SUMS.txt line 4"
# A file the checksum check cannot read is never taken as checked.
if [ "$(id -u)" = 0 ]; then
  echo "skip  unreadable files (root reads every file)"
else
  d="$(fresh)"
  chmod 000 "$d/SHA256SUMS-linux.txt"
  expect 1 "a checksum file that can't be read is refused" gate --dir "$d"
  says "and the refusal names it" "SHA256SUMS-linux.txt could not be checked"
  chmod 644 "$d/SHA256SUMS-linux.txt"
  d="$(fresh)"
  chmod 000 "$d/conduit-desktop_1.3.0-1_amd64.deb"
  expect 1 "a package that can't be read for its checksum is refused" gate --dir "$d"
  says "and the refusal names its checksum file" "SHA256SUMS-linux.txt could not be checked"
  says "and the package" "conduit-desktop_1.3.0-1_amd64.deb"
  chmod 644 "$d/conduit-desktop_1.3.0-1_amd64.deb"
fi

# ── the feeds and what they describe ─────────────────────────────────────────
d="$(fresh)"
winlinux_feed "$d/appcast-windows.xml" windows "$tmp/key-other.der" 1.3.0 "$d/Conduit-1.3.0-windows-x64-setup.exe"
windows_sums "$d"
expect 1 "a Windows feed signed with another key is refused" gate --dir "$d"
says "and the refusal names the feed and the key" "appcast-windows.xml is not signed with WINDOWS_PUBLIC_ED_KEY"
d="$(fresh)"
mac_feed "$d/appcast.xml" "$d/Conduit-1.3.0.dmg" "$tmp/key-other.der"
mac_sums "$d"
expect 1 "a Mac appcast signed with another key is refused" gate --dir "$d"
says "and the refusal names the feed and the key" "appcast.xml is not signed with SPARKLE_PUBLIC_ED_KEY"
d="$(fresh)"
python3 -I - "$d/appcast-linux.xml" <<'EOF'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
open(path, "wb").write(data[: data.rfind(b"<!-- sparkle-signatures:")])
EOF
linux_sums "$d"
expect 1 "an unsigned Linux feed is refused" gate --dir "$d"
says "and the refusal names it" "appcast-linux.xml is not signed with LINUX_PUBLIC_ED_KEY"
d="$(fresh)"
printf 'synthetic installer 1.2.0' >"$tmp/Conduit-1.2.0-windows-x64-setup.exe"
winlinux_feed "$d/appcast-windows.xml" windows "$tmp/key-windows.der" 1.2.0 "$tmp/Conduit-1.2.0-windows-x64-setup.exe"
windows_sums "$d"
expect 1 "a Windows feed made for another version is refused" gate --dir "$d"
says "and the refusal says the feed lacks this version" "appcast-windows.xml"
d="$(fresh)"
printf 'synthetic installer, another build' >"$d/Conduit-1.3.0-windows-x64-setup.exe"
windows_sums "$d"
expect 1 "an installer its signed item doesn't describe is refused" gate --dir "$d"
says "and the refusal names the installer" "Conduit-1.3.0-windows-x64-setup.exe"
d="$(fresh)"
printf 'other dmg bytes, same sum' >"$d/Conduit-1.3.0.dmg"
mac_sums "$d"
expect 1 "a DMG its signed item doesn't describe is refused" gate --dir "$d"
says "and the refusal names the DMG" "Conduit-1.3.0.dmg"
expect 1 "items at another download URL are refused" \
  gate --dir "$r" --download-url-prefix https://example.invalid/elsewhere/
says "and the refusal names the URL it wanted" "https://example.invalid/elsewhere/Conduit-1.3.0.dmg"
d="$(fresh)"
mac_feed "$d/appcast.xml" "$d/Conduit-1.3.0.dmg" "$tmp/key-mac.der" https://example.invalid/dry-run/
winlinux_feed "$d/appcast-windows.xml" windows "$tmp/key-windows.der" 1.3.0 \
  "$d/Conduit-1.3.0-windows-x64-setup.exe" https://example.invalid/dry-run/
mac_sums "$d"
windows_sums "$d"
expect 0 "a release made for another download URL passes with that URL (the dry run's)" \
  gate --dir "$d" --download-url-prefix https://example.invalid/dry-run/
# Each item names this tag's release page (the Linux notice offers it).
other_page="https://github.com/$repo/releases/tag/desktop-v1.2.0"
d="$(fresh)"
LINUX_ED_PRIVATE_KEY="$(private_of "$tmp/key-linux.der")" python3 -I "$here/winlinux_feed.py" add \
  --os linux --version 1.3.0 --release-url "$other_page" --out "$d/appcast-linux.xml" >/dev/null
linux_sums "$d"
expect 1 "a Linux feed whose item names another release's page is refused" gate --dir "$d"
says "and the refusal names the page it wants" "https://github.com/$repo/releases/tag/desktop-v1.3.0"
d="$(fresh)"
WINDOWS_ED_PRIVATE_KEY="$(private_of "$tmp/key-windows.der")" python3 -I "$here/winlinux_feed.py" add \
  --os windows --version 1.3.0 --installer "$d/Conduit-1.3.0-windows-x64-setup.exe" \
  --download-url-prefix "$prefix" --release-url "$other_page" --out "$d/appcast-windows.xml" >/dev/null
windows_sums "$d"
expect 1 "a Windows feed whose item names another release's page is refused" gate --dir "$d"
says "and the refusal names the page it wants" "https://github.com/$repo/releases/tag/desktop-v1.3.0"
d="$(fresh)"
cp "$d/THIRD_PARTY_NOTICES-linux.md" "$d/THIRD_PARTY_NOTICES-windows.md"
windows_sums "$d"
expect 1 "Linux's notices in place of Windows' are refused" gate --dir "$d"
says "and the refusal names them" "THIRD_PARTY_NOTICES-windows.md"

# ── what stops the gate without a verdict ────────────────────────────────────
expect 2 "without WINDOWS_PUBLIC_ED_KEY the gate cannot run (never a refusal)" \
  env -u WINDOWS_PUBLIC_ED_KEY "$here/release_gate.sh" check --version 1.3.0 --dir "$r"
says "and it names the variable" "WINDOWS_PUBLIC_ED_KEY"
expect 2 "without its folder the gate cannot run" gate --dir "$tmp/no-such-folder"
expect 2 "a beta version is refused before anything is checked" \
  "$here/release_gate.sh" check --version 1.3.0-beta.1 --dir "$r"

# ── the asset names, and the checksum files the workflow writes ──────────────
expect 0 "assets names the Linux files" "$here/release_gate.sh" assets --os linux --version 1.3.0
if [ "$(cat "$tmp/out.txt")" = "conduit-desktop_1.3.0-1_amd64.deb
conduit-desktop-1.3.0-1.x86_64.rpm
appcast-linux.xml
THIRD_PARTY_NOTICES-linux.md
SHA256SUMS-linux.txt" ]; then
  pass "they are the package names package.sh writes, the feed, the notices and the checksums"
else
  fail "assets --os linux printed: $(tr '\n' ' ' <"$tmp/out.txt")"
fi
d="$(fresh)"
mkdir -p "$d.aside" && mv "$d/SHA256SUMS-windows.txt" "$d/SHA256SUMS-linux.txt" "$d.aside/"
expect 0 "sums writes the Windows checksum file" "$here/release_gate.sh" sums --os windows --version 1.3.0 --dir "$d"
expect 0 "sums writes the Linux checksum file" "$here/release_gate.sh" sums --os linux --version 1.3.0 --dir "$d"
expect 0 "the gate accepts the release with them" gate --dir "$d"
d="$(fresh)"
mkdir -p "$d.aside" && mv "$d/conduit-desktop-1.3.0-1.x86_64.rpm" "$d.aside/"
expect 1 "sums refuses a release missing one of its files" \
  "$here/release_gate.sh" sums --os linux --version 1.3.0 --dir "$d"
says "and names it" "conduit-desktop-1.3.0-1.x86_64.rpm"
expect 2 "sums leaves the Mac's checksum file to the Mac's job" \
  "$here/release_gate.sh" sums --os mac --version 1.3.0 --dir "$d"

echo
if [ "$failures" = 0 ]; then
  echo "release_gate_test: all checks passed"
else
  echo "release_gate_test: $failures failed"
  exit 1
fi
