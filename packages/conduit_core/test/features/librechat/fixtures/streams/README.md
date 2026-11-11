# LibreChat stream fixtures

Generation streams in LibreChat v0.8.8's wire format
(`GET /api/agents/chat/stream/:streamId`, protocol v2): `event: message`
frames with JSON bodies, `event: error` for failures, `:` keepalive comments.

They were written from the v0.8.8 sources (`api/server/routes/agents/index.js`,
`api/server/controllers/agents/request.js`, `packages/data-provider/src/types/`)
rather than recorded, so each exercises one case on purpose:

| File | Case |
| --- | --- |
| `fresh_tool_reply.sse` | reasoning, an MCP tool call with streamed arguments, text, a title; one delta arrives before its run step |
| `resume_mid_text.sse` | a resumed subscription: the sync snapshot, a pending event, then live deltas |
| `pending_action.sse` | a tool call paused for approval; the stream stays open |
| `aborted.sse` | stopped mid-reply: the final frame is marked aborted and unfinished |
| `failed.sse` | the generation failed: an `event: error` frame |
| `reconcile.sse` | the result moved: a v2 `reconcile` final frame without a payload |
| `denied_start.txt` | a start request a middleware refused with SSE frames (denyRequest) |

`tool/librechat_dev/record_sse.sh` records real streams from the dev stack to
compare against.
