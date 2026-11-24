#!/bin/bash
# The publish gate: whether a desktop-v* release carries every OS's files,
# each matching its checksum file, and the three update feeds, each signed
# with the key installed copies have and describing this version. One tag
# releases every OS, and none is published without the others
# (docs/RELEASING-DESKTOP.md, "The publish gate").
#
#   desktop/packaging/release_gate.sh check --version V --dir DIR [--download-url-prefix U]
#   desktop/packaging/release_gate.sh assets --os mac|windows|linux --version V
#   desktop/packaging/release_gate.sh sums --os windows|linux --version V --dir DIR
#
# check: DIR holds the release's files as GitHub serves them (gh release
# download). Every problem is listed before it fails:
#   - every file is there:
#       macOS    Conduit-V.dmg, Conduit-V-dSYMs.zip, appcast.xml, SHA256SUMS.txt
#       Windows  Conduit-V-windows-x64-setup.exe, appcast-windows.xml,
#                THIRD_PARTY_NOTICES-windows.md, SHA256SUMS-windows.txt
#       Linux    conduit-desktop_V-1_amd64.deb, conduit-desktop-V-1.x86_64.rpm,
#                appcast-linux.xml, THIRD_PARTY_NOTICES-linux.md, SHA256SUMS-linux.txt
#   - each OS's checksum file lists exactly that OS's other files, once
#     each, and each matches;
#   - appcast.xml is signed with SPARKLE_PUBLIC_ED_KEY (lib.sh verify_feed),
#     and its newest item is V at U + the DMG, the DMG's length, its EdDSA
#     signature by that key (check_appcast.py, lib.sh verify_enclosure);
#   - appcast-windows.xml is signed with WINDOWS_PUBLIC_ED_KEY, and its
#     newest item is V with the installer at U + its name, signed by that
#     key (winlinux_feed.py check, verify_enclosure);
#   - appcast-linux.xml is signed with LINUX_PUBLIC_ED_KEY, and its newest
#     item is V (winlinux_feed.py check);
#   - both those items name V's release page (the Linux notice offers it);
#   - each OS's notices were made for it (winlinux.py notices).
# U, the download URL prefix, defaults to the version's GitHub release.
# Whether each feed keeps every item of the live one is the feed job's
# check, made against the live feed when it publishes.
#
# Exit codes: 0 the release is complete; 1 it is refused (the problems are
# listed); 2 it could not be checked (usage, a key variable missing, no
# OpenSSL with Ed25519), which says nothing about the release.
#
# assets: prints one OS's file names, one a line (the checksum file last).
# sums: writes SHA256SUMS-<os>.txt in DIR for that OS's other files, as
# `shasum -a 256` writes it; the Mac's SHA256SUMS.txt is the Mac job's.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=macos/lib.sh
. "$here/macos/lib.sh"

cannot() {
  printf '\033[31merror:\033[0m %s\n' "$*" >&2
  exit 2
}

# One OS's release files for version $2, the checksum file last.
assets_of() {
  case "$1" in
    mac) printf '%s\n' "Conduit-$2.dmg" "Conduit-$2-dSYMs.zip" appcast.xml SHA256SUMS.txt ;;
    windows)
      printf '%s\n' "Conduit-$2-windows-x64-setup.exe" appcast-windows.xml \
        THIRD_PARTY_NOTICES-windows.md SHA256SUMS-windows.txt
      ;;
    linux)
      printf '%s\n' "conduit-desktop_$2-1_amd64.deb" "conduit-desktop-$2-1.x86_64.rpm" \
        appcast-linux.xml THIRD_PARTY_NOTICES-linux.md SHA256SUMS-linux.txt
      ;;
    *) cannot "--os mac, windows or linux (got '$1')" ;;
  esac
}

command="${1:-}"
[ $# -gt 0 ] && shift
os="" version="" dir="" prefix=""
while [ $# -gt 0 ]; do
  case "$1" in
    --os) os="${2:-}"; shift ;;
    --version) version="${2:-}"; shift ;;
    --dir) dir="${2:-}"; shift ;;
    --download-url-prefix) prefix="${2:-}"; shift ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) cannot "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
