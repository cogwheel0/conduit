# Shared helpers for the macOS packaging scripts (sourced, not run).
# Written for /bin/bash 3.2: no associative arrays, and empty arrays are
# expanded as ${a[@]+"${a[@]}"} so `set -u` holds.

PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "$PACKAGING_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$DESKTOP_DIR/.." && pwd)"

# shellcheck source=release.env
. "$PACKAGING_DIR/release.env"

BUNDLE_ID_DEFAULT=app.cogwheel.conduit.desktop
RUST_TARGET=aarch64-apple-darwin
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

log() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# Moves an existing path aside (`<path>.old-<timestamp>`) instead of
# deleting it: these scripts never delete anything.
move_aside() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    local dest
    dest="$1.old-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mv "$1" "$dest"
    log "moved the previous $(basename "$1") aside to $dest"
  fi
}

# The appcast URL every build embeds (SUFeedURL), from APPCAST_HOSTING.
appcast_url() {
  if [ -n "${CONDUIT_APPCAST_URL:-}" ]; then
    printf '%s\n' "$CONDUIT_APPCAST_URL"
    return
  fi
  local owner="${RELEASE_REPO%%/*}" name="${RELEASE_REPO#*/}"
  case "$APPCAST_HOSTING" in
    release-asset)
      printf 'https://github.com/%s/releases/download/%s/appcast.xml\n' \
        "$RELEASE_REPO" "$APPCAST_RELEASE_TAG"
      ;;
    pages) printf 'https://%s.github.io/%s/desktop/appcast.xml\n' "$owner" "$name" ;;
    branch)
      printf 'https://raw.githubusercontent.com/%s/%s/appcast.xml\n' \
        "$RELEASE_REPO" "$APPCAST_BRANCH"
      ;;
    *) die "APPCAST_HOSTING must be release-asset, pages or branch (got '$APPCAST_HOSTING')" ;;
  esac
}

# Validates a version: X.Y.Z or X.Y.Z-beta.N, each part without leading
# zeros (shell arithmetic would read 010 as octal, and Sparkle orders the
# build numbers made from them).
check_version() {
  local part='(0|[1-9][0-9]*)'
  printf '%s\n' "$1" | grep -Eq "^$part\\.$part\\.$part(-beta\\.$part)?\$" ||
    die "version '$1' is not X.Y.Z or X.Y.Z-beta.N (no leading zeros)"
}

is_beta() { case "$1" in *-beta.*) return 0 ;; *) return 1 ;; esac }

# Releases go out on Sparkle's default (stable) channel only (decided
# 2026-11-12): a -beta.N version can be built and tested locally, but
# appcast.sh and release-desktop.yml refuse to publish it.
refuse_beta_release() {
  if is_beta "$1"; then
    die "$1 is a beta: Conduit Desktop publishes stable releases only (one appcast, no beta channel)"
  fi
}

# CFBundleVersion (Sparkle's sparkle:version): one integer that orders
# every version:
#   X*1000000 + Y*10000 + Z*100 + 99 for a release (1.2.0 is 1020099);
# a local -beta.N build (never released) has N in place of 99, so it sorts
# before its release: 1.2.0-beta.3 (1020003) < 1.2.0 (1020099).
build_number() {
  check_version "$1"
  local core="${1%%-*}" beta=99
  local major="${core%%.*}" rest="${core#*.}"
  local minor="${rest%%.*}" patch="${rest#*.}"
  if is_beta "$1"; then beta="${1##*-beta.}"; fi
  { [ "$minor" -le 99 ] && [ "$patch" -le 99 ]; } || die "minor and patch must be 0-99 ($1)"
  if is_beta "$1"; then
    { [ "$beta" -ge 1 ] && [ "$beta" -le 98 ]; } || die "beta number must be 1-98 ($1)"
  fi
  printf '%s\n' $((major * 1000000 + minor * 10000 + patch * 100 + beta))
}

