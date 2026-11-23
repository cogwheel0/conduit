#!/bin/bash
# Builds Conduit Desktop's Linux packages (x86_64, unsigned): a .deb and an
# .rpm from one build.
#
#   desktop/packaging/linux/package.sh [--version V] [--out DIR] [--notices FILE]
#                                      [--skip-rust] [--skip-daemon]
#
# 1. The app: cargo build --release, without the test harness (no
#    `harness` feature), CONDUIT_VERSION set.
# 2. conduitd: `dart build cli` in apps/daemon (conduitd and its
#    libsqlite3.so), with the Dart code generated first when it isn't.
# 3. <out>/stage/usr/lib/conduit: conduit-desktop with conduitd/ beside it
#    (where paths::packaged_daemon_for looks) and the model logo catalog
#    conduitd reads; checked (winlinux.py layout: complete, no test
#    harness), and the desktop entry with desktop-file-validate when it's
#    installed.
# 4. The dependencies, worked out from the binaries: the .deb's with
#    dpkg-shlibdeps, as Debian names them on the build machine (so build on
#    the oldest release the packages are for: CI uses Ubuntu 22.04, glibc
#    2.35, and newer Debian and Ubuntu releases provide the same names);
#    the .rpm's as sonames and glibc symbol versions (winlinux.py
#    rpm-requires), which Fedora, openSUSE and others resolve alike.
# 5. nfpm writes <out>/conduit-desktop_<version>-1_amd64.deb and
#    <out>/conduit-desktop-<version>-1.x86_64.rpm.
#
# The packages install /usr/lib/conduit/, the link /usr/bin/conduit-desktop,
# /usr/share/applications/conduit-desktop.desktop (conduit:// links, and
# Open With for the Mac's document types: never their default app), the
# hicolor icons, the licence and the third-party notices
# (/usr/share/doc/conduit-desktop/). Nothing goes in a home folder, so
# removing a package leaves its users' data.
#
# --notices: the Linux third-party notices, made by
# packaging/notices/notices.sh --target x86_64-unknown-linux-gnu (CI makes
# them in a job of their own); without it this script runs notices.sh,
# which needs cargo-about. Either way they are checked to be Linux's.
#
# --version: X.Y.Z (default 0.0.0), checked as the Mac's (macos/lib.sh).
# --out: default desktop/target/linux/Conduit-<version>; an earlier one is
# moved aside, never deleted. --skip-rust, --skip-daemon: reuse what an
# earlier build left.
#
# Needs Linux x86_64, Rust, Flutter/Dart with `flutter pub get` done at the
# repository root, python3, readelf (binutils), dpkg-shlibdeps (dpkg-dev)
# and the app's build libraries (docs/BUILDING-DESKTOP.md). nfpm: NFPM in
# the environment, else the release tools.env pins, downloaded once into
# desktop/target/nfpm/<version> and checked against its SHA-256.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../macos/lib.sh
. "$here/../macos/lib.sh"
# shellcheck source=tools.env
. "$here/tools.env"

version=0.0.0
out=""
notices=""
skip_rust=0
skip_daemon=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift ;;
    --out) out="$2"; shift ;;
    --notices) notices="$2"; shift ;;
    --skip-rust) skip_rust=1 ;;
    --skip-daemon) skip_daemon=1 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || die "the Linux packages are built on Linux x86_64"
