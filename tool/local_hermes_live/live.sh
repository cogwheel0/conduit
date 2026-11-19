#!/bin/zsh
# The fake GPT-Live vendor and its WebKit peer, for a local Hermes Desktop
# Gateway whose `voice.gpt_live.base_url` points here (README.md). macOS
# only: the peer runs in WebKit.
#
#   live.sh start [PORT]   build the peer host if needed, start both
#   live.sh stop
#   live.sh status
#   live.sh stats          what the peer heard and did (JSON)
#
# CONDUIT_GPT_LIVE_DIR holds the build, the logs and the pids
# (default ~/Library/Caches/conduit-dev/gpt-live); CONDUIT_GPT_LIVE_PORT
# the port (default 19335). The TURN relay on 127.0.0.1 takes the next port
# (CONDUIT_GPT_LIVE_TURN_PORT): the call's packets never leave loopback.
set -u
HERE=${0:A:h}
RUN=${CONDUIT_GPT_LIVE_DIR:-$HOME/Library/Caches/conduit-dev/gpt-live}
PORT=${2:-${CONDUIT_GPT_LIVE_PORT:-19335}}
TURN_PORT=${CONDUIT_GPT_LIVE_TURN_PORT:-$((PORT + 1))}
mkdir -p $RUN

running() {
  [ -f $RUN/$1.pid ] && kill -0 $(cat $RUN/$1.pid) 2>/dev/null
}

build() {
  if [ ! -x $RUN/peer-host ] || [ $HERE/peer_host.swift -nt $RUN/peer-host ]; then
    echo "building the peer host"
    swiftc -O -o $RUN/peer-host $HERE/peer_host.swift -framework AppKit -framework WebKit \
      > $RUN/build.log 2>&1 || { cat $RUN/build.log; return 1; }
  fi
}

stop() {
  for name in peer_host gpt_live; do
    if running $name; then
      kill $(cat $RUN/$name.pid) 2>/dev/null
    fi
  done
  for i in $(seq 1 20); do
    lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || lsof -nP -iUDP:$TURN_PORT >/dev/null 2>&1 || break
    sleep 0.25
  done
}

start() {
  build || return 1
  stop
  : > $RUN/gpt_live.log
  : > $RUN/peer_host.log
  nohup /usr/bin/python3 -I $HERE/fake_gpt_live.py $PORT --turn $TURN_PORT >> $RUN/gpt_live.log 2>&1 &
  echo $! > $RUN/gpt_live.pid
  for i in $(seq 1 40); do
    curl -sf -o /dev/null http://127.0.0.1:$PORT/stats && break
    sleep 0.25
  done
  nohup $RUN/peer-host http://127.0.0.1:$PORT/peer >> $RUN/peer_host.log 2>&1 &
  echo $! > $RUN/peer_host.pid
  # Up once the page asks for offers.
  for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:$PORT/stats | /usr/bin/python3 -I -c \
      'import json,sys; sys.exit(0 if json.load(sys.stdin)["polls"] > 0 else 1)' 2>/dev/null; then
      echo "fake GPT-Live up on $PORT (peer page waiting for offers)"
      return 0
    fi
    sleep 0.5
  done
  echo "the peer page never asked for an offer; see $RUN/peer_host.log"
  return 1
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  status)
    for name in gpt_live peer_host; do
      if running $name; then echo "$name running ($(cat $RUN/$name.pid))"; else echo "$name stopped"; fi
    done ;;
  stats) curl -sf http://127.0.0.1:$PORT/stats ;;
  *) echo "usage: live.sh start [PORT] | stop | status | stats"; exit 64 ;;
esac
