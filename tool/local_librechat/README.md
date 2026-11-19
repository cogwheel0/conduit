# Fake LibreChat server

A stand-in for a LibreChat v0.8.8 server, for the daemon's live tests and the
desktop app's `--e2e librechat` pass. It is one Python file with no
dependencies beyond the standard library (Python 3.9 or newer), so it runs
where docker (and `tool/librechat_dev`) cannot.

It serves what `conduit_core`'s LibreChat client calls, with invented users,
chats, prompts and memories. It is not LibreChat: it answers in LibreChat's
shapes, and nothing more.

```sh
tool/local_librechat/librechat.sh start    # background, port 19213 by default
tool/local_librechat/librechat.sh reset    # restart from the seed
tool/local_librechat/librechat.sh stop
tool/local_librechat/librechat.sh status
tool/local_librechat/librechat.sh env      # where the env file is
```

Options and environment: `--dir`/`CONDUIT_LIBRECHAT_DIR` (pid, log and env
file; default `~/Library/Caches/conduit-dev/local-librechat`), `--port`/
`CONDUIT_LIBRECHAT_PORT`, `CONDUIT_LIBRECHAT_ENV` (env file path),
`CONDUIT_LIBRECHAT_PYTHON` (default `python3`). Reset moves the old log into
`$DIR/old/`; nothing is deleted.

The env file (mode 600) is what tests read: `LIBRECHAT_URL`,
`LIBRECHAT_2FA_EMAIL`/`_PASSWORD`/`_CODE`/`_BACKUP_CODE` and
`LIBRECHAT_EMAIL`/`_PASSWORD`.

## What it holds

| | |
| --- | --- |
| Users | Rowan Vale (`rowan@example.test`, two-step code `246810`, backup codes `fern-quartz-01`, `fern-quartz-02`); Kit Marlow (`kit@example.test`, no two-step); Sage Ito (single sign-on only) |
| Sign-in | password, two-step (`/api/auth/2fa/verify-temp`), refresh with a rotating `refreshToken` cookie, sign-out; same-origin checks on sign-in |
| Single sign-on | "Harbour ID": `/oauth/openid` → `/fake-idp/authorize` (a page with **Continue**) → `/oauth/openid/callback`, which sets the session cookies and sends the browser to `/c/new` |
| Models | endpoint `Harbour` (`harbour-small`, `harbour-large`); agents Tidewatch and Ledger Helper; specs Quick Notes and Deep Research (not enforced) |
| Chats | four of Rowan's (one pinned, one archived), one of Kit's |
| Prompts | `/pack` (`{{destination}}`, `{{days}}`), `/tone` (`{{tone:friendly\|formal\|playful}}`, `{{text}}`), `/summary` |
| Memories | two of Rowan's, one of Kit's; a 2,000-token budget |
| MCP | `harbour_docs` (connected) and `ledger_sync` (needs signing in, "Connect in LibreChat") |
| Speech | STT answers "Harbour lights at dusk"; TTS answers a short WAV tone; voices Marlin, Heron, Puffin |

Chat, agent and file routes refuse a User-Agent that is not a browser's, with
LibreChat's own "Illegal request" frame, as the real server does.

## Replies

A reply is streamed over protocol v2 (`POST /api/agents/chat/:endpoint`, then
`GET /api/agents/chat/stream/:id`, with `resume=true` snapshots, `abort` and
`status`). What it does depends on the user's words:

- **"approve"**: pauses on a tool approval for `lookup_tide_mcp_harbour_docs`;
  approving gives "The next high tide at Port Wren is at 06:40."
- **"ask me"**: pauses on a question with two options (Port Wren, Gull Haven).
- **"long"** or **"story"**: streams for about 15 seconds, to stop.
- **"fail"**: ends with an error frame.
- anything else: `Noted: "<text>". <model> answers from the fake harbour server.`

With the web search tool on (`ephemeralAgent.web_search`), a search step and
a source come first. A new chat is titled from the first words of its message.

## Test hooks

`/__fake/state` (what it holds, and the last turn bodies), `/__fake/reset`,
`/__fake/end-sessions` (every session ends: "session ended" on the next
renewal), `/__fake/expire-access`, `/__fake/mcp-connect/<name>`.
