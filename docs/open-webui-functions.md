# Open WebUI functions in Conduit

This page is for authors of Open WebUI filters, tools, actions and pipes that
talk to the client through `__event_call__` or `__event_emitter__`. Conduit is
a native app, not a browser, so a few events behave differently from the web
client.

## Conduit never runs JavaScript

Conduit never runs code sent in an `execute` event.

An `execute` call made with `__event_call__` gets this reply straight away, so
your function never waits on it:

```json
{
  "error": "Conduit does not support client-side JavaScript execution. Use a server-side tool or the Open WebUI browser client.",
  "client": "conduit",
  "capabilities": ["chat:handoff"]
}
```

- `client` is always `"conduit"`. Check this field rather than the error text.
- `capabilities` lists the events Conduit handles in place of JavaScript.
- Older Conduit versions reply with `error` only.
- A one-way `execute` sent with `__event_emitter__` is ignored.

## `chat:handoff`: carry on in a new chat with another model

Routing and handoff filters on the web client usually run JavaScript that
opens a new chat on another model and fills in a prompt. In Conduit, send this
event instead:

```python
reply = await __event_call__({
    "type": "chat:handoff",
    "data": {
        "model_id": "code-assistant",      # required: a non-empty model id
        "prompt": "Review this diff: ...",  # optional: goes in the composer
    },
})
```

### What Conduit does

1. Ignores the event unless it is for the chat open on screen in Conduit, not
   one left open behind a note or settings. Open WebUI adds the `chat_id` of
   the request your function is running for.
2. Looks for `model_id` among the user's Open WebUI models. Hidden models
   count, as in the web client's `/?models=` link. Models that live only on the
   device, such as Direct connections and Hermes, never match.
3. Asks the user with a native dialog that names the model, for example
   "Switch to Code Assistant?", with **Start new chat** and **Stay here**.
4. If they agree, and are still in that chat, opens a new chat with that
   model selected and puts `prompt` in the composer. Attachments the user had
   picked in the old composer stay behind.

Conduit **never**:

- sends the prompt; the user reviews it and sends it themselves;
- switches chats without asking;
- deletes or changes the original chat, or any other chat on the server;
- runs code from the event.

### The reply

Only an `__event_call__` gets a reply:

| Reply | Meaning |
| --- | --- |
| `{"handled": true}` | The user agreed and the new chat is open. |
| `{"handled": false, "reason": "declined"}` | The user chose to stay. |
| `{"handled": false, "reason": "model_unavailable"}` | The user has no Open WebUI model with that id. |
| `{"handled": false, "reason": "not_active_chat"}` | The event was for a chat that isn't on screen in Conduit, or the user left it before agreeing. |
| `{"handled": false, "reason": "duplicate"}` | The same handoff for the same message already arrived. |
| `{"handled": false, "reason": "busy"}` | The user is still answering another handoff. |
| `{"handled": false, "reason": "invalid"}` | `model_id` is missing, empty or not a string, or `prompt` is neither a string nor `null`. |
| `{"handled": false, "reason": "unsupported"}` | This Conduit cannot ask the user. |
| `{"handled": false, "reason": "failed"}` | Something went wrong in Conduit. |

### Not supported yet

`files` and any other fields in `data` are ignored: Conduit doesn't carry
attachments into the new chat yet. Describe them in the prompt, or ask the user
to attach them again.

### Send it with `__event_call__`, and only to Conduit

Open WebUI 0.12 forwards any event type unchanged:

- `__event_call__` goes to the session that made the request and waits for its
  reply.
- `__event_emitter__` goes to every open session of the user and doesn't wait.

Some things to keep in mind:

- **The web client never replies to event types it doesn't know.** A
  `chat:handoff` call to a browser waits until `WEBSOCKET_EVENT_CALLER_TIMEOUT`,
  which is unset by default, so it waits forever. Check for Conduit first, as in
  the example below.
- **With `__event_emitter__` you get no reply.** Every Conduit device that has
  the chat open asks its user.
- **Conduit asks the user itself.** Don't send your own `confirmation` first, or
  the user is asked twice.
- **The call waits while the user decides.** Conduit sets no time limit. Wrap
  the call in `asyncio.wait_for` if your function must not wait that long.

### Example filter

```python
"""
title: Hand off to a specialist (Conduit example)
"""

from typing import Any, Awaitable, Callable, Optional

SPECIALIST = "code-assistant"  # an Open WebUI model id


class Filter:
    async def inlet(
        self,
        body: dict,
        __event_call__: Optional[Callable[[dict], Awaitable[Any]]] = None,
    ) -> dict:
        if not __event_call__ or body.get("model") == SPECIALIST:
            return body
        # Decide here whether this request belongs with SPECIALIST.

        # A browser runs this and returns "browser"; Conduit names itself.
        probe = await __event_call__(
            {"type": "execute", "data": {"code": "return 'browser'"}}
        )
        is_conduit = (
            isinstance(probe, dict)
            and probe.get("client") == "conduit"
            and "chat:handoff" in probe.get("capabilities", [])
        )
        if not is_conduit:
            return body  # A browser or an older Conduit: use your usual path.

        content = body["messages"][-1].get("content")
        reply = await __event_call__(
            {
                "type": "chat:handoff",
                "data": {
                    "model_id": SPECIALIST,
                    "prompt": content if isinstance(content, str) else "",
                },
            }
        )
        if isinstance(reply, dict) and reply.get("handled"):
            # The user is in the new chat now. Raising stops this model from
            # answering; Open WebUI shows the message as an error in the old
            # chat.
            raise Exception("Continuing in a new chat.")
        return body  # Declined or refused: answer here as usual.
```
