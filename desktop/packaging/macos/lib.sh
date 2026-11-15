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

# CFBundleVersion (Sparkle's sparkle:version): one integer that orders
# every release across both channels:
#   X*1000000 + Y*10000 + Z*100 + (beta N, or 99 for the stable release)
# so 1.2.0-beta.3 (1020003) < 1.2.0 (1020099) < 1.2.1-beta.1 (1020101).
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
# new feed (the first desktop release).
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
