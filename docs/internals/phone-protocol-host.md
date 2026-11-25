# The phone's protocol host

[`InProcessProtocolHost`](../../packages/conduit_services/lib/src/in_process_host.dart)
runs the protocol's services inside the Flutter app, so a native screen in the
same process can use them over messages. It shares the app's root container
rather than starting a second core: two cores over the same databases and
Keychain would each sync, drain the outbox and own a socket, and race.

## What the app keeps, and what the host does not do

The host builds the services in shared mode
(`ProtocolHostPorts.sharesAppContainer`). The app's own listeners already run
over that container, so the host must not run them a second time:

- **Read-aloud, calls, Apple models and location** stay the app's. Their
  window bridges are not built, and their namespaces answer
  `rpc.unsupported` (`Capabilities.notOffered`).
- **Channel upkeep**: the app counts unread, applies mutes and reloads the
  list after a reconnect.
- **Alerts**: the app's notification router alerts for channel messages and
  answers from elsewhere, with the push ledger it shares with the
  notification extension. The services announce neither `channels.posted` nor
  `notifications.answered`, so a client cannot alert a second time.
- **The account-change reset**: the app's root listener resets the departing
  account's state, in its own order, however the switch started.

A new service that listens to the container must ask the same question: does
the app already do this?

## Stopping

`dispose()` stops in the order `conduitd` does: no new sessions or streams,
the sessions closed, `closeTransports()`, the byte streams ended, then the
services. It never disposes the container, and it does not call
`CoreRuntime.beginShutdown`: the app's core keeps running. The services close
the event bus last, so work still in flight after that tells no client.

## Backpressure

A platform channel has none, so each session counts the messages its client
has not yet acknowledged. Past the limit, an answer's `turn.delta` and
`turn.blocks` frames are held back, each replaced by the next for the same
answer (chat and `messageId`: a comparison streams several in one chat). Every
frame carries the whole state so far. Nothing else is ever held or dropped.

A held frame is refused before the bus numbers it (`EventBus.attach`'s
`EventGate`), so the client sees no gap in `seq`. A gap means "refetch" to a
client (the Mac's stores do), so dropping an already numbered frame would
trade a few stale frames for a refetch storm.

The rule that keeps this safe: a held frame is never sent after a newer state
for the same answer, by any path. Whatever else reaches the client for a chat
goes after what is held for it, whether published or sent straight to the
session (`sendTo`, as a catch-up does), which is why the gate is told of
direct sends as well as asked about published ones. A chat the client stops
watching is owed nothing held, and frames held under a chat's old id move to
its new one on `route.remap`. Catching up on acknowledgements, held frames go
only while the client has room; a chat's next event still takes everything
held for it first.

The count has to be exact for that. The JSON-RPC peer hands a message to the
transport a step after the bus delivers it, so an event is counted from the
moment the gate lets it through, and told from a reply where it is handed
over by how a notification begins.

A send the transport fails ends the session at once: the client would
otherwise read the next event or reply as if nothing were missing.
`InProcessSession.closed` tells the binding, the client reconnects, and the
new session catches up.

## Byte routes

The byte routes travel as frames (`ByteFrame`): a 12-byte header (stream,
kind, flags, reserved, length) and up to 64 KiB of payload. A chunk over
64 KiB is refused either way. Tunnels need a socket both ways and are refused
by path, without asking services the app keeps.

The calling contract, which a binding must follow, is on `receiveBytes` and
`sendBytes`:
- `receiveBytes` never waits on a route or on a send, so frames may be taken
  one at a time, each awaited before the next. Body chunks are taken as they
  come: every route reads its whole body, so holding the client back gains
  nothing.
- `sendBytes` may complete late, after frames the client sends meanwhile. The
  host waits on it only inside one stream's serving task, and sends that
  stream's next chunk once the client has taken the last.
- Every stream the host serves ends with exactly one `end` or `error` from the
  host. That frame is decided before it is handed to the transport, and from
  then the stream is finished: its number is free once the client has the
  frame, even while the client's answer to it is pending.
- A client's cancel takes effect at once: nothing more of the stream is sent,
  and its `error` comes when the serving task has let go. A route cannot be
  stopped once it is answering; it runs on and its answer is dropped, so a
  route that never finishes keeps its number busy (a client uses a fresh one).
- A frame the client fails to take ends that stream alone.
- A frame the host cannot take for a stream it can name (unreadable, a chunk
  after `end`, a second `open` on a live number) ends that stream with an
  `error` and no answer: a body that lost data never reaches a route as
  whole. A chunk for a stream already answered or failed is dropped, since the
  host told the client so.

**A stream's states.** A stream is *receiving* its body until the client's
`end`, then *answering* while the route runs and its answer is sent, and
*finished* once its last frame is decided. What reaches the host in each:

| | Receiving | Answering | Finished |
| --- | --- | --- | --- |
| chunk | taken | dropped if the host already said "stop sending"; after the client's `end`, ends it with `error` | not its: dropped, or the new stream's on that number |
| `end` | body complete | (already had it) | not its |
| cancel | ends it with `error`; the route reading its body fails | nothing more is sent; `error` once the serving task lets go | not its |
| unreadable frame naming it | ends it with `error` | ends it with `error` | not its |
| `open` on its number | ends it with `error`; no new stream | ends it with `error`; no new stream | a new stream |
| a send of it fails | — | ends it, with no last frame | touches nothing else |

Covered in `in_process_host_test`: the upload tests and the download test
(normal flow); "a chunk after the body ended", "an oversize chunk", "a second
open" and "an upload … cancelled" (receiving); "a download the client
abandons", "a cancel is taken at once" and "a byte frame the client cannot
take" (answering); and the "once its last frame is decided" group (finished:
a late cancel, an `open` on the number, a failed last frame, and the number
freed once).

