#!/usr/bin/env bash
# Checks that owui.sh start (and so up) refuses a running server that says
# it runs another Open WebUI version than the venv has, as one started
# before a `setup` that installed a newer version does, and leaves it
# running; and that a server of the venv's own version is "already running".
#
#   tool/local_owui/version_test.sh
#
# Starts and stops only a server of its own: python3's http.server on a free
# loopback port, serving a stand-in /api/config. The venv is a bare one with
# an open-webui install record and no Open WebUI in it.
set -euo pipefail
tool=$(cd "$(dirname "$0")" && pwd)
. "$tool/pids.sh"

dir=$(mktemp -d)
trap 'kill "${s:-}" 2>/dev/null || true; rm -rf "${dir:?}"' EXIT
python3 -m venv "$dir/venv"
site=$("$dir/venv/bin/python" -I -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
mkdir -p "$site/open_webui-0.13.4.dist-info"
printf 'Metadata-Version: 2.1\nName: open-webui\nVersion: 0.13.4\n' \
  > "$site/open_webui-0.13.4.dist-info/METADATA"
printf '#!/bin/sh\nexit 1\n' > "$dir/venv/bin/open-webui"
chmod +x "$dir/venv/bin/open-webui"

port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$dir/www/api" "$dir/state"
printf '%s\n' "$port" > "$dir/state/port"
printf 'http://127.0.0.1:%s\n' "$port" > "$dir/state/url"
nohup python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$dir/www" \
  > /dev/null 2>&1 &
s=$!
pid_record "$dir/state/server.pid" "$s"
serves() {
  printf '{"status":true,"name":"Open WebUI","version":"%s"}' "$1" > "$dir/www/api/config"
}
serves 0.13.2
for _ in $(seq 1 50); do
  curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$port/api/config" && break
  sleep 0.1
done
# Only the fixture's ports and paths count, whatever the shell exports.
unset CONDUIT_OWUI_PORT CONDUIT_OWUI_MODEL_PORT CONDUIT_OWUI_HERMES_PORT \
  CONDUIT_OWUI_TERMINAL_PORT CONDUIT_OWUI_PROXY_PORT CONDUIT_OWUI_DIR CONDUIT_OWUI_ENV
export CONDUIT_OWUI_VENV="$dir/venv"
failures=0

for command in start up; do
  out=$("$tool/owui.sh" "$command" --dir "$dir" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = 1 ] && [[ $out == *"runs Open WebUI 0.13.2, but $dir/venv has 0.13.4"* ]] &&
    pid_alive "$dir/state/server.pid"; then
    echo "ok    $command refuses a running server of another version, and leaves it running"
  else
    echo "FAIL  $command refuses a running server of another version (exit $rc: $out)"
    failures=$((failures + 1))
  fi
done

serves 0.13.4
out=$("$tool/owui.sh" start --dir "$dir" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [[ $out == "already running at http://127.0.0.1:$port" ]]; then
  echo 'ok    start finds a running server of the same version already running'
else
  echo "FAIL  start finds a running server of the same version already running (exit $rc: $out)"
  failures=$((failures + 1))
fi

[ "$failures" = 0 ] && echo 'version: all ok' || { echo "version: $failures failed"; exit 1; }
