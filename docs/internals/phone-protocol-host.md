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
  host, and its number may be used again only after that.
- A client's cancel takes effect at once: nothing more of the stream is sent,
  and its `error` comes when the serving task has let go. A route cannot be
  stopped once it is answering; it runs on and its answer is dropped, so a
  route that never finishes keeps its number busy (a client uses a fresh one).
- A frame the client fails to take ends that stream alone.

**Chunk ownership.** A chunk a host hands a route is the route's: the host
never writes to its bytes again, so a route may keep it without copying. This
is the contract on `ByteRequest.read`, and `ProtocolByteRoutes._collect`
depends on it. The in-process host copies each frame's payload, because the
client may reuse its buffer. `conduitd` passes `dart:io`'s views of each socket
read, which it never rewrites.
