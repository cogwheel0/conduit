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

set_plist() { /usr/libexec/PlistBuddy -c "$1" "$2" >/dev/null; }

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
  leaf="$(sed -n 's/^Authority=//p' <<<"$info" | head -1)"
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
  leaf="$(sed -n 's/^Authority=//p' <<<"$info" | head -1)"
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
