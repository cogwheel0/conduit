#!/usr/bin/env bash
# Produces every generated artifact the desktop build needs, in dependency
# order, from a fresh clone.
#
#   ./scripts/bootstrap_desktop.sh
#
# Everything it writes is git-ignored. Re-running is safe and is the fastest
# way to recover from a half-finished build.
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$PWD"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found on PATH. See docs/BUILDING.md#requirements." >&2
  exit 1
fi

step 'Resolving the pub workspace'
# One resolve at the root covers every member; they share a single lockfile.
flutter pub get

step 'Generating mobile code (freezed, json_serializable, riverpod, drift)'
dart run build_runner build

step 'Generating conduit_core models'
# The freezed/json_serializable models moved out of lib/core/models, so
# their generated code is produced here now, not by the root build.
(cd packages/conduit_core && dart run build_runner build)

step 'Generating conduit_protocol DTOs'
(cd packages/conduit_protocol && dart run build_runner build)

step 'Converting ARB to slang input'
dart run tool/arb_to_slang.dart

step 'Generating desktop translations'
(cd apps/desktop_ui && dart run slang)

step 'Generating theme.css from the palette registry'
dart run conduit_theme:generate_theme_css

step 'Building conduitd'
# `dart build cli`, not `dart compile exe`: the latter refuses to run once a
# dependency has build hooks, and drift brings sqlite3, which has them.
(cd apps/daemon && dart build cli)

if command -v npm >/dev/null 2>&1; then
  step 'Installing Electron dependencies'
  (cd desktop/electron && npm ci)

  step 'Building the renderer bundle and the main process'
  (cd desktop/electron && npm run build)
else
  echo
  echo "npm not found; skipped the Electron shell." >&2
  echo "Install Node 22+ and run: cd desktop/electron && npm ci && npm run build" >&2
fi

printf '\n\033[1mReady.\033[0m Run the desktop app with:\n'
printf '  cd %s/desktop/electron && npm run dev\n' "$repo_root"