# The Sparkle release named in release.env, downloaded once into
# desktop/target/sparkle/<version>/ and checked against SPARKLE_SHA256.
# Prints the extracted folder (Sparkle.framework, bin/).
sparkle_dir() {
  local root="$DESKTOP_DIR/target/sparkle/$SPARKLE_VERSION"
  local archive="$root/Sparkle-$SPARKLE_VERSION.tar.xz"
  # `.complete` is written once tar has finished: a half-extracted copy is
  # never used.
  if [ ! -f "$root/extracted/.complete" ]; then
    mkdir -p "$root"
    if [ ! -f "$archive" ]; then
      log "downloading Sparkle $SPARKLE_VERSION"
      curl -fsSL --retry 3 -o "$archive.part" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
      mv "$archive.part" "$archive"
    fi
    local sum
    sum="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [ "$sum" != "$SPARKLE_SHA256" ]; then
      move_aside "$archive"
      die "Sparkle archive checksum $sum does not match release.env ($SPARKLE_SHA256)"
    fi
    log "Sparkle $SPARKLE_VERSION checksum verified"
    move_aside "$root/extracted"
    mkdir -p "$root/extracted"
    tar -xJf "$archive" -C "$root/extracted"
    : > "$root/extracted/.complete"
  fi
  printf '%s\n' "$root/extracted"
}

# Whether the GitHub release TAG exists on RELEASE_REPO: prints yes or no.
# Any other answer (network, auth, rate limit) stops: a lookup that failed
# is never read as "none yet".
release_exists() {
  local out
  if out="$(gh api "repos/$RELEASE_REPO/releases/tags/$1" --jq .id 2>&1)"; then
    printf 'yes\n'
    return
  fi
  case "$out" in
    *"HTTP 404"*) printf 'no\n' ;;
    *) die "could not look up the release $1: $out" ;;
  esac
}

# Whether the appcast has ever been published where APPCAST_HOSTING keeps
# it: prints yes or no, and stops when it cannot tell. Only "no" may start a
# new feed (the first desktop release). A feed release that is still a
# draft (a first publication that stopped) is "no": GitHub's lookup by tag
# sees published releases only, and publish-appcast.sh takes the draft over.
feed_exists() {
  case "$APPCAST_HOSTING" in
    release-asset) release_exists "$APPCAST_RELEASE_TAG" ;;
    pages | branch)
      local branch="$APPCAST_BRANCH" rc=0
      [ "$APPCAST_HOSTING" = pages ] && branch=gh-pages
      git ls-remote --exit-code --heads "https://github.com/$RELEASE_REPO.git" "$branch" >/dev/null 2>&1 || rc=$?
      case "$rc" in
        0) printf 'yes\n' ;;
        2) printf 'no\n' ;;
        *) die "could not look up the branch $branch (git exit $rc)" ;;
      esac
      ;;
    *) die "APPCAST_HOSTING must be release-asset, pages or branch" ;;
  esac
}

# Every Mach-O file under a folder (symlinks skipped), one per line.
macho_files() {
  find "$1" -type f -print0 | while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then printf '%s\n' "$f"; fi
  done
}

# The oldest macOS a Mach-O file runs on: LC_BUILD_VERSION's minos, or
# the older LC_VERSION_MIN_MACOSX's version; empty when it names neither.
macho_minos() {
  local v
  v="$(vtool -show-build "$1" 2>/dev/null | awk '/minos/ {print $2; exit}')"
  if [ -z "$v" ]; then
    v="$(otool -l "$1" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/ {f = 1} f && $1 == "version" {print $2; exit}')"
  fi
  printf '%s\n' "$v"
}

# Whether version $1 is at most $2 (dotted numbers).
version_le() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | awk 'NR == 1')" = "$1" ]
}

# The UUID of a Mach-O file or of a dSYM (its DWARF file), for matching
# the two: a dSYM symbolicates only the binary with its UUID.
macho_uuid() {
  xcrun dwarfdump --uuid "$1" 2>/dev/null | awk '/arm64/ {print $2; exit}'
}

