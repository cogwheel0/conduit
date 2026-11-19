#!/usr/bin/env bash
# A fake LibreChat server (fake_librechat.py, standard library only) with
# invented users, chats, prompts and memories, for the daemon's tests and the
# desktop app's E2E passes. No docker needed.
#
#   tool/local_librechat/librechat.sh start    start in the background
#   tool/local_librechat/librechat.sh stop     stop it
#   tool/local_librechat/librechat.sh reset    stop, set the log aside, start
#   tool/local_librechat/librechat.sh status   what runs where
#   tool/local_librechat/librechat.sh env      print the env file's path
#
# Options, also read from the environment:
#   --dir DIR    the instance: pid, log, env file
#                (CONDUIT_LIBRECHAT_DIR, default $CONDUIT_DEV_CACHE/local-librechat)
#   --port N     the server's port (CONDUIT_LIBRECHAT_PORT, default 19213)
#
# The env file (mode 600) names the server and its invented accounts:
# LIBRECHAT_URL, LIBRECHAT_2FA_EMAIL/_PASSWORD/_CODE/_BACKUP_CODE,
# LIBRECHAT_EMAIL/_PASSWORD (no two-step verification).
#
# Nothing is ever deleted: reset moves the old log into $DIR/old/.
set -euo pipefail

TOOL_DIR=$(cd "$(dirname "$0")" && pwd)
if [ "$(uname -s)" = Darwin ]; then
  default_cache="$HOME/Library/Caches/conduit-dev"
else
  default_cache="${XDG_CACHE_HOME:-$HOME/.cache}/conduit-dev"
fi
CACHE=${CONDUIT_DEV_CACHE:-$default_cache}
DIR=${CONDUIT_LIBRECHAT_DIR:-$CACHE/local-librechat}
PORT=${CONDUIT_LIBRECHAT_PORT:-19213}
PYTHON=${CONDUIT_LIBRECHAT_PYTHON:-python3}

command=${1:-}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case $1 in
    --dir) DIR=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

PID=$DIR/fake_librechat.pid
LOG=$DIR/fake_librechat.log
ENV_FILE=${CONDUIT_LIBRECHAT_ENV:-$DIR/local-librechat.env}
URL="http://127.0.0.1:$PORT"

running() {
  [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null
}

write_env() {
  umask 077
  cat >"$ENV_FILE" <<EOF
LIBRECHAT_URL=$URL
LIBRECHAT_2FA_EMAIL=rowan@example.test
LIBRECHAT_2FA_PASSWORD=lantern-harbour-42
LIBRECHAT_2FA_CODE=246810
LIBRECHAT_2FA_BACKUP_CODE=fern-quartz-01
LIBRECHAT_EMAIL=kit@example.test
LIBRECHAT_PASSWORD=kite-meadow-77
EOF
}

start() {
  mkdir -p "$DIR"
  if running; then
    echo "already running (pid $(cat "$PID")) on $URL"
    return
  fi
  write_env
  nohup "$PYTHON" -I "$TOOL_DIR/fake_librechat.py" --port "$PORT" --log "$LOG" \
    >>"$DIR/stdout.log" 2>&1 &
  echo $! >"$PID"
  for _ in $(seq 1 50); do
    if curl -sf "$URL/health" >/dev/null 2>&1; then
      echo "fake LibreChat on $URL (pid $(cat "$PID"))"
      return
    fi
    sleep 0.1
  done
  echo "fake LibreChat did not start; see $DIR/stdout.log" >&2
  exit 1
}

stop() {
  if running; then
    kill "$(cat "$PID")" 2>/dev/null || true
    for _ in $(seq 1 30); do
      running || break
      sleep 0.1
    done
  fi
  [ -f "$PID" ] && mv "$PID" "$PID.stopped"
  echo "stopped"
}

case $command in
  start) start ;;
  stop) stop ;;
  reset)
    stop
    if [ -f "$LOG" ]; then
      mkdir -p "$DIR/old"
      mv "$LOG" "$DIR/old/fake_librechat.$(date +%Y%m%d-%H%M%S).log"
    fi
    start
    ;;
  status)
    if running; then echo "running (pid $(cat "$PID")) on $URL"; else echo "stopped"; fi
    ;;
  env) echo "$ENV_FILE" ;;
  *)
    sed -n '2,20p' "$0" >&2
    exit 64
    ;;
esac
