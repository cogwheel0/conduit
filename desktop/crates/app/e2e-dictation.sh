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
rc=0
crates/app/run.sh "$@" --e2e dictation || rc=1
crates/app/run.sh "$@" --e2e dictation-recovered || rc=1
exit $rc