# Whether two Mach-O files or dSYMs have the same UUID: both read, neither
# empty (a dwarfdump that failed on both is never a match).
same_uuid() {
  local a b
  a="$(macho_uuid "$1")"
  b="$(macho_uuid "$2")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# The Rust toolchain's rust-objcopy, printed only when it runs. It needs the
# toolchain's llvm-tools component (lib/libLLVM.dylib), which
# rust-toolchain.toml leaves out so that not every checkout downloads it;
# the release workflow adds it. Without it bundle.sh strips with Apple's
# strip instead. CONDUIT_RUST_OBJCOPY names another one (say, another
# installed toolchain's), checked the same way.
rust_objcopy() {
  local sysroot host tool
  if [ -n "${CONDUIT_RUST_OBJCOPY:-}" ]; then
    "$CONDUIT_RUST_OBJCOPY" --version >/dev/null 2>&1 ||
      die "CONDUIT_RUST_OBJCOPY ($CONDUIT_RUST_OBJCOPY) does not run"
    printf '%s\n' "$CONDUIT_RUST_OBJCOPY"
    return 0
  fi
  sysroot="$(cd "$DESKTOP_DIR" && rustc --print sysroot 2>/dev/null)" || return 0
  host="$(cd "$DESKTOP_DIR" && rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
  tool="$sysroot/lib/rustlib/$host/bin/rust-objcopy"
  if [ -x "$tool" ] && "$tool" --version >/dev/null 2>&1; then
    printf '%s\n' "$tool"
  fi
  return 0
}

# An openssl that does all the Ed25519 these scripts need (the one macOS
# ships, LibreSSL, does none of it; OpenSSL 1.1.1 makes keys but cannot
# sign or verify raw input): $OPENSSL when set, else the first of `openssl`
# on PATH and Homebrew's openssl@3 that makes a throwaway key, derives its
# public half, and signs and verifies raw bytes with them. Stops, saying
# so, when none can, so a missing tool is never reported as a bad key or a
# bad signature.
ed25519_openssl() {
  local c probe
  # Every step checked here: callers run this in `$(…) ||`, where errexit
  # does not stop it.
  probe="$(mktemp -d "${TMPDIR:-/tmp}/conduit-openssl.XXXXXX")" && [ -d "$probe" ] ||
    die "could not make a scratch folder to probe openssl in"
  printf 'a probe of raw Ed25519' >"$probe/data" || die "could not write in $probe"
  for c in ${OPENSSL:+"$OPENSSL"} openssl /opt/homebrew/opt/openssl@3/bin/openssl \
    /usr/local/opt/openssl@3/bin/openssl; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" genpkey -algorithm ed25519 -outform DER -out "$probe/key.der" >/dev/null 2>&1 &&
      "$c" pkey -inform DER -in "$probe/key.der" -pubout -outform DER -out "$probe/public.der" >/dev/null 2>&1 &&
      "$c" pkeyutl -sign -inkey "$probe/key.der" -keyform DER -rawin -in "$probe/data" \
        -out "$probe/signature" >/dev/null 2>&1 &&
      "$c" pkeyutl -verify -pubin -keyform DER -inkey "$probe/public.der" -rawin -in "$probe/data" \
        -sigfile "$probe/signature" >/dev/null 2>&1; then
      command -v "$c"
      return
    fi
  done
  die "no OpenSSL with Ed25519 signing here (macOS's LibreSSL and OpenSSL 1.1.1 lack it): brew install openssl@3, or set OPENSSL"
}

# The public half (base64, as SUPublicEDKey) of a private Sparkle EdDSA key
# given on stdin: base64 of the 32-byte seed `generate_keys -x` exports, or
# of the 96-byte form older keys were kept in (seed or private key, then
# the public key). Prints nothing for anything else. The key never reaches
# argv or a file. Stops when no openssl here does Ed25519.
sparkle_public_key() {
  local openssl
  openssl="$(ed25519_openssl)" || exit 1
  python3 -I -c '
import base64, subprocess, sys
try:
    raw = base64.b64decode(sys.stdin.read().strip(), validate=True)
except Exception:
    sys.exit(0)
if len(raw) == 96:
    print(base64.b64encode(raw[64:]).decode())
elif len(raw) == 32:
    der = bytes.fromhex("302e020100300506032b657004220420") + raw
    out = subprocess.run([sys.argv[1], "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                         input=der, capture_output=True)
    if out.returncode == 0 and len(out.stdout) >= 32:
        print(base64.b64encode(out.stdout[-32:]).decode())
' "$openssl"
}

# Whether $1 has the shape of a Sparkle public EdDSA key: base64 of 32
# bytes, as SUPublicEDKey and `generate_keys -p` have it.
is_ed25519_public_key() {
  python3 -I -c '
import base64, binascii, sys
try:
    sys.exit(0 if len(base64.b64decode(sys.argv[1], validate=True)) == 32 else 1)
except (binascii.Error, ValueError):
    sys.exit(1)
' "$1"
}

# The public key the app of release TAG carries (SUPublicEDKey), from the
# repository's variables: CURRENT (SPARKLE_PUBLIC_ED_KEY), the key that signs
# the release; or, for a key rotation's bridge release, NEXT
# (SPARKLE_NEXT_PUBLIC_ED_KEY), only when ROTATION_TAG
# (SPARKLE_KEY_ROTATION_TAG) names TAG. Anything else stops: one of the two
# without the other, a rotation named for another tag (left over, or set
# early), or a NEXT that is not a key or is CURRENT.
#
#   release_app_key TAG CURRENT NEXT ROTATION_TAG
release_app_key() {
  local tag="$1" current="$2" next="$3" rotation_tag="$4"
  if [ -z "$next" ] && [ -z "$rotation_tag" ]; then
    printf '%s\n' "$current"
    return 0
  fi
  [ -n "$next" ] && [ -n "$rotation_tag" ] ||
    die "a key rotation needs both SPARKLE_NEXT_PUBLIC_ED_KEY and SPARKLE_KEY_ROTATION_TAG; only one is set (docs/RELEASING-DESKTOP.md, \"Rotating the Sparkle key\")"
  [ "$rotation_tag" = "$tag" ] ||
    die "SPARKLE_KEY_ROTATION_TAG names $rotation_tag, not $tag: finish that rotation (swap the keys, delete both rotation variables) or name this tag (docs/RELEASING-DESKTOP.md)"
  is_ed25519_public_key "$next" ||
    die "SPARKLE_NEXT_PUBLIC_ED_KEY is not a Sparkle public key (base64 of 32 bytes; generate_keys -p)"
  [ "$next" != "$current" ] ||
    die "SPARKLE_NEXT_PUBLIC_ED_KEY is SPARKLE_PUBLIC_ED_KEY: nothing to rotate (delete both rotation variables)"
  printf '%s\n' "$next"
}

# Whether the appcast XML's item for sparkle:version BUILD describes FILE:
# its enclosure's length is FILE's size, and its sparkle:edSignature (an
# Ed25519 signature over the whole file, as Sparkle checks it) verifies with
# PUBLIC, the public key (base64, as SUPublicEDKey) installed copies have.
#
#   verify_enclosure XML BUILD FILE PUBLIC
verify_enclosure() {
  local xml="$1" build="$2" file="$3" public="$4" openssl dir rc=0
  [ -n "$public" ] || { warn "no public key to check the enclosure with"; return 1; }
  # Every step checked here, never by errexit: callers run this on the left
  # of `||`, where errexit does not stop it, and a skipped step must never
  # read as a verified DMG.
  [ -r "$file" ] || { warn "enclosure: cannot read $file"; return 1; }
  openssl="$(ed25519_openssl)" || return 1
  dir="$(mktemp -d "${TMPDIR:-/tmp}/conduit-enclosure.XXXXXX")" && [ -d "$dir" ] ||
    { warn "enclosure: could not make a scratch folder"; return 1; }
  python3 -I - "$xml" "$build" "$file" "$public" "$dir" <<'PY' || rc=$?
import base64, binascii, os, sys, xml.etree.ElementTree as ET
xml, build, path, public, out = sys.argv[1:]
S = "http://www.andymatuschak.org/xml-namespaces/sparkle"
items = [i for i in ET.parse(xml).getroot().iter("item")
         if (i.findtext(f"{{{S}}}version") or "").strip() == build]
if len(items) != 1:
    sys.exit(f"enclosure: expected one item with sparkle:version {build}, found {len(items)}")
enc = items[0].find("enclosure")
if enc is None:
    sys.exit("enclosure: the item has none")
if enc.get("length") != str(os.path.getsize(path)):
    sys.exit(f"enclosure: length {enc.get('length')}, the file is {os.path.getsize(path)} bytes")
try:
    sig = base64.b64decode(enc.get(f"{{{S}}}edSignature") or "", validate=True)
    key = base64.b64decode(public, validate=True)
except binascii.Error:
    sys.exit("enclosure: the signature or the key is not base64")
if len(sig) != 64 or len(key) != 32:
    sys.exit("enclosure: not an Ed25519 signature and public key")
with open(os.path.join(out, "signature"), "wb") as f:
    f.write(sig)
with open(os.path.join(out, "public.der"), "wb") as f:
    f.write(bytes.fromhex("302a300506032b6570032100") + key)
PY
  if [ "$rc" = 0 ] && { [ ! -s "$dir/public.der" ] || [ ! -s "$dir/signature" ]; }; then
    warn "enclosure: the signature or the key was not written"
    rc=1
  fi
  if [ "$rc" = 0 ]; then
    "$openssl" pkeyutl -verify -pubin -keyform DER -inkey "$dir/public.der" -rawin \
      -in "$file" -sigfile "$dir/signature" >/dev/null || rc=$?
  fi
  [ "$rc" = 0 ] || warn "enclosure: $file is not the DMG the signed item describes"
  return "$rc"
}

# Whether the appcast XML carries its own signature by PUBLIC (base64, as
# SUPublicEDKey), as installed copies require it (SURequireSignedFeed). It
# is Sparkle 2.10.1's check (SPUExtractAppcastContent, SUSignatureVerifier)
# with the public key alone, so the job that publishes the feed needs no
# private key, which `sign_update --verify` does. Like Sparkle, it verifies
# the bytes before the last `<!-- sparkle-signatures:` block against that
# block's edSignature; it accepts the block only as generate_appcast and
# sign_update write it (edSignature, then length, the length of those bytes)
# with nothing but whitespace after it. release_test.sh checks it against
# feeds the pinned Sparkle signs.
#
#   verify_feed XML PUBLIC
verify_feed() {
  local xml="$1" public="$2" openssl dir rc=0
  [ -n "$public" ] || { warn "feed: no public key to check the signature with"; return 1; }
  # Every step checked here, never by errexit, as in verify_enclosure.
  [ -r "$xml" ] || { warn "feed: cannot read $xml"; return 1; }
  openssl="$(ed25519_openssl)" || return 1
  dir="$(mktemp -d "${TMPDIR:-/tmp}/conduit-feed-signature.XXXXXX")" && [ -d "$dir" ] ||
    { warn "feed: could not make a scratch folder"; return 1; }
  python3 -I - "$xml" "$public" "$dir" <<'PY' || rc=$?
import base64, binascii, os, re, sys
path, public, out = sys.argv[1:]
with open(path, "rb") as f:
    data = f.read()
prefix = b"<!-- sparkle-signatures:\n"
start = data.rfind(prefix)
if start < 0:
    sys.exit("feed: not signed (no sparkle-signatures block)")
end = data.find(b"-->", start + len(prefix))
if end < 0:
    sys.exit("feed: the signature block is not closed")
content, block = data[:start], data[start + len(prefix):end]
if data[end + 3:].strip():
    sys.exit("feed: something follows the signature block")
m = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n", block)
if not m:
    sys.exit("feed: the signature block is not an edSignature and a length")
if int(m.group(2)) != len(content):
    sys.exit(f"feed: the block signs {int(m.group(2))} bytes, but {len(content)} precede it")
try:
    sig = base64.b64decode(m.group(1), validate=True)
    key = base64.b64decode(public, validate=True)
except binascii.Error:
    sys.exit("feed: the signature or the key is not base64")
if len(sig) != 64 or len(key) != 32:
    sys.exit("feed: not an Ed25519 signature and public key")
for name, value in (("content", content), ("signature", sig),
                    ("public.der", bytes.fromhex("302a300506032b6570032100") + key)):
    with open(os.path.join(out, name), "wb") as f:
        f.write(value)
PY
  if [ "$rc" = 0 ] && { [ ! -f "$dir/content" ] || [ ! -s "$dir/signature" ] || [ ! -s "$dir/public.der" ]; }; then
    warn "feed: the signed bytes, the signature or the key was not written"
    rc=1
  fi
  if [ "$rc" = 0 ]; then
    "$openssl" pkeyutl -verify -pubin -keyform DER -inkey "$dir/public.der" -rawin \
      -in "$dir/content" -sigfile "$dir/signature" >/dev/null || rc=$?
  fi
  [ "$rc" = 0 ] || warn "feed: $xml is not signed with that public key"
  return "$rc"
}

set_plist() { /usr/libexec/PlistBuddy -c "$1" "$2" >/dev/null; }

# The entitlement that lets a debugger (lldb, Instruments) attach, as Xcode
# gives Debug builds. Development signatures only (sign-dev.sh): notarization
# refuses it, and a released app must not take it.
GET_TASK_ALLOW=com.apple.security.get-task-allow

# Copies the entitlements SRC to OUT with GET_TASK_ALLOW added: a dev-only
# copy, so the checked-in files stay as a release signs them.
#
#   dev_entitlements SRC OUT
dev_entitlements() {
  cp "$1" "$2"
  set_plist "Add :$GET_TASK_ALLOW bool true" "$2"
}

# Whether the entitlements FILE grants GET_TASK_ALLOW: its value, as the
# property list holds it (comments and XML escapes read as codesign reads
# them), is Boolean true. A value false or of another type, or none, grants
# nothing. Stops when FILE is missing or is no property list.
#
#   grants_debugger FILE
grants_debugger() {
  [ -r "$1" ] || die "no entitlements at $1"
  /usr/bin/plutil -lint -s "$1" >/dev/null 2>&1 || die "$1 is not a property list"
  # plutil reads a key path, "." between keys: the entitlement's own dots
  # are escaped.
  /usr/bin/plutil -extract "${GET_TASK_ALLOW//./\\.}" xml1 -o - "$1" 2>/dev/null |
    grep -Fxq '<true/>'
}

# Stops when any entitlements FILE grants GET_TASK_ALLOW ([grants_debugger]),
# or is missing or no property list: what bundle.sh signs a bundle with is
# never a debug build's.
#
#   refuse_debug_entitlements FILE...
refuse_debug_entitlements() {
  local f
  for f in "$@"; do
    if grants_debugger "$f"; then
      die "$f grants $GET_TASK_ALLOW: a debugger's entitlement, for sign-dev.sh's dev builds only"
    fi
  done
}

# The bytes only a build with the test harness carries (lib.rs
# HARNESS_MARKER, compiled in with the `harness` feature only).
HARNESS_MARKER='conduit-desktop: test harness build'

# Whether the binary BIN was built with the test harness: 0 yes, 1 no, and
# it stops when BIN cannot be read (never taken for "no").
has_harness_marker() {
  local rc=0
  LC_ALL=C grep -aqF "$HARNESS_MARKER" "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "could not read $1 to look for the test harness" ;;
  esac
}

# Stops when the binary BIN carries the test harness and KIND (SIGN_KIND)
# signs for distribution: a harness build is signed ad hoc or with an Apple
# Development identity only, and never notarized, whatever flags a script
# was given. A binary that cannot be read stops too.
#
#   refuse_harness_distribution BIN KIND
refuse_harness_distribution() {
  [ -r "$1" ] || die "no binary at $1"
  case "$2" in adhoc | development) return 0 ;; esac
  if has_harness_marker "$1"; then
    die "$1 was built with the test harness: never signed for distribution (Developer ID) or notarized"
  fi
}

# Stops unless the app at APP is a bundle of id WANT (its Info.plist), so a
# step never re-signs or verifies another build than the one asked for (a
# release app as a test bundle, or the reverse). With RELEASE=1 it must also
# carry no test environment (LSEnvironment) and be version VERSION.
#
#   check_bundle APP WANT RELEASE VERSION
check_bundle() {
  local plist="$1/Contents/Info.plist" v
  v="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)"
  [ "$v" = "$2" ] || die "$1 is bundle id '${v:-?}', not $2: another build is in --out"
  [ "$3" = 1 ] || return 0
  if plutil -extract LSEnvironment raw -o - "$plist" >/dev/null 2>&1; then
    die "--release: $1 carries a test environment (LSEnvironment)"
  fi
  v="$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)"
  [ "$v" = "$4" ] || die "--release: $1 is version '$v', not $4"
}

# The executable of the app at APP.
app_binary() {
  printf '%s/Contents/MacOS/%s\n' "$1" "$(plutil -extract CFBundleExecutable raw -o - "$1/Contents/Info.plist")"
}

# Refuses a codesign identity ($1: its SHA-1, or its name or part of it)
# that the keychains hold only as revoked, expired or otherwise invalid,
# or not at all. `find-identity -v` still lists a revoked certificate, so
# each row's own verdict is read. Never prints the certificate's name.
check_identity() {
  local id="$1" rows hash reason found=0 valid=0 why=""
  rows="$(security find-identity -p codesigning 2>/dev/null |
    awk '/Valid identities only/ {exit} /^ *[0-9]+\) [0-9A-F]{40} / {print}')"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    hash="$(awk '{print $2}' <<<"$row")"
    if [ "$hash" = "$(tr '[:lower:]' '[:upper:]' <<<"$id")" ] || grep -Fq -- "$id" <<<"$row"; then
      found=1
      reason="$(sed -n 's/.*(\(CSSMERR_[A-Z_]*\)).*/\1/p' <<<"$row")"
      if [ -z "$reason" ]; then valid=1; else why="$reason"; fi
    fi
  done <<<"$rows"
  [ "$found" = 1 ] || die "no codesigning identity matches CONDUIT_SIGN_IDENTITY in the keychains"
  [ "$valid" = 1 ] || die "CONDUIT_SIGN_IDENTITY names an unusable certificate ($why); pick a valid one by its SHA-1 (security find-identity -v -p codesigning)"
}

# What signing with identity $1 makes, read off a probe signed with it:
#   SIGN_TEAM  the certificate's team (its OU), or TEAM_ID from release.env,
#              which must then agree; empty for ad-hoc ("-")
#   SIGN_KIND  adhoc; development for an "Apple Development" (or older
#              "Mac Developer") certificate: local test builds, no secure
#              timestamp, never notarized; distribution otherwise
#              (Developer ID)
signing_identity() {
  SIGN_TEAM=""
  SIGN_KIND=adhoc
  [ "$1" = "-" ] && return 0
  check_identity "$1"
  local probe info leaf
  probe="$(mktemp -d "${TMPDIR:-/tmp}/conduit-team.XXXXXX")"
  cp /usr/bin/true "$probe/probe"
  codesign --force --sign "$1" --timestamp=none "$probe/probe" >/dev/null 2>&1 ||
    die "codesign could not sign with CONDUIT_SIGN_IDENTITY (is its key in an unlocked keychain?)"
  # --verbose=2 for the Authority lines (the certificate chain).
  info="$(codesign -dv --verbose=2 "$probe/probe" 2>&1)"
  SIGN_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$info" | grep -v '^not set$' || true)"
  leaf="$(awk 'sub(/^Authority=/, "") && !n++' <<<"$info")"
  case "$leaf" in
    "Apple Development:"* | "Mac Developer:"*) SIGN_KIND=development ;;
    *) SIGN_KIND=distribution ;;
  esac
  if [ -n "${TEAM_ID:-}" ]; then
    [ -z "$SIGN_TEAM" ] || [ "$SIGN_TEAM" = "$TEAM_ID" ] ||
      die "release.env TEAM_ID $TEAM_ID is not the signing certificate's team $SIGN_TEAM"
    SIGN_TEAM="$TEAM_ID"
  fi
}

