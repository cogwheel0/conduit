#!/bin/bash
# Smoke-tests the Linux packages the way a user meets them.
#
#   desktop/packaging/linux/smoke.sh PACKAGE.deb [WORK]
#       (Debian or Ubuntu, with sudo; CI's install smoke, or a test VM)
#   desktop/packaging/linux/smoke.sh --container PACKAGE.deb|PACKAGE.rpm
#       (as root in a clean distribution container)
#
# With a .deb:
# 1. Installs it with apt (which resolves its dependencies), and checks the
#    install folder (winlinux.py layout), the /usr/bin link, the desktop
#    entry (conduit:// registered in mimeinfo.cache) and the icons; every
#    library the binaries need is found.
# 2. The installed app refuses the test harness's flags (exit 64), and runs
#    its --smoke pass under Xvfb, on a session bus of its own with GNOME
#    Keyring as the Secret Service the app keeps its key in, on a profile of
#    its own in WORK: exit code 0 and "SMOKE passed". No conduitd from the
#    package runs afterwards. The keyring is the smoke's own (WORK), never
#    the user's: an unencrypted "login" keyring that is the default, so
#    nothing prompts; secret-tool (libsecret-tools), when installed, checks
#    it stores and finds a secret before the app starts.
# 3. Removes the package: none of its files is left, conduit:// is no longer
#    registered, and the user's data folder is still there.
#
# With --container: installs the package without recommended ones, checks
# every library resolves and the app starts (it refuses --e2e, exit 64),
# removes it and checks none of its files is left. Nothing else is needed
# in the container (no python3, no display).
#
# The .deb mode installs into /usr and removes the package at the end, and
# the app runs on a profile in WORK (default: a new folder in /tmp).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../macos/lib.sh
. "$here/../macos/lib.sh"

app_dir=/usr/lib/conduit
app=$app_dir/conduit-desktop
daemon=$app_dir/conduitd/bin/conduitd
entry=/usr/share/applications/conduit-desktop.desktop
icon_sizes="16 24 32 48 64 128 256 512"
installed=("$app_dir" /usr/bin/conduit-desktop "$entry")
for n in $icon_sizes; do installed+=("/usr/share/icons/hicolor/${n}x$n/apps/conduit-desktop.png"); done

