#!/bin/bash
# Generates THIRD_PARTY_NOTICES.md for Conduit Desktop: the components bundled
# directly (vendored gpui-pre, Sparkle, whisper.cpp, SQLite, the Dart
# runtime, mermaid, Chart.js, noVNC, Lucide, KaTeX fonts), the Rust crates in
# the conduit-desktop binary (cargo-about) and the Dart packages in conduitd.
#
#   desktop/packaging/notices/notices.sh [--out FILE]
#   desktop/packaging/notices/notices.sh --check
#
# The file is not committed. packaging/macos/bundle.sh writes it into each
# bundle (Contents/Resources/THIRD_PARTY_NOTICES.md); without --out it goes
# to desktop/target/notices/THIRD_PARTY_NOTICES.md. --check writes it to a
# temporary folder only (CI runs it).
#
# Either way it fails unless the licence set is complete:
# * every crate cargo builds into the app for Apple Silicon (its normal
#   dependencies, as `cargo tree` resolves them) is listed with its licence,
#   except the workspace's own crates and the vendored gpui-pre (listed
#   with the bundled components);
# * every licence is one about.toml accepts (cargo-about refuses others);
# * every Dart package compiled into conduitd has a licence file;
# * every bundled component's licence text is found.
#
# Needs: cargo-about 0.9 (`cargo install cargo-about --locked --features cli`),
# dart (with `flutter pub get` done at the repository root), python3, and
# the network the first time (crates.io for Cargo.lock's crates, GitHub for
# Sparkle's licence).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../macos/lib.sh
. "$here/../macos/lib.sh"

check=0
out="$DESKTOP_DIR/target/notices/THIRD_PARTY_NOTICES.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1 ;;
    --out) out="$2"; shift ;;
    *) die "unknown argument: $1 (see the header of $0)" ;;
  esac
  shift
done
work="$(mktemp -d "${TMPDIR:-/tmp}/conduit-notices.XXXXXX")"
[ "$check" = 1 ] && out="$work/THIRD_PARTY_NOTICES.md"
mkdir -p "$(dirname "$out")"

command -v cargo-about >/dev/null || die "cargo-about is missing: cargo install cargo-about --locked --features cli"

# cargo-about, cargo tree and cargo metadata below run offline, so they all
# read the same locked set; offline, they need every crate in Cargo.lock
# downloaded already, for every target (not only what a build fetched), and
# a fresh machine or an empty CI cache has none. Fetch what is missing
# first: exactly the locked versions, checksummed; nothing when the
# registry is full.
log "Cargo.lock's crates (cargo fetch --locked)"
(cd "$DESKTOP_DIR" && cargo fetch --locked)

log "Rust crates (cargo-about)"
(cd "$DESKTOP_DIR" && cargo about generate --offline --locked \
  -c packaging/notices/about.toml -m crates/app/Cargo.toml \
  packaging/notices/about.hbs -o "$work/rust.md") 2>"$work/cargo-about.log" || {
  cat "$work/cargo-about.log" >&2
  die "cargo about failed"
}
# What the notices must cover: the app's normal dependencies on the release
# target, as cargo resolves them.
# --color never: CI sets CARGO_TERM_COLOR=always, which would wrap the
# `(*)` and `(proc-macro)` markers in escape codes.
(cd "$DESKTOP_DIR" && cargo --color never tree -p conduit-desktop -e normal --target "$RUST_TARGET" \
  --prefix none --format '{p}' --locked --offline) >"$work/crates.txt"

log "Dart packages (conduitd)"
config="$REPO_ROOT/.dart_tool/package_config.json"
[ -f "$config" ] || die "no $config: run flutter pub get at the repository root"
(cd "$REPO_ROOT/apps/daemon" && dart pub deps --json) >"$work/pub-deps.json"

# The Dart SDK whose runtime conduitd embeds (standalone or Flutter's).
dart_bin="$(command -v dart)"
while [ -L "$dart_bin" ]; do
  link="$(readlink "$dart_bin")"
  case "$link" in /*) dart_bin="$link" ;; *) dart_bin="$(dirname "$dart_bin")/$link" ;; esac
done
sdk_license=""
for candidate in "$(dirname "$dart_bin")/../LICENSE" "$(dirname "$dart_bin")/cache/dart-sdk/LICENSE"; do
  if [ -f "$candidate" ] && grep -q 'Dart project authors' "$candidate"; then
    sdk_license="$candidate"
    break
  fi
done
[ -n "$sdk_license" ] || die "cannot find the Dart SDK's LICENSE next to $dart_bin"

registry="$(cd "$DESKTOP_DIR" && cargo metadata --format-version 1 --locked --offline |
  python3 -I -c 'import json,sys,os; m=json.load(sys.stdin); print(next(os.path.dirname(os.path.dirname(p["manifest_path"])) for p in m["packages"] if p["name"]=="gpui-kit-assets"))')"

python3 -I "$here/notices.py" \
  --rust "$work/rust.md" \
  --expected-crates "$work/crates.txt" \
  --pub-deps "$work/pub-deps.json" \
  --package-config "$config" \
  --sparkle-license "$(sparkle_dir)/LICENSE" \
  --dart-sdk-license "$sdk_license" \
  --cargo-registry "$registry" \
  --repo "$REPO_ROOT" \
  --out "$out"

if [ "$check" = 1 ]; then
  log "the licence set is complete (checked in $out)"
fi