# A bundle's or binary's own signature: "<team> <kind>", the team being
# "-" when there is none; kind as in signing_identity.
signature_of() {
  local info team leaf kind
  info="$(codesign -dv --verbose=2 "$1" 2>&1)" || {
    printf -- '- unsigned\n'
    return 0
  }
  team="$(sed -n 's/^TeamIdentifier=//p' <<<"$info")"
  case "$team" in "" | "not set") team="-" ;; esac
  leaf="$(awk 'sub(/^Authority=/, "") && !n++' <<<"$info")"
  if grep -q '^Signature=adhoc' <<<"$info"; then
    kind=adhoc
  else
    case "$leaf" in
      "Apple Development:"* | "Mac Developer:"*) kind=development ;;
      *) kind=distribution ;;
    esac
  fi
  printf '%s %s\n' "$team" "$kind"
}

# Every Mach-O file under $1 with the team its signature names ("-" for
# none), one "<team> <path relative to $1>" per line.
macho_teams() {
  local f team
  while IFS= read -r f; do
    team="$(codesign -dv "$f" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    case "$team" in "" | "not set") team="-" ;; esac
    printf '%s %s\n' "$team" "${f#"$1"/}"
  done < <(macho_files "$1")
}

# codesign -dv's lines with each certificate's holder left out (the
# certificate kinds stay): logs may be shared, names are personal.
redact_authorities() {
  sed -E 's/^(Authority=(Apple Development|Mac Developer|Developer ID Application|Developer ID Installer|Apple Distribution|3rd Party Mac Developer Application)): .*/\1: …/'
}

