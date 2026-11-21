#!/usr/bin/env bash
# A throwaway local Open WebUI 0.13.4 with a fake model and synthetic seed
# data, for the daemon's live tests and the desktop app's E2E passes.
#
#   tool/local_owui/owui.sh setup          venv with open-webui (once, ~5 min)
#   tool/local_owui/owui.sh start          server and fake model, in the background
#   tool/local_owui/owui.sh seed           synthetic users, chats, prompts and a file
#   tool/local_owui/owui.sh up             start, then seed if it never was
#   tool/local_owui/owui.sh reset          stop, set the data aside, start, seed
#   tool/local_owui/owui.sh stop           stop both
#   tool/local_owui/owui.sh status         what runs where
#   tool/local_owui/owui.sh env            print the env file's path
#   tool/local_owui/owui.sh chat DIR TEXT  one chat turn, as the web client
#                                          sends it (drive_chat.py), into DIR
#   tool/local_owui/owui.sh showcase DIR   a stored chat with every rich block
#                                          (showcase.py), its ids into DIR
#   tool/local_owui/owui.sh media DIR URL  a stored chat with pictures and PDFs
#                                          from the site at URL (media_site.py)
#                                          and the server, and diagrams
#                                          (media_chat.py), its ids into DIR
#   tool/local_owui/owui.sh tool-permissions on|off
#                                          auto tool permissions on, or back as
#                                          they were (tool_permissions.py)
#   tool/local_owui/owui.sh peer COMMAND ARGS...
#                                          the second user in channels: post,
#                                          react, type, start a direct message,
#                                          or an app's card (channel_peer.py)
#   tool/local_owui/owui.sh two-step       two-step sign-in (TOTP) on, with
#                                          synthetic accounts that have, lack or
#                                          lost an authenticator, and one
#                                          awaiting approval (two_step.py);
#                                          restarts the server with persistent
#                                          config, which two-step needs
#   tool/local_owui/owui.sh proxy start|expire|stop
#                                          a fake sign-in proxy in front of the
#                                          server, whose session can be expired
#                                          (fake_proxy.py; --proxy-port N, the
#                                          proxy's sign-in page on N+1)
#
# Options, also read from the environment:
#   --dir DIR        the instance: data, logs, pids, secrets
#                    (CONDUIT_OWUI_DIR, default $CONDUIT_DEV_CACHE/local-owui;
#                    the daemon's tests read CONDUIT_OWUI_DIR, so set it to
#                    DIR for them too)
#   --port N         the server's port; the fake model takes the next one
#                    and the fake Hermes the one after (CONDUIT_OWUI_PORT,
#                    default 8150)
#   --model-port N   the fake model's port (CONDUIT_OWUI_MODEL_PORT)
#   --hermes-port N  the fake Hermes server's port (CONDUIT_OWUI_HERMES_PORT)
#   --terminal-port N  the fake Open Terminal's port, the server's port + 3
#                    by default (CONDUIT_OWUI_TERMINAL_PORT); Open WebUI
#                    offers it as the "Build box" terminal
#   --proxy-port N   the fake sign-in proxy's port (CONDUIT_OWUI_PROXY_PORT,
#                    default the server's + 5); its sign-in page takes N+1
#
#   CONDUIT_DEV_CACHE    the cache root (~/Library/Caches/conduit-dev on
#                        macOS, ${XDG_CACHE_HOME:-~/.cache}/conduit-dev elsewhere)
#   CONDUIT_OWUI_VENV    the venv (default $CONDUIT_DEV_CACHE/owui-0.13.4)
#   CONDUIT_OWUI_PYTHON  a CPython 3.11 for setup (default: uv's, then
#                        python3.11 on PATH)
#   CONDUIT_OWUI_ENV     the env file seed writes and the tests read
#                        (default $CONDUIT_OWUI_DIR/local-owui.env)
#
# Every account, password, chat and file it makes is invented. Nothing is
# ever deleted: reset moves the old data into $CONDUIT_OWUI_DIR/old/.
set -euo pipefail

