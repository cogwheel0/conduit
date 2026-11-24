#!/bin/bash
# Smoke-tests the Linux packages the way a user meets them.
#
#   desktop/packaging/linux/smoke.sh [--update-feed DIR [--update-feed-port N]] PACKAGE.deb [WORK]
#       (Debian or Ubuntu, with sudo; CI's install smoke, or a test VM)
#   desktop/packaging/linux/smoke.sh --container PACKAGE.deb|PACKAGE.rpm
#       (as root in a clean distribution container)
#
# With a .deb:
# 1. Installs it with apt (which resolves its dependencies), and checks the
#    install folder (winlinux.py layout), the /usr/bin link, the desktop
#    entry (conduit:// registered in mimeinfo.cache), the icons and the
#    third-party notices; every library the binaries need is found. No file
#    type the app opens gets another default app: GIO's choice (GNOME's file
#    manager's, and xdg-open's there), asked before and after in a desktop
#    of the smoke's own arranged as GNOME's, is the same for each.
# 2. The installed app refuses the test harness's flags (exit 64), and runs
#    its --smoke pass under Xvfb, on a session bus of its own with GNOME
#    Keyring as the Secret Service the app keeps its key in, on a profile of
#    its own in WORK: exit code 0 and "SMOKE passed", and its windows carry
#    the desktop entry's StartupWMClass as their WM_CLASS (docks group them
#    with the launcher by it). No conduitd from the
#    package runs afterwards. The keyring is the smoke's own (WORK), never
#    the user's: an unencrypted "login" keyring that is the default, so
#    nothing prompts; secret-tool (libsecret-tools), when installed, checks
#    it stores and finds a secret before the app starts.
#    With --update-feed, DIR is served on 127.0.0.1 port N (default 8471)
#    while the pass runs, and its update check must find nothing newer: a
#    package built with that feed's URL and key (package.sh
#    --update-feed-url, --update-public-key) and DIR holding
#    appcast-linux.xml, signed, for no newer version (CI's rehearsal).
# 3. Removes the package: none of its files is left, conduit:// is no longer
#    registered, every file type's default app is what it was before the
#    install, and the user's data folder is still there.
#
# With --container: installs the package without recommended ones, checks
# every library resolves, the notices are there (the doc folder's copy may
# be missing only where the image excludes documentation) and the app
# starts (it refuses --e2e, exit 64), removes it and checks none of its
# files is left. Nothing else is needed in the container (no python3, no
# display).
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
lib_notices=$app_dir/THIRD_PARTY_NOTICES.md
notices=/usr/share/doc/conduit-desktop/THIRD_PARTY_NOTICES.md
icon_sizes="16 24 32 48 64 128 256 512"
installed=("$app_dir" /usr/bin/conduit-desktop "$entry" "$notices")
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

