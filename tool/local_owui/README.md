# A local Open WebUI for tests

The daemon's live tests (`apps/daemon/test/live_server_test.dart`), its
signed-in smoke run (`apps/daemon/tool/smoke.dart`) and the desktop app's
`--e2e` passes run against a throwaway Open WebUI 0.13.4 on this machine,
with a fake model and invented data. Nothing here talks to a real server
or a real model, and CI never starts it: there, those tests skip.

```sh
tool/local_owui/owui.sh setup    # once: a venv with open-webui (a few minutes)
tool/local_owui/owui.sh up       # start the server and the fake model, seed once
tool/local_owui/owui.sh env      # the env file the tests read
tool/local_owui/owui.sh reset    # fresh data and a new seed (after a test changed it)
tool/local_owui/owui.sh stop
```

`setup` needs a CPython 3.11: uv's (`uv python install 3.11`), or
`python3.11` on `PATH`, or `CONDUIT_OWUI_PYTHON`. The venv lives in
`~/Library/Caches/conduit-dev/owui-0.13.4` (`CONDUIT_OWUI_VENV`), and the
instance (data, logs, pids and a generated secret key) in
`~/Library/Caches/conduit-dev/local-owui` (`CONDUIT_OWUI_DIR`, or `--dir`).
The daemon's tests find the instance through `CONDUIT_OWUI_DIR` (or
`CONDUIT_OWUI_ENV`, the env file itself), so an instance started with
`--dir` needs that variable set to the same directory when they run.
On Linux the cache root is `${XDG_CACHE_HOME:-~/.cache}/conduit-dev`;
`CONDUIT_DEV_CACHE` moves it anywhere. The server listens on
`127.0.0.1:8150` (`--port`), the fake model on 8151 and a fake Hermes
Agent API server on 8152 (the next ports). Nothing is deleted: `reset`
moves the old data into `local-owui/old/`.

Each process's pid file also holds what `ps` said about it at start (its
start time and command line); `owui.sh` takes a process for its own, and
stops it, only while `ps` still says exactly that, so a pid reused after a
crash, or another instance's process, is left alone.
`tool/local_owui/pids_test.sh` checks that with `sleep` processes of its own.

A start refuses a port something else already listens on, and a running
instance keeps the ports it was started on: any command but `stop`,
`status`, `reset` and `env` given another port is refused, so `seed` and
`chat` never reach another listener. `tool/local_owui/ports_test.sh` checks
that. `start` and `up` also refuse a running server that says it runs
another Open WebUI version than the venv has, as one started before a
`setup` of a newer version does: `stop` it first (the data stays).
`tool/local_owui/version_test.sh` checks that.

## What it holds

`owui.sh start` runs Open WebUI with `ENABLE_PERSISTENT_CONFIG=false`,
offline, with channels on, retrieval bypassed, and one OpenAI connection,
`fake_model.py`, which also does its speech-to-text, text-to-speech and
embeddings (saving a memory needs one), and is the voice behind the
server's realtime calls (a scripted exchange over its `/v1/realtime`
WebSocket). The fake model also serves a personal tool server (OpenAPI,
`/personal/openapi.json`, one operation `read_buoy`) for Personal
Connections (see below), and takes webhook deliveries on any
`/webhook/...` path (user webhooks are on), logging both. `seed.py` then
makes:

- an admin, Avery Tester (`avery@example.test`), and a second user, Riley
  Example (`riley@example.test`), each with a random password;
- the admin's folders `Garden` (expanded) › `Seeds`, `Side project` and
  `Recipes`, and 40 chats with a short exchange each: 11 filed, 3 pinned,
  4 archived, dated from minutes to a year ago;
- Riley's folder `Riley trip planning` with two chats, shared read-only
  with the admin;
- prompts `/orbit` and `/brief` (with a select variable) and an uploaded
  text file.

Open WebUI 0.13.4 moved direct connections and Personal Connections (the
tool servers and terminals kept in the account) into Tether, its companion
app, and dropped the settings that turned them on. Against it, the tests
of a connection kept in the account are skipped, and the desktop passes
skip those steps with a line saying so, until Conduit can act as a Tether
device. The daemon's terminal test still writes a terminal into the
account's settings itself and reaches it directly.

## The env file

`seed.py` writes it with mode 600, by default to
`~/Library/Caches/conduit-dev/local-owui/local-owui.env`
(`CONDUIT_OWUI_ENV` moves it; the tests read the same variable):

| Key | Value |
|---|---|
| `OWUI_URL` | `http://127.0.0.1:8150` |
| `OWUI_EMAIL`, `OWUI_PASSWORD` | the admin |
| `OWUI_MODEL` | `fake-model` |
| `OWUI_SECOND_MODEL` | `fake-model-b`, which answers as `fake-model` does with a `B: ` prefix (Compare Models, Regenerate With) |
| `OWUI_REFUSED_MODEL` | `fake-refused`, which the provider refuses with a 400 |
| `OWUI_SECOND_EMAIL`, `OWUI_SECOND_PASSWORD` | the second user |
| `OWUI_SHARED_FOLDER`, `OWUI_SHARED_CHAT` | the shared folder and one of its chats |
| `OWUI_FILE` | the uploaded file's id |
| `FAKE_OPENAI_URL` | the fake model's own OpenAI-compatible base URL |
| `FAKE_HERMES_URL`, `FAKE_HERMES_KEY` | the fake Hermes server and its random key |

## The fake model

`fake_model.py` answers from the last user message: "Say the word: X"
with X, a favourite colour from earlier in the chat, `fail` with a 500,
`refuse` with a 400, `time` with a `get_current_timestamp` call
(approval asked when the message says `approve`, once
`owui.sh tool-permissions on` has turned on auto tool permissions; every
other call says it needs none), and `reason`, `code`,
`math`, `long` and `slow` with the answers the chat view's E2E checks,
`effort` (sent with a `reasoning_effort`) with a 400 naming the parameter,
and Open WebUI's Merge Responses prompt with one merged sentence. A streamed
answer ends with a usage chunk (token counts and timings), and
`fake-model-b` answers the same way with a `B: ` prefix. Its docstring has
the full list. `drive_chat.py` sends one turn over a socket
session the way the web client does and saves what the server sent;
`owui.sh chat DIR TEXT` runs it with the venv's python, into `DIR`
(`chat.json` holds the saved chat). The desktop app's `--e2e offline`
pass uses it to change the server while the app is closed.

## The fake Hermes server

`fake_hermes.dart` serves the daemon tests' fake Hermes Agent API server
(`apps/daemon/test/support/fake_hermes_server.dart`) for the desktop app's
Hermes pass. `owui.sh start` runs it when `dart` is on `PATH`.