OWUI_VERSION=0.13.4
TOOL_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$(uname -s)" = Darwin ]; then
  default_cache="$HOME/Library/Caches/conduit-dev"
else
  default_cache="${XDG_CACHE_HOME:-$HOME/.cache}/conduit-dev"
fi
CACHE=${CONDUIT_DEV_CACHE:-$default_cache}
VENV=${CONDUIT_OWUI_VENV:-$CACHE/owui-$OWUI_VERSION}
DIR=${CONDUIT_OWUI_DIR:-$CACHE/local-owui}
PORT=${CONDUIT_OWUI_PORT:-}
MODEL_PORT=${CONDUIT_OWUI_MODEL_PORT:-}
HERMES_PORT=${CONDUIT_OWUI_HERMES_PORT:-}
TERMINAL_PORT=${CONDUIT_OWUI_TERMINAL_PORT:-}
PROXY_PORT=${CONDUIT_OWUI_PROXY_PORT:-}

command=${1:-}
[ $# -gt 0 ] && shift
# `chat` and `media` take two arguments; nothing else takes any.
ARG1=
ARG2=
# `peer` hands every argument to channel_peer.py.
if [ "$command" = peer ]; then
  PEER_ARGS=("$@")
  set --
fi
# `proxy` takes one argument: start, expire or stop.
PROXY_ACTION=
if [ "$command" = proxy ] && [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  PROXY_ACTION=$1
  shift
fi
while [ $# -gt 0 ]; do
  case $1 in
    --dir) DIR=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --model-port) MODEL_PORT=$2; shift 2 ;;
    --hermes-port) HERMES_PORT=$2; shift 2 ;;
    --terminal-port) TERMINAL_PORT=$2; shift 2 ;;
    --proxy-port) PROXY_PORT=$2; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *)
      if { [ "$command" != chat ] && [ "$command" != showcase ] && [ "$command" != media ] && [ "$command" != tool-permissions ]; } || [ -n "$ARG2" ]; then
        echo "unexpected argument: $1" >&2
        exit 64
      fi
      if [ -z "$ARG1" ]; then ARG1=$1; else ARG2=$1; fi
      shift
      ;;
  esac
done

STATE=$DIR/state
DATA=$DIR/data
ENV_FILE=${CONDUIT_OWUI_ENV:-$DIR/local-owui.env}

# The port a running instance was started on wins over the default.
if [ -z "$PORT" ] && [ -f "$STATE/port" ]; then PORT=$(cat "$STATE/port"); fi
PORT=${PORT:-8150}
if [ -z "$MODEL_PORT" ] && [ -f "$STATE/model_port" ]; then MODEL_PORT=$(cat "$STATE/model_port"); fi
MODEL_PORT=${MODEL_PORT:-$((PORT + 1))}
if [ -z "$HERMES_PORT" ] && [ -f "$STATE/hermes_port" ]; then HERMES_PORT=$(cat "$STATE/hermes_port"); fi
HERMES_PORT=${HERMES_PORT:-$((PORT + 2))}
if [ -z "$TERMINAL_PORT" ] && [ -f "$STATE/terminal_port" ]; then TERMINAL_PORT=$(cat "$STATE/terminal_port"); fi
TERMINAL_PORT=${TERMINAL_PORT:-$((PORT + 3))}
if [ -z "$PROXY_PORT" ] && [ -f "$STATE/proxy_port" ]; then PROXY_PORT=$(cat "$STATE/proxy_port"); fi
PROXY_PORT=${PROXY_PORT:-$((PORT + 5))}
URL=http://127.0.0.1:$PORT

# Each service needs a port of its own: two on one port would both pass the
# free-port check and then fight over it.
if [ "$(printf '%s\n' "$PORT" "$MODEL_PORT" "$HERMES_PORT" "$TERMINAL_PORT" | sort -u | wc -l)" -ne 4 ]; then
  echo "the server, fake model, fake Hermes and fake terminal need four different ports (now $PORT, $MODEL_PORT, $HERMES_PORT, $TERMINAL_PORT)" >&2
  exit 2
