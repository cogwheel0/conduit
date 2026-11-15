#!/bin/sh
# The `--e2e offline` pass, which needs two launches and a server that goes
# away between them:
#
#   crates/app/e2e-offline.sh --shots /tmp/shots
#
# 1. `--e2e offline-setup`: a fresh profile signs in to the local Open WebUI
#    (tool/local_owui) and quits.
# 2. While the app is closed, a chat is made on the server (`owui.sh chat`,
#    saved to <shots>/offline-chat/chat.json) and the server stops.
# 3. `--e2e offline`: the app opens with the server out of reach, conduitd is
#    restarted once while the window opens, and the pass starts the server
#    again and expects the app to catch up.
#
# Arguments go to run.sh; `--shots` is required. Both launches use one
# profile: CONDUIT_USER_DATA's when set, else a new scratch one (every other
# scripted launch gets a fresh profile of its own). The instance is
# CONDUIT_OWUI_DIR's, as for every pass. It is left running afterwards.
set -eu
cd "$(dirname "$0")/../.."
shots=
prev=
for arg in "$@"; do
  if [ "$prev" = --shots ]; then shots=$arg; fi
  prev=$arg
done
if [ -z "$shots" ]; then
  echo "usage: $0 --shots <dir> [run.sh arguments]" >&2
  exit 64
fi
if [ -z "${CONDUIT_USER_DATA:-}" ]; then
  profile="$(mktemp -d "${TMPDIR:-/tmp}/conduit-e2e-offline.XXXXXX")"
  CONDUIT_USER_DATA="$profile/user-data"
  CONDUIT_LOGS="${CONDUIT_LOGS:-$profile/logs}"
  export CONDUIT_USER_DATA CONDUIT_LOGS
  echo "e2e-offline: profile $profile"
fi
owui=../tool/local_owui/owui.sh
"$owui" up
crates/app/run.sh "$@" --e2e offline-setup
mkdir -p "$shots/offline-chat"
"$owui" chat "$shots/offline-chat" "Say the word: heron" > "$shots/offline-chat/drive.log"
"$owui" stop
crates/app/run.sh "$@" --e2e offline
