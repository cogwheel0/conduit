#!/usr/bin/env bash
# Checks that owui.sh keeps a running instance on the ports it was started
# on: a command given another --port is refused, so seed and chat never
# reach whatever listens there; env (like stop, status and reset) is not.
#
#   tool/local_owui/ports_test.sh
#
# Starts and stops only a `sleep` of its own, standing in for the server.
# It points owui.sh at a venv that does not exist, so even with the check
# removed, seed stops before it can send anything to a real listener.
set -euo pipefail
tool=$(cd "$(dirname "$0")" && pwd)
. "$tool/pids.sh"

dir=$(mktemp -d)
trap 'kill "${s:-}" 2>/dev/null || true; rm -rf "${dir:?}"' EXIT
mkdir -p "$dir/state"
printf '%s\n' 8150 > "$dir/state/port"
printf '%s\n' 8151 > "$dir/state/model_port"
printf '%s\n' 8152 > "$dir/state/hermes_port"
printf '%s\n' 8153 > "$dir/state/terminal_port"
nohup sleep 60 > /dev/null 2>&1 &
s=$!
pid_record "$dir/state/server.pid" "$s"
# Only the fixture's ports and paths count, whatever the shell exports.
unset CONDUIT_OWUI_PORT CONDUIT_OWUI_MODEL_PORT CONDUIT_OWUI_HERMES_PORT \
  CONDUIT_OWUI_TERMINAL_PORT CONDUIT_OWUI_DIR CONDUIT_OWUI_ENV
export CONDUIT_OWUI_VENV="$dir/no-venv"
failures=0

out=$("$tool/owui.sh" seed --dir "$dir" --port 9000 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && [[ $out == *"runs with port 8150, not 9000"* ]]; then
  echo 'ok    seed with another port is refused'
else
  echo "FAIL  seed with another port is refused (exit $rc: $out)"; failures=$((failures + 1))
fi

out=$("$tool/owui.sh" seed --dir "$dir" --model-port 9001 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && [[ $out == *"runs with model_port 8151, not 9001"* ]]; then
  echo 'ok    seed with another model port is refused'
else
  echo "FAIL  seed with another model port is refused (exit $rc: $out)"; failures=$((failures + 1))
fi

out=$("$tool/owui.sh" seed --dir "$dir" --terminal-port 9003 2>&1) && rc=0 || rc=$?
if [ "$rc" = 1 ] && [[ $out == *"runs with terminal_port 8153, not 9003"* ]]; then
  echo 'ok    seed with another terminal port is refused'
else
  echo "FAIL  seed with another terminal port is refused (exit $rc: $out)"; failures=$((failures + 1))
fi

if "$tool/owui.sh" env --dir "$dir" --port 9000 > /dev/null 2>&1; then
  echo 'ok    env with another port is allowed'
else
  echo 'FAIL  env with another port is allowed'; failures=$((failures + 1))
fi

[ "$failures" = 0 ] && echo 'ports: all ok' || { echo "ports: $failures failed"; exit 1; }