fi

# Pid files and the identity of what they name: tool/local_owui/pids.sh.
. "$TOOL_DIR/pids.sh"

# Whether NAME (server, fake_model, fake_hermes, fake_terminal or fake_proxy)
# is running: the process its pid file names, and no other one that took its
# pid since.
alive() { pid_alive "$STATE/$1.pid"; }

# A running instance keeps the ports it was started on: a different --port,
# --model-port, --hermes-port or --terminal-port (or --proxy-port while the
# proxy runs) would point seed and chat at whatever listens there instead.
# Only stopping (reset stops first) may change them.
if alive server; then
  for kind in port model_port hermes_port terminal_port proxy_port; do
    case $kind in
      port) wanted=$PORT ;;
      model_port) wanted=$MODEL_PORT ;;
      hermes_port) wanted=$HERMES_PORT ;;
      terminal_port) wanted=$TERMINAL_PORT ;;
      proxy_port)
        alive fake_proxy || continue
        wanted=$PROXY_PORT
        ;;
    esac
    [ -f "$STATE/$kind" ] || continue
    running=$(cat "$STATE/$kind")
    if [ "$wanted" != "$running" ]; then
      case $command in
        stop | status | reset | env) ;;
        *)
          echo "this instance runs with $kind $running, not $wanted: stop it (or reset) to change it" >&2
          exit 1
          ;;
      esac
    fi
  done
fi

# Whether nothing listens on 127.0.0.1:PORT (curl: 7 = could not connect),
# asked directly rather than through any proxy the shell exports.
# Checked before each launch, so that a health answer can only come from
# this instance's server and the seed never reaches another instance.
port_free() {
  local rc=0
  curl -s --noproxy '*' -o /dev/null --max-time 2 "http://127.0.0.1:$1/" || rc=$?
  [ "$rc" = 7 ]
}

# Waits (30 s at most) until something answers on PORT, for NAME.
wait_listening() {
  for _ in $(seq 1 60); do
    port_free "$2" || return 0
    sleep 0.5
  done
  echo "the $1 did not start listening on $2; see $STATE" >&2
  return 1
}

# Refuses to start NAME on PORT when something else already listens there.
need_free_port() {
  if ! port_free "$2"; then
    echo "port $2 is in use by something else, not this instance's $1: stop it or pick another --port" >&2
    exit 1
  fi
}

find_python() {
  if [ -n "${CONDUIT_OWUI_PYTHON:-}" ]; then echo "$CONDUIT_OWUI_PYTHON"; return; fi
  if command -v uv >/dev/null 2>&1; then
    found=$(uv python find 3.11 2>/dev/null || true)
    if [ -n "$found" ]; then echo "$found"; return; fi
  fi
  for candidate in "$HOME"/.local/share/uv/python/cpython-3.11*/bin/python3.11; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
  if command -v python3.11 >/dev/null 2>&1; then command -v python3.11; return; fi
  echo "no CPython 3.11: install one (uv python install 3.11) or set CONDUIT_OWUI_PYTHON" >&2
  exit 1
}

# The open-webui version installed in the venv, or nothing.
venv_version() {
  "$VENV/bin/python" -I -c 'import importlib.metadata as m; print(m.version("open-webui"))' 2>/dev/null || true
}

# The version the server on URL says it runs (/api/config), or nothing when
# it does not answer.
running_version() {
  curl -s --noproxy '*' --max-time 5 "$URL/api/config" 2>/dev/null |
    "$VENV/bin/python" -I -c 'import json, sys
try:
    print(json.load(sys.stdin).get("version") or "")
except ValueError:
    pass' 2>/dev/null || true
}

