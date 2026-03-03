# OpenWebUI `/api/chat/completions` SSE/streaming inspection

## File paths + key functions

- `/Users/cwawak/GitHub/conduit/open-webui/backend/open_webui/main.py`
  - `chat_completion(...)` — `/api/chat/completions` endpoint
  - Calls `process_chat_payload(...)`, `chat_completion_handler(...)`, `process_chat_response(...)`

- `/Users/cwawak/GitHub/conduit/open-webui/backend/open_webui/utils/chat.py`
  - `generate_chat_completion(...)` — routes to providers
  - `generate_direct_chat_completion(...)` — emits SSE directly via `StreamingResponse`

- `/Users/cwawak/GitHub/conduit/open-webui/backend/open_webui/routers/openai.py`
  - `generate_chat_completion(...)` — proxy to upstream OpenAI‑style endpoints
  - Returns `StreamingResponse(stream_wrapper(...))` for `text/event-stream`

- `/Users/cwawak/GitHub/conduit/open-webui/backend/open_webui/utils/misc.py`
  - `stream_wrapper(...)` — pass‑through streaming
  - `stream_chunks_handler(...)` — guards against oversized SSE lines

- `/Users/cwawak/GitHub/conduit/open-webui/backend/open_webui/utils/middleware.py`
  - `process_chat_response(...)` — chooses streaming vs non‑streaming
  - `streaming_chat_response_handler(...)` — parses SSE, emits socket events, fallback SSE wrapper

- `/Users/cwawak/GitHub/conduit/open-webui/backend/open_webui/socket/main.py`
  - `get_event_emitter(...)` — emits internal socket “events” and updates DB

## SSE payload shapes and event formats

### HTTP SSE emitted by `/api/chat/completions` (API clients)

Primary behavior: upstream SSE is **passed through**.

- **OpenAI‑style streaming**
  - SSE lines are `data: <json>\n\n` (no `event:` lines)
  - Each `data` chunk has `choices[0].delta` with `content`, etc.
  - Ends with `data: [DONE]`
  - Server generally **forwards** these chunks without reformatting

- **Direct model connections** (`generate_direct_chat_completion`)
  - Emits `data: {json}\n\n` for dict messages
  - Raw string lines are wrapped into `data: ...\n\n` unless already prefixed
  - Terminates on `done: true`

- **Arena model selection**
  - If `stream=true`, prepends `data: {"selected_model_id": "<id>"}\n\n`
  - Then forwards upstream SSE as‑is

- **Fallback SSE wrapper** (`streaming_chat_response_handler`)
  - Injects precomputed events as `data: <json>\n\n`
  - Then yields the original upstream SSE stream unchanged

### Internal (socket) event formats emitted during streaming

When `session_id`/`chat_id`/`message_id` are present, the server **consumes** SSE
and emits socket events instead:

```json
{ "type": "<event-type>", "data": { ... } }
```

Common types:
- `chat:completion` — `content` (cumulative), `usage`, `done`, etc.
- `status`, `source`, `citation`, `files`, `chat:message:error`

## Cumulative vs delta content

- **HTTP SSE**: delta chunks (OpenAI‑style) are forwarded as‑is
- **Socket events**: `chat:completion` uses **cumulative** content
  - Emission is throttled by `stream_delta_chunk_size`

## Replay behavior

- **HTTP SSE**: no explicit replay / `Last‑Event‑ID`
- **Socket**: content is persisted to DB; UI reconstructs on reconnect
- **Injected events**: only injected once at stream start

## Summary

`/api/chat/completions` emits SSE `data:` lines; for API clients it mostly
passes through OpenAI‑style delta chunks. For WebUI sessions it consumes SSE,
accumulates content, and emits socket events with **cumulative** content.
