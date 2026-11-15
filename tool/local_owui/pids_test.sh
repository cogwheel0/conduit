#!/usr/bin/env bash
# Checks pids.sh: a recorded process is ours, and a stale pid, a reused pid,
# another process and an old one-line pid file are not.
#
#   tool/local_owui/pids_test.sh
#
# Starts and stops only `sleep` processes of its own.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/pids.sh"

dir=$(mktemp -d)
trap 'kill "${a:-}" "${b:-}" 2>/dev/null || true; rm -rf "${dir:?}"' EXIT
failures=0
check() { # NAME EXPECTED(0|1) FILE
  local got=0
  pid_alive "$3" || got=1
  if [ "$got" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}

# Started through nohup, as owui.sh starts its processes.
nohup sleep 60 > /dev/null 2>&1 &
a=$!
pid_record "$dir/a.pid" "$a"
check 'the recorded process is ours' 0 "$dir/a.pid"

# Another program, such as one that took a dead process's pid. (`lstart`
# counts seconds, so it is not another `sleep 60` started this second.)
sleep 61 &
b=$!
pid_record "$dir/b.pid" "$b"

# A pid reused by another process: the pid is live, but what runs under it
# is not what was recorded.
{ echo "$b"; sed -n 2p "$dir/a.pid"; } > "$dir/reused.pid"
check 'a reused pid is not ours' 1 "$dir/reused.pid"

# The same command, started at another time.
{ echo "$a"; sed -n 2p "$dir/a.pid" | sed 's/^[A-Z][a-z][a-z] /Xxx /'; } > "$dir/other-start.pid"
check 'another start of the same command is not ours' 1 "$dir/other-start.pid"

# An old pid file with no identity line.
echo "$a" > "$dir/old.pid"
check 'a pid file without an identity is not ours' 1 "$dir/old.pid"

# A stale pid: the process has ended.
kill "$a"
wait "$a" 2>/dev/null || true
check 'a stale pid is not ours' 1 "$dir/a.pid"
check 'a missing pid file is not ours' 1 "$dir/none.pid"

[ "$failures" = 0 ] && echo 'pids: all ok' || { echo "pids: $failures failed"; exit 1; }