setup() {
  if [ -x "$VENV/bin/open-webui" ] && [ "$(venv_version)" = "$OWUI_VERSION" ]; then
    echo "open-webui $OWUI_VERSION is ready in $VENV"
    return
  fi
  python=$(find_python)
  echo "making $VENV with $python (open-webui $OWUI_VERSION, a few minutes)"
  mkdir -p "$(dirname "$VENV")"
  "$python" -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  "$VENV/bin/python" -m pip install --quiet "open-webui==$OWUI_VERSION"
  echo "open-webui $OWUI_VERSION is ready in $VENV"
}

need_venv() {
  if [ ! -x "$VENV/bin/open-webui" ]; then
    echo "no open-webui in $VENV: run '$0 setup' first" >&2
    exit 1
  fi
}

# Two-step verification needs persistent config (`owui.sh two-step` turns
# it on for the instance); everything else runs without it, so env changes
# apply on the next start.
persistent_config() {
  if [ -f "$STATE/persistent_config" ]; then echo true; else echo false; fi
}

start() {
  need_venv
  if alive server; then
    # A server started from an older venv (before a `setup` that installed
    # another version) keeps running; seeding it would test the wrong version.
    local running installed
    running=$(running_version)
    installed=$(venv_version)
    if [ -n "$running" ] && [ -n "$installed" ] && [ "$running" != "$installed" ]; then
      echo "the server at $(cat "$STATE/url") runs Open WebUI $running, but $VENV has $installed: run '$0 stop' (the data stays), then '$0 up'" >&2
      exit 1
    fi
    echo "already running at $(cat "$STATE/url")"
    return
  fi
  local started_model= started_hermes= started_terminal=
  need_free_port server "$PORT"
  alive fake_model || need_free_port 'fake model' "$MODEL_PORT"
  if command -v dart >/dev/null 2>&1; then
    alive fake_hermes || need_free_port 'fake Hermes' "$HERMES_PORT"
    alive fake_terminal || need_free_port 'fake terminal' "$TERMINAL_PORT"
  fi
  mkdir -p "$DATA" "$STATE"
  chmod 700 "$STATE"
  if [ ! -s "$STATE/secret" ]; then
    (umask 077 && "$VENV/bin/python" -I -c 'import secrets; print(secrets.token_urlsafe(32))' > "$STATE/secret")
  fi
  echo "$PORT" > "$STATE/port"
  echo "$MODEL_PORT" > "$STATE/model_port"
  echo "$HERMES_PORT" > "$STATE/hermes_port"
  echo "$TERMINAL_PORT" > "$STATE/terminal_port"
  echo "$URL" > "$STATE/url"
  if [ ! -s "$STATE/hermes_key" ]; then
    (umask 077 && "$VENV/bin/python" -I -c 'import secrets; print(secrets.token_urlsafe(24))' > "$STATE/hermes_key")
  fi
  if [ ! -s "$STATE/terminal_key" ]; then
    (umask 077 && "$VENV/bin/python" -I -c 'import secrets; print(secrets.token_urlsafe(24))' > "$STATE/terminal_key")
  fi

  if ! alive fake_model; then
    nohup "$VENV/bin/python" -I "$TOOL_DIR/fake_model.py" \
      --port "$MODEL_PORT" --log "$STATE/requests.jsonl" \
      > "$STATE/fake_model.log" 2>&1 &
    pid_record "$STATE/fake_model.pid" $!
    started_model=1
  fi

  # The daemon tests' fake Hermes API server, for the desktop app's Hermes
  # pass. It needs only the Dart SDK: an empty package config keeps `dart`
  # from resolving (and running the build hooks of) the whole workspace.
  if ! alive fake_hermes; then
    if command -v dart >/dev/null 2>&1; then
      echo '{"configVersion":2,"packages":[]}' > "$STATE/no_packages.json"
      nohup dart --packages="$STATE/no_packages.json" "$TOOL_DIR/fake_hermes.dart" \
        --port "$HERMES_PORT" --key "$(cat "$STATE/hermes_key")" \
        > "$STATE/fake_hermes.log" 2>&1 &
      pid_record "$STATE/fake_hermes.pid" $!
      started_hermes=1
    else
      echo "no dart on PATH: the fake Hermes server is not started" >&2
    fi
  fi

  # The daemon tests' fake Open Terminal in its interactive mode: a shell,
  # files, a dev server on port 5173, live events, a display_file tool and a
  # Computer desktop. Open WebUI offers it as a system terminal.
  if ! alive fake_terminal; then
    if command -v dart >/dev/null 2>&1; then
      echo '{"configVersion":2,"packages":[]}' > "$STATE/no_packages.json"
      nohup dart --packages="$STATE/no_packages.json" "$TOOL_DIR/fake_terminal.dart" \
        --port "$TERMINAL_PORT" --key "$(cat "$STATE/terminal_key")" \
        > "$STATE/fake_terminal.log" 2>&1 &
      pid_record "$STATE/fake_terminal.pid" $!
      started_terminal=1
    else
      echo "no dart on PATH: the fake terminal is not started" >&2
    fi
  fi

  # The server writes a few files into its working directory.
  (
    cd "$STATE"
    # Its own SQLite file, local file storage and the fake model only,
    # whatever the caller's shell exports: an inherited DATABASE_URL (or
    # DATABASE_TYPE and its parts), STORAGE_PROVIDER (s3, gcs, azure) or
    # OPENAI_API_BASE_URLS/KEYS would point this throwaway server at real
    # data, a real bucket or a real provider.
    # ENABLE_DIRECT_CONNECTIONS and ENABLE_DIRECT_INTEGRATIONS only reach a
    # CONDUIT_OWUI_VENV of 0.13.3 or older: 0.13.4 moved both into Tether.
    DATA_DIR="$DATA" STORAGE_PROVIDER=local \
      DATABASE_URL="sqlite:///$DATA/webui.db" DATABASE_TYPE= DATABASE_SCHEMA= \
      OPENAI_API_BASE_URLS="http://127.0.0.1:$MODEL_PORT/v1" OPENAI_API_KEYS=sk-local-fake \
      WEBUI_SECRET_KEY="$(cat "$STATE/secret")" \
      ENABLE_PERSISTENT_CONFIG="$(persistent_config)" \
      OFFLINE_MODE=true HF_HUB_OFFLINE=1 \
      ENABLE_VERSION_UPDATE_CHECK=false \
      DO_NOT_TRACK=true SCARF_NO_ANALYTICS=true ANONYMIZED_TELEMETRY=false \
      ENABLE_OLLAMA_API=false \
      ENABLE_OPENAI_API=true \
      OPENAI_API_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1" \
      OPENAI_API_KEY=sk-local-fake \
      ENABLE_TOOL_CALL_LABELS=true \
      ENABLE_DIRECT_CONNECTIONS=true \
      ENABLE_DIRECT_INTEGRATIONS=true \
      TOOL_SERVER_CONNECTIONS="[{\"type\":\"mcp\",\"url\":\"http://127.0.0.1:$MODEL_PORT/mcp\",\"path\":\"\",\"auth_type\":\"none\",\"key\":\"\",\"config\":{\"enable\":true},\"info\":{\"id\":\"harbour\",\"name\":\"Harbour\",\"description\":\"A synthetic MCP server with one app.\"}}]" \
      ENABLE_TOOL_SERVERS=true \
      TERMINAL_SERVER_CONNECTIONS="[{\"id\":\"buildbox\",\"name\":\"Build box\",\"url\":\"http://127.0.0.1:$TERMINAL_PORT\",\"auth_type\":\"bearer\",\"key\":\"$(cat "$STATE/terminal_key")\",\"enabled\":true,\"config\":{}}]" \
      ENABLE_CHANNELS=true \
      ENABLE_APPS=true \
      ENABLE_USER_WEBHOOKS=true \
      ENABLE_LOCAL_WEB_FETCH=true \
      CODE_INTERPRETER_ENGINE=jupyter \
      CODE_INTERPRETER_JUPYTER_URL=http://127.0.0.1:9 \
      BYPASS_EMBEDDING_AND_RETRIEVAL=true \
      RAG_EMBEDDING_ENGINE=openai RAG_EMBEDDING_MODEL=fake-embedding \
      RAG_OPENAI_API_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1" \
      RAG_OPENAI_API_KEY=sk-local-fake \
      BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true \
      AUDIO_STT_ENGINE=openai AUDIO_STT_MODEL=whisper-1 \
      AUDIO_STT_OPENAI_API_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1" \
      AUDIO_STT_OPENAI_API_KEY=sk-local-fake \
      AUDIO_TTS_ENGINE=openai AUDIO_TTS_MODEL=tts-1 AUDIO_TTS_VOICE=alloy \
      AUDIO_TTS_OPENAI_API_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1" \
      AUDIO_TTS_OPENAI_API_KEY=sk-local-fake \
      AUDIO_REALTIME_ENABLED=true \
      AUDIO_REALTIME_OPENAI_API_BASE_URL="http://127.0.0.1:$MODEL_PORT/v1" \
      AUDIO_REALTIME_OPENAI_API_KEY=sk-local-fake \
      AUDIO_REALTIME_MODEL=fake-realtime AUDIO_REALTIME_VOICE=fake-voice \
      AUDIO_REALTIME_TRANSCRIPTION_MODEL=fake-transcribe \
      nohup "$VENV/bin/open-webui" serve --host 127.0.0.1 --port "$PORT" \
      > "$STATE/server.log" 2>&1 &
    pid_record "$STATE/server.pid" $!
  )

  code=000
  for _ in $(seq 1 120); do
    code=$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "$URL/health" || true)
    [ "$code" = 200 ] && break
    if ! alive server; then break; fi
    sleep 2
  done
  if [ "$code" != 200 ] || ! alive server; then
    echo "the server did not come up (health $code); see $STATE/server.log" >&2
    exit 1
  fi
  # A program started through a launcher (Homebrew's `dart` is a script)
  # may hand over after its pid file was written. Once it answers on its
  # port it has, so what this start launched is recorded again then.
  pid_refresh "$STATE/server.pid"
  local silent=
  if [ -n "$started_model" ]; then
    if wait_listening 'fake model' "$MODEL_PORT"; then
      pid_refresh "$STATE/fake_model.pid"
    else
      silent="fake model on $MODEL_PORT"
    fi
  fi
  if [ -n "$started_hermes" ]; then
    if wait_listening 'fake Hermes' "$HERMES_PORT"; then
      pid_refresh "$STATE/fake_hermes.pid"
    else
      silent="${silent:+$silent, }fake Hermes on $HERMES_PORT"
    fi
  fi
  if [ -n "$started_terminal" ]; then
    if wait_listening 'fake terminal' "$TERMINAL_PORT"; then
      pid_refresh "$STATE/fake_terminal.pid"
    else
      silent="${silent:+$silent, }fake terminal on $TERMINAL_PORT"
    fi
  fi
  if [ -n "$silent" ]; then
    echo "running at $URL, but not listening: $silent (see $STATE)"
  else
    echo "running at $URL (fake model on $MODEL_PORT)"
  fi
}

seed() {
  need_venv
  if ! alive server; then
    echo "not running: run '$0 start' first" >&2
    exit 1
  fi
  if [ -f "$STATE/seeded" ]; then
    echo "already seeded; '$0 reset' starts over"
    echo "env file: $ENV_FILE"
    return
  fi
  "$VENV/bin/python" -I "$TOOL_DIR/seed.py" \
    --url "$URL" --state "$STATE" --data "$DATA" --env-file "$ENV_FILE" \
    --fake-model-url "http://127.0.0.1:$MODEL_PORT/v1" \
    --fake-hermes-url "http://127.0.0.1:$HERMES_PORT/v1" \
    --fake-hermes-key-file "$STATE/hermes_key" \
    --fake-terminal-url "http://127.0.0.1:$TERMINAL_PORT" \
    --fake-terminal-key-file "$STATE/terminal_key"
  date -u +%FT%TZ > "$STATE/seeded"
  echo "env file: $ENV_FILE"
}

stop() {
  for name in server fake_model fake_hermes fake_terminal fake_proxy; do
    case $(pid_stop "$STATE/$name.pid") in
      stopped) echo "stopped $name" ;;
      killed) echo "stopped $name (killed)" ;;
    esac
    rm -f "$STATE/$name.pid"
  done
}