(check_version "$version") 2>/dev/null || cannot "--version '$version' is not X.Y.Z"
case "$version" in *-beta.*) cannot "$version is a beta: Conduit Desktop publishes stable releases only" ;; esac

case "$command" in
  assets)
    assets_of "$os" "$version"
    exit 0
    ;;
  sums)
    case "$os" in windows | linux) ;; *) cannot "sums --os windows or linux: the Mac's SHA256SUMS.txt is the Mac job's" ;; esac
    [ -d "$dir" ] || cannot "--dir: no such folder '$dir'"
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(assets_of "$os" "$version" | sed '$d')
    missing=()
    for f in "${files[@]}"; do [ -f "$dir/$f" ] || missing+=("$f"); done
    if [ "${#missing[@]}" -gt 0 ]; then
      printf '\033[31merror:\033[0m missing: %s\n' "${missing[@]}" >&2
      exit 1
    fi
    python3 -I - "$dir" "SHA256SUMS-$os.txt" "${files[@]}" <<'EOF' || exit 1
import hashlib, os, sys
folder, out, *names = sys.argv[1:]
lines = []
for name in names:
    digest = hashlib.sha256()
    with open(os.path.join(folder, name), "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    lines.append(f"{digest.hexdigest()}  {name}\n")
with open(os.path.join(folder, out), "w", encoding="utf-8") as f:
    f.writelines(lines)
print(f"{os.path.join(folder, out)}: {len(names)} files")
EOF
    exit 0
    ;;
  check) ;;
  *) cannot "usage: release_gate.sh check|assets|sums ... (see --help)" ;;
esac

[ -d "$dir" ] || cannot "--dir: no such folder '$dir'"
for var in SPARKLE_PUBLIC_ED_KEY WINDOWS_PUBLIC_ED_KEY LINUX_PUBLIC_ED_KEY; do
  [ -n "${!var:-}" ] || cannot "$var is not set: the public key that checks its OS's feed"
done
OPENSSL="$(ed25519_openssl 2>/dev/null)" || cannot "no OpenSSL with Ed25519 here (brew install openssl@3, or set OPENSSL)"
export OPENSSL
prefix="${prefix:-https://github.com/$RELEASE_REPO/releases/download/desktop-v$version/}"
case "$prefix" in */) ;; *) prefix="$prefix/" ;; esac
build="$(build_number "$version")"
tag="desktop-v$version"
page="https://github.com/$RELEASE_REPO/releases/tag/$tag"

problems=0
refuse() {
  problems=$((problems + 1))
  printf 'refused: %s\n' "$*"
}
# The last line a failed check printed, without lib.sh's colours.
said() { printf '%s' "$1" | sed "s/$(printf '\033')\\[[0-9;]*m//g" | awk 'NF' | tail -1; }
# check LABEL COMMAND...: refuses with LABEL and what the command said.
check() {
  local label="$1" out
  shift
  if ! out="$("$@" 2>&1)"; then
    refuse "$label ($(said "$out"))"
  fi
}
present() { [ -f "$dir/$1" ]; }

for target in mac windows linux; do
  while IFS= read -r f; do
    present "$f" || refuse "missing: $f ($target)"
  done < <(assets_of "$target" "$version")
done

# Each checksum file lists exactly its OS's other files, and each matches.
# A file the reader cannot read refuses the release too: its checksum was
# never checked.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/conduit-gate.XXXXXX")" && [ -d "$scratch" ] ||
  cannot "could not make a scratch folder"
for target in mac windows linux; do
  names=()
  while IFS= read -r f; do names+=("$f"); done < <(assets_of "$target" "$version")
  sums="${names[${#names[@]} - 1]}"
  unset 'names[${#names[@]}-1]'
  present "$sums" || continue
  rc=0
  python3 -I - "$dir" "$sums" "${names[@]}" >"$scratch/sums.out" 2>"$scratch/sums.err" <<'EOF' || rc=$?