# Whether this system drops packages' documentation: dpkg's path-exclude
# (minimized Ubuntu and Debian images), rpm's nodocs (dnf's tsflags).
docs_excluded() {
  if grep -hqs '^path-exclude=/usr/share/doc' /etc/dpkg/dpkg.cfg.d/*; then return 0; fi
  if command -v rpm >/dev/null && [ "$(rpm --eval '%{_excludedocs}' 2>/dev/null)" = 1 ]; then
    return 0
  fi
  grep -qs '^tsflags=.*nodocs' /etc/dnf/dnf.conf /etc/yum.conf
}

# The package carries the Linux build's third-party notices: beside the app
# always (what Settings › About opens), and in the doc folder unless, with
# docs-may-drop, this system excludes documentation.
has_notices() {
  local heading="# Third-party notices: Conduit Desktop for Linux"
  [ "$(head -n 1 "$lib_notices" 2>/dev/null)" = "$heading" ] ||
    die "no Linux third-party notices at $lib_notices"
  if [ "$(head -n 1 "$notices" 2>/dev/null)" = "$heading" ]; then
    log "the third-party notices are in $lib_notices and $notices"
  elif [ -e "$notices" ]; then
    die "$notices is not the Linux third-party notices"
  elif [ "${1:-}" = docs-may-drop ] && docs_excluded; then
    log "the third-party notices are in $lib_notices ($notices dropped: this system excludes documentation)"
  else
    die "no Linux third-party notices at $notices"
  fi
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

# A desktop of the smoke's own for GIO's default-app lookup, arranged as
# GNOME's: defaults (gnome-mimeapps.list) for text/plain, PDF, the images
# and application/zip only, all a stand-in app of the smoke's. Markdown,
# CSV and JSON reach theirs through text/plain, and the office files theirs
# through application/zip (the Archive Manager on GNOME), so an entry that
# lists them itself would take them over.
mime_desktop() {
  local root="$1/mime" t
  mkdir -p "$root/home" "$root/config" "$root/config-dirs" "$root/data" "$root/system/applications"
  printf '[Desktop Entry]\nType=Application\nName=Smoke Viewer\nExec=true %%F\nNoDisplay=true\n' \
    >"$root/system/applications/conduit-smoke-viewer.desktop"
  {
    printf '[Default Applications]\n'
    for t in text/plain application/pdf image/png image/jpeg image/gif image/webp application/zip; do
      printf '%s=conduit-smoke-viewer.desktop\n' "$t"
    done
  } >"$root/system/applications/gnome-mimeapps.list"
  printf '%s\n' "$root"
}

# GIO's default app for type $2 in the smoke's desktop $1, with data
# folder $3 first when given.
gio_default() {
  env -i PATH="$PATH" LC_ALL=C HOME="$1/home" XDG_CURRENT_DESKTOP=GNOME \
    XDG_CONFIG_HOME="$1/config" XDG_CONFIG_DIRS="$1/config-dirs" XDG_DATA_HOME="$1/data" \
    XDG_DATA_DIRS="${3:+$3:}$1/system:/usr/local/share:/usr/share" \
    gio mime "$2" 2>/dev/null | sed -n 's/^Default application for .*: //p'
}

# Each type the app opens (winlinux.py types linux) and its default app
# there, one "type=app" a line ("type=" for none).
default_apps() {
  local t
  for t in $(python3 -I "$here/../winlinux.py" types linux); do
    printf '%s=%s\n' "$t" "$(gio_default "$1" "$t")"
  done
}

# The check sees a takeover: an entry that lists Markdown and a .docx
# itself, as the package's once did, becomes their default there.
sees_takeover() {
  local control="$1/control" t
  mkdir -p "$control/applications"
  printf '%s\n' '[Desktop Entry]' Type=Application 'Name=Smoke Takeover' 'Exec=true %F' NoDisplay=true \
    'MimeType=text/markdown;application/vnd.openxmlformats-officedocument.wordprocessingml.document;' \
    >"$control/applications/conduit-smoke-takeover.desktop"
  update-desktop-database "$control/applications"
  for t in text/markdown application/vnd.openxmlformats-officedocument.wordprocessingml.document; do
    [ "$(gio_default "$1" "$t" "$control")" = conduit-smoke-takeover.desktop ] ||
      die "an entry listing $t itself doesn't take it over in the smoke's desktop: the default-app check would prove nothing"
  done
}

# The default apps now are $2's (taken before the install).
same_default_apps() {
  local now
  now="$(default_apps "$1")"
  [ "$now" = "$2" ] || die "$3 changed default apps (before, then now):
$2
--
$now"
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

update_feed=""
update_port=8471
while [ $# -gt 0 ]; do
  case "$1" in
    --update-feed) update_feed="$(cd "$2" && pwd)"; shift 2 ;;
    --update-feed-port) update_port="$2"; shift 2 ;;
    *) break ;;
  esac
done

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
  # The root certificates came with it: the update notice reads over HTTPS.
  case "$package" in
    *.deb) dpkg -s ca-certificates >/dev/null 2>&1 ;;
    *.rpm) rpm -q ca-certificates >/dev/null 2>&1 ;;
  esac || die "ca-certificates didn't come with $(basename "$package")"
  log "ca-certificates came with it"
  has_notices docs-may-drop
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
command -v gio >/dev/null || die "the default-app check needs gio (libglib2.0-bin)"
command -v update-desktop-database >/dev/null ||
  die "the default-app check needs update-desktop-database (desktop-file-utils)"
[ -f /usr/share/mime/packages/freedesktop.org.xml ] ||
  die "the default-app check needs shared-mime-info (Markdown's and JSON's parent types)"
mime_root="$(mime_desktop "$work")"
defaults_before="$(default_apps "$mime_root")"
log "default apps before the install (a GNOME-like desktop of the smoke's):"
printf '%s\n' "$defaults_before" | sed 's/^/  /' >&2
for t in text/plain application/pdf; do
  printf '%s\n' "$defaults_before" | grep -qx "$t=conduit-smoke-viewer.desktop" ||
    die "GIO doesn't answer from the smoke's desktop ($t): the default-app check would prove nothing"
done
sees_takeover "$mime_root"
log "in that desktop, an entry listing Markdown and .docx itself takes them over (what the check looks for)"
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
same_default_apps "$mime_root" "$defaults_before" "installing the package"
log "no file type the app opens has another default app (Conduit stays in Open With)"
libraries_resolve
has_notices

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
server=""
if [ -n "$update_feed" ]; then
  [ -f "$update_feed/appcast-linux.xml" ] || die "no appcast-linux.xml in $update_feed"
  python3 -I -m http.server "$update_port" --bind 127.0.0.1 --directory "$update_feed" \
    >"$work/feed-server.log" 2>&1 &
  server=$!
  # Stopped however the smoke ends from here on.
  trap 'kill "$server" 2>/dev/null || true' EXIT
  # The pass checks once it has connected; the server answers well before.
  for _ in $(seq 50); do
    curl -fsS -o /dev/null "http://127.0.0.1:$update_port/appcast-linux.xml" 2>/dev/null && break
    sleep 0.2
  done
  curl -fsS -o /dev/null "http://127.0.0.1:$update_port/appcast-linux.xml" ||
    die "the update feed in $update_feed isn't served on port $update_port"
  log "serving $update_feed on 127.0.0.1:$update_port for the update check"
fi
command -v xwininfo >/dev/null || die "the WM_CLASS check needs xwininfo (x11-utils)"
wm_class="$(sed -n 's/^StartupWMClass=//p' "$entry")"
[ -n "$wm_class" ] || die "$entry names no StartupWMClass"
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
    # Every WM_CLASS (instance and class) on the display, sampled until the
    # desktop entry'"'"'s appears or the app ends: other clients, such as a
    # portal the session starts, may show a window first. Emptied first, so
    # a reused WORK never offers what an earlier run saw.
    : >"$3"
    /usr/bin/conduit-desktop --smoke "$1" &
    app=$!
    while kill -0 "$app" 2>/dev/null && ! grep -qx "$4 $4" "$3"; do
      { cat "$3"; xwininfo -root -tree 2>/dev/null |
        sed -n "s/.*: (\"\([^\"]*\)\" \"\([^\"]*\)\").*/\1 \2/p"; } | sort -u >"$3.next"
      mv "$3.next" "$3"
      sleep 0.2
    done
    wait "$app"' sh "$report" "$keyring_data" "$work/smoke/wm-class" "$wm_class" >"$work/smoke/run.log" 2>&1 ||
  status=$?
if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; fi
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
grep -qx "$wm_class $wm_class" "$work/smoke/wm-class" 2>/dev/null ||
  die "the app's windows carry WM_CLASS '$(tr '\n' ',' 2>/dev/null <"$work/smoke/wm-class")', not $entry's StartupWMClass ($wm_class)"
log "the app's windows carry WM_CLASS $wm_class, the desktop entry's StartupWMClass"
if [ -n "$update_feed" ]; then
  grep -qx 'SMOKE update check: up to date' "$report" ||
    die "the update notice didn't read the served feed and find nothing newer (see the report)"
  log "the update notice read the signed feed: nothing newer"
fi
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
same_default_apps "$mime_root" "$defaults_before" "removing the package"
[ -f "$keep" ] || die "removing the package removed the user's data ($keep)"
log "removed: no files left, conduit:// unregistered, the default apps as before; the user data stays"
log "smoke passed"