chat() {
  need_venv
  if [ -z "$ARG1" ] || [ -z "$ARG2" ]; then
    echo "usage: $0 chat OUT-DIR PROMPT" >&2
    exit 64
  fi
  if ! alive server || [ ! -f "$ENV_FILE" ]; then
    echo "not running or not seeded: run '$0 up' first" >&2
    exit 1
  fi
  "$VENV/bin/python" -I "$TOOL_DIR/drive_chat.py" "$ENV_FILE" "$ARG1" "$ARG2"
}

peer() {
  need_venv
  if ! alive server || [ ! -f "$ENV_FILE" ]; then
    echo "not running or not seeded: run '$0 up' first" >&2
    exit 1
  fi
  "$VENV/bin/python" -I "$TOOL_DIR/channel_peer.py" "$ENV_FILE" "$DATA" "${PEER_ARGS[@]}"
}

showcase() {
  need_venv
  if [ -z "$ARG1" ]; then
    echo "usage: $0 showcase OUT-DIR" >&2
    exit 64
  fi
  if ! alive server || [ ! -f "$ENV_FILE" ]; then
    echo "not running or not seeded: run '$0 up' first" >&2
    exit 1
  fi
  "$VENV/bin/python" -I "$TOOL_DIR/showcase.py" --env-file "$ENV_FILE" \
    --secret-file "$STATE/secret" --out "$ARG1"
}

