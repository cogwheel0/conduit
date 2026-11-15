#!/bin/bash
# Smoke-tests a built Conduit.app (CI's PR job and local release checks).
#
#   desktop/packaging/macos/smoke.sh APP [--launch]
#
# 1. The bundle: Info.plist lints, Apple Silicon only, signature valid.
# 2. The bundled conduitd, as signed (hardened runtime, entitlements,
#    its own libsqlite3): apps/daemon/tool/smoke.dart starts it, checks the
#    handshake, and that it exits 0 on stdin EOF and on system.shutdown.
# 3. With --launch: the app itself runs its `--shots` smoke pass against a
#    throwaway profile (CONDUIT_USER_DATA, CONDUIT_LOGS): it starts the
#    bundled conduitd, connects, captures its windows and quits. Afterwards
#    no conduitd from this bundle may still run.
#
# Set CONDUIT_FLAVOR=dev to keep the master key in the dev Keychain item
# (on a Mac that should not get the release item); CI uses the default.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

app="${1:-}"
launch=0
[ "${2:-}" = "--launch" ] && launch=1
[ -d "$app" ] || die "usage: smoke.sh APP [--launch]"
app="$(cd "$app" && pwd)"
daemon="$app/Contents/Resources/conduitd/bin/conduitd"

log "bundle"
plutil -lint "$app/Contents/Info.plist"
lipo -info "$app/Contents/MacOS/Conduit" "$daemon"
while IFS= read -r f; do
  [ "$(lipo -archs "$f")" = "$ARCH" ] || die "$f is $(lipo -archs "$f")"
done < <(macho_files "$app")
codesign --verify --deep --strict --verbose=2 "$app"

log "conduitd handshake (apps/daemon/tool/smoke.dart)"
(cd "$REPO_ROOT/apps/daemon" && dart run tool/smoke.dart "$daemon")

if [ "$launch" = 1 ]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/conduit-smoke.XXXXXX")"
  mkdir -p "$scratch/user-data" "$scratch/logs" "$scratch/shots"
  log "app launch smoke (profile in $scratch)"
  status=0
  # The bundle's own conduitd, whatever CONDUITD_PATH says.
  env -u CONDUITD_PATH CONDUIT_USER_DATA="$scratch/user-data" CONDUIT_LOGS="$scratch/logs" \
    "$app/Contents/MacOS/Conduit" --shots "$scratch/shots" >"$scratch/run.log" 2>&1 || status=$?
  grep '^SMOKE' "$scratch/run.log" || true
  if [ "$status" != 0 ] || grep -q 'SMOKE FAILED' "$scratch/run.log" ||
    ! grep -q 'SMOKE status Connected' "$scratch/run.log"; then
    tail -n 60 "$scratch/run.log" >&2
    die "the app smoke failed (exit $status)"
  fi
  grep -h 'conduitd' "$scratch/logs"/*.log 2>/dev/null | grep -m3 -E 'spawn|ready|Resources/conduitd' || true
  sleep 1
  # By executable path, exactly (never a pattern over command lines).
  if ps -axo pid=,comm= | awk -v d="$daemon" '{p=$1; sub(/^ *[0-9]+ /, ""); if ($0 == d) print p}' | grep -q .; then
    die "a conduitd from this bundle is still running after the app quit"
  fi
  log "no orphan conduitd"
fi
log "smoke passed"