**Chunk ownership.** A chunk a host hands a route is the route's: the host
never writes to its bytes again, so a route may keep it without copying. This
is the contract on `ByteRequest.read`, and `ProtocolByteRoutes._collect`
depends on it. The in-process host copies each frame's payload, because the
client may reuse its buffer. `conduitd` passes `dart:io`'s views of each socket
read, which it never rewrites.

## The Flutter binding

[`ProtocolChannelHost`](../../lib/platform/protocol_channel_host.dart) puts
the host on three platform channels, and only in a build with
`--dart-define=CONDUIT_PROTOCOL_HOST=true`, on iOS. The call in `main.dart` is
behind that const, so a build without it does not reach the host and leaves it
out.

- **Control** (standard codec): the client's `hello`, `open` and `close`; the
  host's `ready` (with the protocol version) and `closed`. Dart sends `ready`
  when it starts, again after a restart of the Dart side (a hot restart keeps
  Swift's handlers), and a client registers its handlers before it sends
  anything. A `hello` sent before Dart listens waits in the engine's buffer
  and is answered too, so a client may hear `ready` twice: its `start` names
  the binding, and a client opens once per start.
  An `open` is answered once the host has started, which may take a while
  the first time. Until then the session takes no messages, a `close` cancels
  the open (it is answered `closed`), and a second `open` of it is refused.
  A start that fails is answered `unavailable` (on a byte stream, as the
  `error` frame of the stream its `open` starts) and is not kept: the next
  `open` or byte stream tries again.
- **RPC** (strings): `<session>\n<message>` both ways, on one channel rather
  than one per session, so a message for a session that is gone is still
  answered (`closed`) instead of finding no handler. A session's name ends
  at the first newline, so `open` refuses a name with one.
- **Bytes** (binary): frames, each answered once taken.

Every send is answered: the reply is the acknowledgement the hold counts. A
reply that never comes from a handler arrives as `null`, which the binding
treats as a failed send, so the session ends and the client is told.

**One engine.** The window scene and CarPlay share the app's one engine, and
CarPlay may start it with no window. Nothing is built until a client opens a
session or a byte stream, and the debug probe opens one only once a window of
the app is in front, so a CarPlay-only launch never builds the host.