media() {
  need_venv
  if [ -z "$ARG1" ] || [ -z "$ARG2" ]; then
    echo "usage: $0 media OUT-DIR SITE-URL" >&2
    exit 64
  fi
  if ! alive server || [ ! -f "$ENV_FILE" ]; then
    echo "not running or not seeded: run '$0 up' first" >&2
    exit 1
  fi
  "$VENV/bin/python" -I "$TOOL_DIR/media_chat.py" --env-file "$ENV_FILE" \
    --site "$ARG2" --out "$ARG1"
}

tool_permissions() {
  need_venv
  if [ "$ARG1" != on ] && [ "$ARG1" != off ]; then
    echo "usage: $0 tool-permissions on|off" >&2
    exit 64
  fi
  if ! alive server || [ ! -f "$ENV_FILE" ]; then
    echo "not running or not seeded: run '$0 up' first" >&2
    exit 1
  fi
  "$VENV/bin/python" -I "$TOOL_DIR/tool_permissions.py" --env-file "$ENV_FILE" \
    --state-file "$STATE/tool-permissions.json" "$ARG1"
}

two_step() {
  need_venv
  if ! alive server || [ ! -f "$ENV_FILE" ]; then
    echo "not running or not seeded: run '$0 up' first" >&2
    exit 1
  fi
  if [ ! -f "$STATE/persistent_config" ]; then
    # The server again, with persistent config.
    pid_stop "$STATE/server.pid" 40 > /dev/null
    rm -f "$STATE/server.pid"
    date -u +%FT%TZ > "$STATE/persistent_config"
    start
  fi
  "$VENV/bin/python" -I "$TOOL_DIR/two_step.py" --env-file "$ENV_FILE" \
    --state "$STATE" --data "$DATA" --venv "$VENV"
}

