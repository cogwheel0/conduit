#!/usr/bin/env bash
# Checks pids.sh: a recorded process is ours, and a stale pid, a reused pid,
# another process and an old one-line pid file are not; pid_stop stops only
# what is ours, and kills what ignores TERM.
#
#   tool/local_owui/pids_test.sh
#
# Starts and stops only `sleep` processes of its own.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/pids.sh"

dir=$(mktemp -d)
trap 'kill -KILL "${a:-}" "${b:-}" "${c:-}" "${d:-}" 2>/dev/null || true; rm -rf "${dir:?}"' EXIT
failures=0
check() { # NAME EXPECTED(0|1) FILE
  local got=0
  pid_alive "$3" || got=1
  if [ "$got" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}
expect() { # NAME EXPECTED ACTUAL
  if [ "$3" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1 (got '$3')"; failures=$((failures + 1)); fi
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

# pid_stop leaves a pid file alone whose process is not the recorded one.
expect 'a reused pid is not stopped' '' "$(pid_stop "$dir/reused.pid" 2)"
kill -0 "$b" 2>/dev/null && got=alive || got=gone
expect 'the process under a reused pid keeps running' alive "$got"

# pid_stop stops a recorded process with TERM.
expect 'a recorded process is stopped' stopped "$(pid_stop "$dir/a.pid" 4)"
wait "$a" 2>/dev/null || true

# A stale pid: the process has ended.
check 'a stale pid is not ours' 1 "$dir/a.pid"
expect 'a stale pid is not stopped again' '' "$(pid_stop "$dir/a.pid" 2)"

# A process that ignores TERM is killed once the wait is over. It inherits
# the ignored signal from this shell, and starts through nohup as owui.sh's
# processes do, so pid_record waits for the hand-over to `sleep`.
trap '' TERM
nohup sleep 62 > /dev/null 2>&1 &
c=$!
trap - TERM
pid_record "$dir/c.pid" "$c"
expect 'a process that ignores TERM is killed' killed "$(pid_stop "$dir/c.pid" 2)"
wait "$c" 2>/dev/null || true
check 'the killed process is gone' 1 "$dir/c.pid"
check 'a missing pid file is not ours' 1 "$dir/none.pid"

# A launcher that runs the program in its place only later, as Homebrew's
# `dart` script runs the Dart VM: pid_record records the launcher, and
# pid_refresh, called once the program serves, records the program. The
# hand-over happens when the test says so, through a fifo.
mkfifo "$dir/go"
nohup bash -c 'read -r _ < "$1"; exec sleep 63' _ "$dir/go" > /dev/null 2>&1 &
d=$!
pid_record "$dir/d.pid" "$d"
check 'a launcher not yet handed over is ours' 0 "$dir/d.pid"
echo go > "$dir/go"
# Waits (5 s at most) for the hand-over, as owui.sh waits for the port.
for _ in $(seq 1 100); do
  case $(ps -ww -p "$d" -o command= 2>/dev/null) in sleep\ 63*) break ;; esac
  sleep 0.05
done
check 'after the hand-over the launcher'"'"'s record no longer matches' 1 "$dir/d.pid"
pid_refresh "$dir/d.pid"
check 'a refreshed record names the program' 0 "$dir/d.pid"
expect 'the program is stopped' stopped "$(pid_stop "$dir/d.pid" 4)"
wait "$d" 2>/dev/null || true
# A stale record whose pid another process has taken since: its start time
# is not the recorded one (`lstart` counts seconds, so the record is made
# to name another start). Refreshing it must not adopt that process, which a
# later stop would then end.
{ echo "$b"; sed -n 2p "$dir/b.pid" | sed 's/^[A-Z][a-z][a-z] /Xxx /'; } > "$dir/taken.pid"
pid_refresh "$dir/taken.pid"
check 'refreshing a reused pid does not adopt its process' 1 "$dir/taken.pid"
kill -0 "$b" 2>/dev/null && got=alive || got=gone
expect 'the process under a refreshed reused pid keeps running' alive "$got"

# pid_record leaves no earlier record behind for a process already gone.
{ echo "$b"; sed -n 2p "$dir/b.pid"; } > "$dir/stale.pid"
pid_record "$dir/stale.pid" 999999
[ ! -e "$dir/stale.pid" ] && echo 'ok    recording a gone process clears the old record' || { echo 'FAIL  recording a gone process clears the old record'; failures=$((failures + 1)); }

pid_refresh "$dir/gone.pid"
[ ! -e "$dir/gone.pid" ] && echo 'ok    refreshing a missing pid file writes nothing' || { echo 'FAIL  refreshing a missing pid file writes nothing'; failures=$((failures + 1)); }

[ "$failures" = 0 ] && echo 'pids: all ok' || { echo "pids: $failures failed"; exit 1; }