# Every library the package's binaries need is found.
libraries_resolve() {
  local f missing=""
  for f in "$app" "$daemon" "$app_dir"/conduitd/lib/*.so*; do
    missing+="$(ldd "$f" | awk -v f="$f" '/not found/ {print "  " f ": " $1}')"
  done
  [ -z "$missing" ] || die "libraries not found:
$missing"
  log "every library the binaries need resolves"
}

# Each harness flag ends the launch with 64 before anything opens.
refuses_harness_flags() {
  local scratch="$1" flag status
  for flag in --e2e --capture --probe --fixture --chat-fixture; do
    status=0
    CONDUIT_FLAVOR=dev CONDUIT_USER_DATA="$scratch/user-data" CONDUIT_LOGS="$scratch/logs" \
      timeout 20 /usr/bin/conduit-desktop "$flag" x >/dev/null 2>&1 || status=$?
    [ "$status" = 64 ] || die "$flag x: exit $status, not 64 (a build without the test harness refuses it)"
  done
  log "refuses --e2e, --capture, --probe, --fixture, --chat-fixture (exit 64)"
}

# Nothing of the package's is left.
none_left() {
  local path left=""
  for path in "${installed[@]}"; do
    if [ -e "$path" ] || [ -L "$path" ]; then left+="  $path"$'\n'; fi
  done
  [ -z "$left" ] || die "still there after the removal:
$left"
  log "none of the package's files is left"
}

if [ "${1:-}" = --container ]; then
  package="${2:?usage: smoke.sh --container PACKAGE.deb|PACKAGE.rpm}"
  case "$package" in
    *.deb)
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$package" >/dev/null
      ;;
    *.rpm) dnf install -y -q --setopt=install_weak_deps=False "$package" ;;
    *) die "not a .deb or an .rpm: $package" ;;
  esac
  log "installed $(basename "$package") ($(. /etc/os-release && printf '%s' "$PRETTY_NAME"))"
  libraries_resolve
  refuses_harness_flags "$(mktemp -d)"
  case "$package" in
    *.deb) DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq conduit-desktop >/dev/null ;;
    *.rpm) dnf remove -y -q conduit-desktop ;;
  esac
  none_left
  log "container check passed"
  exit 0
fi

package="${1:?usage: smoke.sh PACKAGE.deb [WORK] | --container PACKAGE}"
case "$package" in
  *.deb) ;;
  *) die "the full smoke installs a .deb (an .rpm: --container)" ;;
esac
package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"
work="${2:-$(mktemp -d "${TMPDIR:-/tmp}/conduit-smoke.XXXXXX")}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"

# 1. Install.
log "installing $(basename "$package")"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package" >/dev/null
python3 -I "$here/../winlinux.py" layout "$app_dir" --os linux
[ "$(readlink -f /usr/bin/conduit-desktop)" = "$app" ] || die "/usr/bin/conduit-desktop doesn't lead to $app"
if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$entry"; fi
grep -q '^x-scheme-handler/conduit=.*conduit-desktop\.desktop' /usr/share/applications/mimeinfo.cache ||
  die "conduit:// is not registered (mimeinfo.cache; desktop-file-utils' trigger)"
for n in $icon_sizes; do
  [ -f "/usr/share/icons/hicolor/${n}x$n/apps/conduit-desktop.png" ] || die "no ${n}x$n icon"
done
log "the /usr/bin link, the desktop entry (conduit:// registered) and the icons"
libraries_resolve

# 2. The installed app.
refuses_harness_flags "$work/harness-check"
log "the app's --smoke pass (profile in $work/smoke)"
mkdir -p "$work/smoke"
report="$work/smoke/report.txt"
# GNOME Keyring prompts to create a default keyring that doesn't exist, and
# the app's key lookup would wait on that prompt. So its data folder (only
# the daemon gets this XDG_DATA_HOME) holds an unencrypted "login" keyring
# named the default, and its control socket goes in a runtime folder of its
# own: a running keyring of the user's is never reached.
keyring_data="$work/keyring-data"
mkdir -p "$keyring_data/keyrings" "$work/runtime"
chmod 700 "$keyring_data/keyrings" "$work/runtime"
printf '[keyring]\ndisplay-name=login\nctime=0\nmtime=0\nlock-on-idle=false\nlock-after=false\n' \
  >"$keyring_data/keyrings/login.keyring"
printf 'login' >"$keyring_data/keyrings/default"
status=0
env -u CONDUITD_PATH XDG_RUNTIME_DIR="$work/runtime" \
  CONDUIT_USER_DATA="$work/smoke/user-data" CONDUIT_LOGS="$work/smoke/logs" \
  xvfb-run -a -s '-screen 0 1440x900x24' \
  dbus-run-session -- sh -c '
    XDG_DATA_HOME="$2" gnome-keyring-daemon --components=secrets >/dev/null || exit 70
    if command -v secret-tool >/dev/null; then
      printf probe | timeout 20 secret-tool store --label="Conduit smoke probe" conduit-smoke probe &&
        [ "$(timeout 20 secret-tool lookup conduit-smoke probe)" = probe ] || exit 71
    fi
    exec /usr/bin/conduit-desktop --smoke "$1"' sh "$report" "$keyring_data" >"$work/smoke/run.log" 2>&1 ||
  status=$?
case "$status" in
  70 | 71)
    tail -n 30 "$work/smoke/run.log" >&2
    [ "$status" = 70 ] && die "gnome-keyring-daemon didn't start"
    die "the smoke's keyring didn't store and find a secret without a prompt (secret-tool)"
    ;;
esac
cat "$report" 2>/dev/null || true
if [ "$status" != 0 ] || [ "$(tail -n 1 "$report" 2>/dev/null)" != "SMOKE passed" ] ||
  grep -q '^SMOKE FAILED' "$report" 2>/dev/null; then
  tail -n 60 "$work/smoke/run.log" >&2
  for f in "$work"/smoke/logs/*.log; do
    [ -f "$f" ] && { printf -- '--- %s\n' "$f" >&2; tail -n 60 "$f" >&2; }
  done
  die "the app's smoke pass failed (exit $status)"
fi
# Started through the /usr/bin link, the app found conduitd beside its own
# binary: only a packaged release build runs in the production flavour.
grep -q 'Conduit Desktop .* (Production), userData ' "$work/smoke/logs/conduit-desktop.log" ||
  die "the installed app didn't run in the production flavour (it found no packaged conduitd)"
# By executable, exactly (never a pattern over command lines).
for proc in /proc/[0-9]*; do
  if [ "$(readlink "$proc/exe" 2>/dev/null)" = "$daemon" ]; then
    die "a conduitd from $app_dir (pid ${proc#/proc/}) still runs after the app quit"
  fi
done
log "smoke passed; no conduitd left"

# 3. Remove.
keep="${XDG_DATA_HOME:-$HOME/.local/share}/conduit/smoke-keep.txt"
mkdir -p "$(dirname "$keep")"
printf 'removing the package keeps the user data\n' >"$keep"
log "removing conduit-desktop"
sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq conduit-desktop >/dev/null
none_left
if grep -q 'conduit-desktop\.desktop' /usr/share/applications/mimeinfo.cache 2>/dev/null; then
  die "mimeinfo.cache still lists conduit-desktop.desktop"
fi
[ -f "$keep" ] || die "removing the package removed the user's data ($keep)"
log "removed: no files left, conduit:// unregistered; the user data stays"
log "smoke passed"