# The widget's app group (release.env WIDGET_APP_GROUP) for team $1; with
# no team (ad-hoc) the team prefix is dropped.
widget_group() {
  if [ -n "$1" ]; then
    printf '%s\n' "${WIDGET_APP_GROUP//@TEAM_ID@/$1}"
  else
    printf '%s\n' "${WIDGET_APP_GROUP#@TEAM_ID@.}"
  fi
}

# The application identifier a provisioning profile grants ("TEAM.bundle.id").
profile_app_id() {
  security cms -D -i "$1" 2>/dev/null |
    plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - - 2>/dev/null || true
}

# The provisioning profiles CONDUIT_APP_PROFILE and CONDUIT_WIDGET_PROFILE
# (bundle.sh sign, sign-dev.sh), both or neither:
#   embed_profiles APP BUNDLE_ID TEAM ENT_DIR
# copies each into APP (the widget's into ConduitWidget.appex) as
# embedded.provisionprofile after checking it is for TEAM.BUNDLE_ID (the
# widget's for TEAM.BUNDLE_ID.widget), and adds the application and team
# identifiers it vouches for to ENT_DIR/Conduit.entitlements and
# ENT_DIR/ConduitWidget.entitlements. Without them the build still signs
# and runs; macOS only leaves the widget out of its gallery
# (docs/BUILDING-DESKTOP.md, "The desktop widget").
embed_profiles() {
  local app="$1" bundle_id="$2" team="$3" ent="$4"
  local app_profile="${CONDUIT_APP_PROFILE:-}" widget_profile="${CONDUIT_WIDGET_PROFILE:-}"
  if [ -z "$app_profile" ] && [ -z "$widget_profile" ]; then
    if [ -n "$team" ]; then
      warn "no CONDUIT_APP_PROFILE / CONDUIT_WIDGET_PROFILE: macOS will not list the widget (docs/BUILDING-DESKTOP.md)"
    fi
    return 0
  fi
  [ -n "$app_profile" ] && [ -n "$widget_profile" ] ||
    die "set both CONDUIT_APP_PROFILE and CONDUIT_WIDGET_PROFILE (or neither)"
  [ -n "$team" ] || die "provisioning profiles need a signing identity with a team"
  local pair dest id ent_file want got
  for pair in "app:$app_profile" "widget:$widget_profile"; do
    if [ "${pair%%:*}" = app ]; then
      dest="$app/Contents/embedded.provisionprofile"
      id="$bundle_id"
      ent_file="$ent/Conduit.entitlements"
    else
      dest="$app/Contents/PlugIns/ConduitWidget.appex/Contents/embedded.provisionprofile"
      id="$bundle_id.widget"
      ent_file="$ent/ConduitWidget.entitlements"
    fi
    [ -f "${pair#*:}" ] || die "no profile at ${pair#*:}"
    want="$team.$id"
    got="$(profile_app_id "${pair#*:}")"
    [ "$got" = "$want" ] || die "the ${pair%%:*} profile is for '$got', not $want"
    cp "${pair#*:}" "$dest"
    set_plist "Add :com.apple.application-identifier string $want" "$ent_file"
    set_plist "Add :com.apple.developer.team-identifier string $team" "$ent_file"
  done
  log "provisioning profiles embedded (app and widget, team $team)"
}