proxy() {
  need_venv
  case $PROXY_ACTION in
    start)
      if alive fake_proxy; then
        echo "proxy already running at http://127.0.0.1:$PROXY_PORT"
        return
      fi
      if ! alive server || [ ! -f "$ENV_FILE" ]; then
        echo "not running or not seeded: run '$0 up' first" >&2
        exit 1
      fi
      need_free_port proxy "$PROXY_PORT"
      need_free_port "proxy's sign-in page" "$((PROXY_PORT + 1))"
      mkdir -p "$STATE"
      echo "$PROXY_PORT" > "$STATE/proxy_port"
      nohup "$VENV/bin/python" -I "$TOOL_DIR/fake_proxy.py" \
        --port "$PROXY_PORT" --sign-in-port "$((PROXY_PORT + 1))" \
        --upstream "$URL" --log "$STATE/proxy_requests.jsonl" \
        > "$STATE/fake_proxy.log" 2>&1 &
      pid_record "$STATE/fake_proxy.pid" $!
      for _ in $(seq 1 40); do
        if curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$PROXY_PORT/__proxy/state"; then
          # Serving: whatever ran first has handed over.
          pid_refresh "$STATE/fake_proxy.pid"
          break
        fi
        sleep 0.25
      done
      if ! grep -q '^OWUI_PROXY_URL=' "$ENV_FILE"; then
        printf '\n# The fake sign-in proxy (owui.sh proxy start)\nOWUI_PROXY_URL=http://127.0.0.1:%s\n' "$PROXY_PORT" >> "$ENV_FILE"
      fi
      echo "proxy at http://127.0.0.1:$PROXY_PORT (sign-in page on $((PROXY_PORT + 1)))"
      ;;
    expire)
      if ! alive fake_proxy; then
        echo "the proxy is not running: run '$0 proxy start' first" >&2
        exit 1
      fi
      curl -sf --noproxy '*' -X POST "http://127.0.0.1:$PROXY_PORT/__proxy/expire" >/dev/null
      echo "proxy sessions expired"
      ;;
    stop)
      case $(pid_stop "$STATE/fake_proxy.pid") in
        stopped) echo "stopped fake_proxy" ;;
        killed) echo "stopped fake_proxy (killed)" ;;
      esac
      rm -f "$STATE/fake_proxy.pid"
      ;;
    *)
      echo "usage: $0 proxy start|expire|stop" >&2
      exit 64
      ;;
  esac
}

