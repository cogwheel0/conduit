#!/bin/sh
# The `--e2e dictation` pass, which needs two launches of one profile:
#
#   crates/app/e2e-dictation.sh --shots /tmp/shots
#
# 1. `--e2e dictation`: a fresh profile signs in to the local Open WebUI
#    (tool/local_owui), dictates with WAV files standing in for the
#    microphone (spoken by `say` at test time), and quits in the middle of
#    a dictation, as a crash would.
# 2. `--e2e dictation-recovered`: the same profile opens again and finds
#    that recording kept with its draft.
#
# CONDUIT_USER_DATA must name the profile (both launches use it); set
# CONDUIT_WHISPER_LIB to a built libconduit_whisper for the Whisper step.
# Arguments go to run.sh; `--shots` is required.
set -eu
cd "$(dirname "$0")/../.."
shots=
prev=
for arg in "$@"; do
  if [ "$prev" = --shots ]; then shots=$arg; fi
  prev=$arg
done
if [ -z "$shots" ] || [ -z "${CONDUIT_USER_DATA:-}" ]; then
  echo "usage: CONDUIT_USER_DATA=<profile> $0 --shots <dir> [run.sh arguments]" >&2
  exit 64
fi
# The first launch quits in the middle of a dictation, as a crash would,
# so nothing stops its conduitd the way a quit does: the daemon has to see
# its app is gone and end by itself. After each launch the profile's
# daemons get 20 s to do so; one still running then is a leftover: it is
# recorded (ps, a `sample` beside the shots) and stopped (SIGTERM, then
# SIGKILL), so the pass never leaves one running.
daemons() { pgrep -f "conduitd.*--user-data $CONDUIT_USER_DATA" || true; }
stop_daemons() {
  i=0
  while [ $i -lt 40 ] && [ -n "$(daemons)" ]; do sleep 0.5; i=$((i + 1)); done
  pids=$(daemons)
  if [ -z "$pids" ]; then
    echo "e2e-dictation: no conduitd left on the profile" >&2
    return 0
  fi
  echo "e2e-dictation: conduitd still running 20 s after its app ended ($pids); stopping it" >&2
  for pid in $pids; do
    ps -o pid=,ppid=,etime=,stat= -p "$pid" >&2 || true
    sample "$pid" 1 -file "$shots/conduitd-$pid.sample.txt" >/dev/null 2>&1 || true
  done
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  i=0
  while [ $i -lt 20 ] && [ -n "$(daemons)" ]; do sleep 0.5; i=$((i + 1)); done
  pids=$(daemons)
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -KILL $pids 2>/dev/null || true
}
rc=0
crates/app/run.sh "$@" --e2e dictation || rc=1
stop_daemons
crates/app/run.sh "$@" --e2e dictation-recovered || rc=1
stop_daemons
exit $rc