check_version "$version"
out="${out:-$DESKTOP_DIR/target/linux/Conduit-$version}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
winlinux="$here/../winlinux.py"
if [ -n "$notices" ]; then
  [ -f "$notices" ] || die "--notices $notices: no such file"
  notices="$(cd "$(dirname "$notices")" && pwd)/$(basename "$notices")"
  # The build moves an earlier --out aside, notices in it included.
  case "$notices" in
    "$out"/*) die "--notices $notices is inside --out $out, which the build moves aside first: put the notices elsewhere" ;;
  esac
fi

# What the packages say about themselves. The description and the
# maintainer are proposals awaiting the maintainer's word (the PR says so).
name=conduit-desktop
summary="Native desktop client for Open WebUI, model endpoints and self-hosted agents"
maintainer="Conduit maintainers <https://github.com/cogwheel0/conduit/issues>"
homepage=https://github.com/cogwheel0/conduit
icon_sizes="16 24 32 48 64 128 256 512"

# The pinned nfpm, downloaded once and checked; NFPM overrides it.
nfpm_bin() {
  if [ -n "${NFPM:-}" ]; then
    printf '%s\n' "$NFPM"
    return
  fi
  local root="$DESKTOP_DIR/target/nfpm/$NFPM_VERSION"
  local archive="$root/nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz"
  # `.complete` is written once tar has finished: a half-extracted copy is
  # never used.
  if [ ! -f "$root/extracted/.complete" ]; then
    mkdir -p "$root"
    if [ ! -f "$archive" ]; then
      log "downloading nfpm $NFPM_VERSION"
      curl -fsSL --retry 3 -o "$archive.part" "$NFPM_URL"
      mv "$archive.part" "$archive"
    fi
    local sum
    sum="$(sha256sum "$archive" | awk '{print $1}')"
    if [ "$sum" != "$NFPM_SHA256" ]; then
      move_aside "$archive"
      die "nfpm archive checksum $sum does not match tools.env ($NFPM_SHA256)"
    fi
    log "nfpm $NFPM_VERSION checksum verified"
    move_aside "$root/extracted"
    mkdir -p "$root/extracted"
    tar -xzf "$archive" -C "$root/extracted" nfpm
    : >"$root/extracted/.complete"
  fi
  printf '%s\n' "$root/extracted/nfpm"
}

# The ELF files under a folder, one a line.
elf_files() {
  find "$1" -type f -print0 | while IFS= read -r -d '' f; do
    if [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then printf '%s\n' "$f"; fi
  done
}

# The .deb's Depends, from dpkg-shlibdeps over every ELF file in the app
# folder (it wants a source package's debian/control to run in).
deb_depends() {
  local app_dir="$1" work f
  work="$(mktemp -d "${TMPDIR:-/tmp}/conduit-shlibdeps.XXXXXX")"
  mkdir -p "$work/debian"
  printf 'Source: %s\n\nPackage: %s\nArchitecture: amd64\n' "$name" "$name" >"$work/debian/control"
  local args=()
  while IFS= read -r f; do args+=("-e$f"); done < <(elf_files "$app_dir")
  (cd "$work" && dpkg-shlibdeps -O --ignore-missing-info -l"$app_dir/conduitd/lib" "${args[@]}") |
    sed -n 's/^shlibs:Depends=//p' | sed 's/, /\n/g'
}

# One YAML list item a line, quoted.
yaml_items() {
  local item
  while IFS= read -r item; do
    [ -n "$item" ] && printf '      - "%s"\n' "$item"
  done
}

# --- 1. the app --------------------------------------------------------------

binary="$DESKTOP_DIR/target/release/conduit-desktop"
if [ "$skip_rust" = 1 ]; then
  [ -f "$binary" ] || die "--skip-rust: no $binary"
  log "reusing $binary"
else
  log "cargo build --release (version $version)"
  (cd "$DESKTOP_DIR" && CONDUIT_VERSION="$version" cargo build --release --locked -p conduit-desktop)
fi

# --- 2. conduitd -------------------------------------------------------------

daemon_bundle="$REPO_ROOT/apps/daemon/build/cli/linux_x64/bundle"
if [ "$skip_daemon" = 1 ]; then
  log "reusing $daemon_bundle"
else
  if ! find "$REPO_ROOT/packages/conduit_core/lib" -name '*.g.dart' -print -quit | grep -q .; then
    log "generating Dart code (build_runner)"
    (cd "$REPO_ROOT" && flutter pub get)
    for dir in "$REPO_ROOT"/packages/* "$REPO_ROOT"/apps/*; do
      if [ -f "$dir/pubspec.yaml" ] && grep -q '^  build_runner:' "$dir/pubspec.yaml"; then
        log "build_runner in ${dir#"$REPO_ROOT"/}"
        (cd "$dir" && dart run build_runner build)
      fi
    done
  fi
  log "dart build cli (apps/daemon)"
  (cd "$REPO_ROOT/apps/daemon" && dart build cli)
fi
[ -x "$daemon_bundle/bin/conduitd" ] || die "no $daemon_bundle/bin/conduitd"

# --- 3. the staged tree ------------------------------------------------------

move_aside "$out"
stage="$out/stage"
app_dir="$stage/usr/lib/conduit"
mkdir -p "$app_dir/conduitd/model_logos"
log "staging $app_dir"
cp "$binary" "$app_dir/conduit-desktop"
cp -R "$daemon_bundle/." "$app_dir/conduitd/"
# The models.dev logo catalog: conduitd looks for it beside its bin/.
cp "$REPO_ROOT/assets/model_logos/catalog.json" "$app_dir/conduitd/model_logos/"
python3 -I "$winlinux" layout "$app_dir" --os linux
if [ -n "$notices" ]; then
  cp "$notices" "$stage/THIRD_PARTY_NOTICES.md"
else
  "$here/../notices/notices.sh" --target x86_64-unknown-linux-gnu --out "$stage/THIRD_PARTY_NOTICES.md"
fi
python3 -I "$winlinux" notices "$stage/THIRD_PARTY_NOTICES.md" --os linux
if command -v desktop-file-validate >/dev/null; then
  desktop-file-validate "$here/conduit-desktop.desktop"
  log "desktop-file-validate: conduit-desktop.desktop"
else
  warn "no desktop-file-validate (desktop-file-utils): the desktop entry is not checked"
fi

# --- 4. dependencies ---------------------------------------------------------

log "dependencies (dpkg-shlibdeps; readelf)"
deb_deps="$(deb_depends "$app_dir")"
rpm_deps="$(python3 -I "$winlinux" rpm-requires "$app_dir")"
[ -n "$deb_deps" ] && [ -n "$rpm_deps" ] || die "found no dependencies in $app_dir"
printf 'deb Depends:\n%s\nrpm Requires:\n%s\n' "$deb_deps" "$rpm_deps" | sed 's/^/  /' >&2

# --- 5. the packages ---------------------------------------------------------

config="$out/nfpm.yaml"
{
  cat <<EOF
# Written by desktop/packaging/linux/package.sh.
name: $name
arch: amd64
platform: linux
version: "$version"
release: "1"
section: net
priority: optional
maintainer: "$maintainer"
description: "$summary"
homepage: $homepage
license: GPL-3.0
overrides:
  deb:
    depends:
$(yaml_items <<<"$deb_deps")
    # The renderer loads Vulkan, or EGL, at run time; xdg-open opens links.
    recommends:
      - libvulkan1
      - libegl1
      - xdg-utils
  rpm:
    depends:
$(yaml_items <<<"$rpm_deps")
    recommends:
      - "libvulkan.so.1()(64bit)"
      - "libEGL.so.1()(64bit)"
      - xdg-utils
contents:
  - src: $app_dir
    dst: /usr/lib/conduit
    type: tree
  - src: /usr/lib/conduit/conduit-desktop
    dst: /usr/bin/conduit-desktop
    type: symlink
  - src: $here/conduit-desktop.desktop
    dst: /usr/share/applications/conduit-desktop.desktop
    file_info:
      mode: 0644
  - src: $stage/THIRD_PARTY_NOTICES.md
    dst: /usr/share/doc/conduit-desktop/THIRD_PARTY_NOTICES.md
    file_info:
      mode: 0644
  - src: $REPO_ROOT/LICENSE
    dst: /usr/share/doc/conduit-desktop/copyright
    packager: deb
    file_info:
      mode: 0644
  - src: $REPO_ROOT/LICENSE
    dst: /usr/share/licenses/conduit-desktop/LICENSE
    packager: rpm
    file_info:
      mode: 0644
EOF
  for n in $icon_sizes; do
    cat <<EOF
  - src: $here/icons/${n}x$n/conduit-desktop.png
    dst: /usr/share/icons/hicolor/${n}x$n/apps/conduit-desktop.png
    file_info:
      mode: 0644
EOF
  done
} >"$config"

nfpm="$(nfpm_bin)"
for packager in deb rpm; do
  log "nfpm: $packager"
  "$nfpm" package --config "$config" --packager "$packager" --target "$out/"
done
log "packages in $out:"
for f in "$out"/*.deb "$out"/*.rpm; do
  printf '  %s (%s, SHA-256 %s; unsigned)\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" \
    "$(sha256sum "$f" | awk '{print $1}')" >&2
done