set_aside() {
  [ -d "$DATA" ] || [ -d "$STATE" ] || return 0
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$DIR/old/$stamp"
  [ -d "$DATA" ] && mv "$DATA" "$DIR/old/$stamp/data"
  if [ -d "$STATE" ]; then
    # Keep the ports; the rest belongs to the old data.
    mv "$STATE" "$DIR/old/$stamp/state"
  fi
  if [ -f "$ENV_FILE" ]; then mv "$ENV_FILE" "$DIR/old/$stamp/"; fi
  echo "old data moved to $DIR/old/$stamp"
}

status() {
  for name in server fake_model fake_hermes fake_terminal fake_proxy; do
    if alive "$name"; then
      echo "$name: running (pid $(pid_of "$STATE/$name.pid"))"
    else
      echo "$name: stopped"
    fi
  done
  echo "url: $URL"
  echo "fake model: http://127.0.0.1:$MODEL_PORT/v1"
  echo "fake Hermes: http://127.0.0.1:$HERMES_PORT/v1"
  echo "fake terminal: http://127.0.0.1:$TERMINAL_PORT (Build box)"
  if [ -f "$STATE/seeded" ]; then echo "seeded: $(cat "$STATE/seeded")"; else echo "seeded: no"; fi
  echo "env file: $ENV_FILE"
}

case $command in
  setup) setup ;;
  start) start ;;
  seed) seed ;;
  up) start; seed ;;
  reset) stop; set_aside; start; seed ;;
  stop) stop ;;
  status) status ;;
  env) echo "$ENV_FILE" ;;
  chat) chat ;;
  showcase) showcase ;;
  media) media ;;
  peer) peer ;;
  tool-permissions) tool_permissions ;;
  two-step) two_step ;;
  proxy) proxy ;;
  *)
    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
    ;;
esac