import hashlib, os, re, sys
folder, sums, *names = sys.argv[1:]
listed = {}
with open(os.path.join(folder, sums), encoding="utf-8", errors="replace") as f:
    for number, line in enumerate(f.read().splitlines(), 1):
        if not line.strip():
            continue
        m = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        if not m:
            print(f"{sums} line {number} is not '<sha256>  <file>'")
        elif m.group(2) in listed:
            print(f"{sums} lists {m.group(2)} twice")
        else:
            listed[m.group(2)] = m.group(1)
for name in names:
    if name not in listed:
        print(f"{sums} does not list {name}")
for name in listed:
    if name not in names:
        print(f"{sums} lists {name}, which is not one of its OS's files")
for name in names:
    path = os.path.join(folder, name)
    if name in listed and os.path.isfile(path):
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                digest.update(block)
        if digest.hexdigest() != listed[name]:
            print(f"{name} is not the file {sums} records (its SHA-256 differs)")
EOF
  while IFS= read -r line; do
    [ -n "$line" ] && refuse "$line"
  done <"$scratch/sums.out"
  [ "$rc" = 0 ] || refuse "$sums could not be checked ($(said "$(cat "$scratch/sums.err")"))"
done

# The feeds: each signed with its OS's key, and describing this version.
dmg="Conduit-$version.dmg"
exe="Conduit-$version-windows-x64-setup.exe"
if present appcast.xml; then
  check "appcast.xml is not signed with SPARKLE_PUBLIC_ED_KEY" verify_feed "$dir/appcast.xml" "$SPARKLE_PUBLIC_ED_KEY"
  if present "$dmg"; then
    check "appcast.xml does not describe $dmg at $prefix$dmg" \
      python3 -I "$here/macos/check_appcast.py" --new "$dir/appcast.xml" --dmg "$dir/$dmg" \
      --version "$version" --build "$build" --url "$prefix$dmg"
    check "appcast.xml's item for $version is not signed for $dmg with SPARKLE_PUBLIC_ED_KEY" \
      verify_enclosure "$dir/appcast.xml" "$build" "$dir/$dmg" "$SPARKLE_PUBLIC_ED_KEY"
  fi
fi
if present appcast-windows.xml; then
  check "appcast-windows.xml is not signed with WINDOWS_PUBLIC_ED_KEY" \
    verify_feed "$dir/appcast-windows.xml" "$WINDOWS_PUBLIC_ED_KEY"
  if present "$exe"; then
    check "appcast-windows.xml does not describe $exe at $prefix$exe" \
      python3 -I "$here/winlinux_feed.py" check --os windows --feed "$dir/appcast-windows.xml" \
      --version "$version" --installer "$dir/$exe" --url "$prefix$exe" --link "$page"
    check "appcast-windows.xml's item for $version is not signed for $exe with WINDOWS_PUBLIC_ED_KEY" \
      verify_enclosure "$dir/appcast-windows.xml" "$build" "$dir/$exe" "$WINDOWS_PUBLIC_ED_KEY"
  fi
fi
if present appcast-linux.xml; then
  check "appcast-linux.xml is not signed with LINUX_PUBLIC_ED_KEY" \
    verify_feed "$dir/appcast-linux.xml" "$LINUX_PUBLIC_ED_KEY"
  check "appcast-linux.xml does not describe $version at $page" \
    python3 -I "$here/winlinux_feed.py" check --os linux --feed "$dir/appcast-linux.xml" \
    --version "$version" --link "$page"
fi
for target in windows linux; do
  if present "THIRD_PARTY_NOTICES-$target.md"; then
    check "THIRD_PARTY_NOTICES-$target.md were not made for $target" \
      python3 -I "$here/winlinux.py" notices "$dir/THIRD_PARTY_NOTICES-$target.md" --os "$target"
  fi
done

if [ "$problems" -gt 0 ]; then
  echo "the publish gate refuses $tag: $problems problem(s) above"
  exit 1
fi
echo "the publish gate passes $tag: every OS's files are here and match their checksums, and the three feeds verify"
