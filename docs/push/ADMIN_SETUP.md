# Conduit Push for Open WebUI: admin setup

Conduit Push is an open-source Open WebUI **Event function** that lets Conduit
users get push notifications on their phones while the app is closed. One admin
installs it once per server; after that, each user turns push on in Conduit.

The source is in this repository:
[`server-plugins/openwebui/conduit_push.py`](../../server-plugins/openwebui/conduit_push.py)
is the single file you install. It is generated from
[`conduit_push.template.py`](../../server-plugins/openwebui/conduit_push.template.py)
and the shared Web Push library in
[`server-plugins/common/conduit_webpush/`](../../server-plugins/common/conduit_webpush).
The wire format is described in [PROTOCOL.md](PROTOCOL.md).

## What it does

It sends a notification when:

| Event | Who gets it |
|---|---|
| A reply finishes | The user who sent the message. By default only for replies requested from Conduit (the request's `User-Agent` starts with `Conduit/`). Each device can switch to "All my chats". |
| A reply fails | The same user, under the same rule. The preview is empty. |
| Someone posts a top-level message in a channel | Every other channel member: in standard channels, members who still have read access; in group channels and DMs, the members. Thread replies and model replies don't notify. Messages posted through a channel webhook notify every member. |

The server always sends. The device decides whether to show a notification: it
stays quiet while Conduit is open on that chat, and it never shows the same
reply twice. That is why the function doesn't try to tell whether the user is
away.

## Privacy

- **End-to-end encrypted.** Each device creates its own key pair and keeps the
  private key in the iOS Keychain or the Android Keystore. This function
  encrypts every notification on your server, to that device's public key
  (Web Push, [RFC 8291](https://www.rfc-editor.org/rfc/rfc8291)), before it
  leaves your server.
- **What leaves your server.** One HTTPS `POST` per device per notification, to
  the endpoint that device registered. That is either the Conduit relay, which
  forwards the ciphertext to Apple or Google, or the user's own UnifiedPush
  distributor. The body is padded to one of three sizes. Neither the relay nor
  Apple or Google can read the title, preview, chat or account.
- **What your server stores.** Each user's subscriptions are kept in this
  function's *user valves*, inside that user's settings: per device, the push
  endpoint, the device's public key and auth secret, a random device id, a label
  such as "iPhone", the platform, which kinds of notification it wants, and when
  it last checked in. There is also a small per-device delivery status. Open
  WebUI encrypts user valves at rest only when you set
  `ENABLE_VALVE_ENCRYPTION=true`. Someone who can read your database could use
  a stored endpoint to send a device junk, but could not read any notification.
- **What it logs.** Only error categories and counts. It never logs endpoints,
  keys, titles, previews or message text.
- **No new dependencies.** It uses what Open WebUI already ships (`aiohttp`,
  `cryptography`, `pydantic`) and has no `requirements:` line, so installing it
  never runs `pip`.

## Requirements

- Open WebUI **0.10.0 or newer**. Open WebUI's editor refuses to save the
  function on older versions.
- **Plugins enabled.** That is the default; `ENABLE_PLUGINS=false` turns them
  off. Conduit reads `features.enable_plugins` from `/api/config`.
- Outbound HTTPS from the Open WebUI server to the push endpoints your users
  register. If your server needs a proxy, set `HTTPS_PROXY` for Open WebUI; the
  function honors it.

## Install

### From Conduit (one tap)

Sign in to Conduit as an admin of the server and turn on push notifications.
Conduit shows what it is about to install and links to the source. It then
creates the function with the id `conduit_push` and switches it on. When a newer
version ships with the app, Conduit offers to update it.

### By hand

1. In Open WebUI, go to **Admin Panel → Functions**.
2. Add the function, either way:
   - **Import From Link**, with
     `https://raw.githubusercontent.com/cogwheel0/conduit/main/server-plugins/openwebui/conduit_push.py`.
   - **New Function**, then paste the contents of `conduit_push.py`.
3. Make sure the **Function ID is `conduit_push`**. Conduit looks for this id.
   Pasting fills it in from the title; Import From Link leaves it empty, so type
   it. Fill in the description if it is empty.
4. Save. New functions start switched off, so **switch it on** in the
   Functions list.

To update by hand, open the function, replace its code with the new file, and
save. Subscriptions are kept.

## Settings (valves)

Open the function's gear icon in **Admin Panel → Functions**.

| Valve | Default | Meaning |
|---|---|---|
| `allow_private_endpoints` | off | Send to endpoints on private, local or loopback addresses. Leave off unless a user runs a UnifiedPush distributor on your network. |
| `extra_allowed_hosts` | empty | Comma-separated host names that skip the private-address check, such as `ntfy.home.arpa`. Safer than allowing every private address. |
| `max_subscriptions_per_user` | 10 | How many devices each user can register. The most recently seen ones are kept. |
| `timeout_s` | 5 | Seconds to wait for each push endpoint. |
| `max_channel_recipients` | 500 | The most people one channel message notifies. 0 turns channel notifications off. |

Endpoints must be `https`. Unless allowed above, each endpoint passes Open
WebUI's own address check: the one Open WebUI uses for web fetches and webhooks,
which honors `ENABLE_LOCAL_WEB_FETCH` and `WEB_FETCH_FILTER_LIST`. The function
sends through Open WebUI's SSRF-safe HTTP session, which checks each address
again when the connection opens, so a DNS change can't point an endpoint at an
internal address. That second check doesn't apply to traffic sent through a
proxy, because the proxy resolves the name.

## Turning it on for users

Nothing else is needed on the server. Each user opens Conduit's notification
settings and turns on push notifications. Conduit then, for that user and
device:

1. registers the device's encrypted endpoint in this function's user valves,
2. sends a test notification through your server, and
3. shows "On" when the test arrives, or the delivery error if it doesn't.

A user who isn't an admin sees "Needs admin setup" until the function is
installed and switched on, with a link they can send to you.

The user valves also appear under **Controls → Valves → Functions** in Open
WebUI's chat view. They are managed by Conduit; users shouldn't edit them there.

## Troubleshooting

Conduit shows the status this function recorded for each device. The values
are:

| Status | Meaning |
|---|---|
| `blocked` | The endpoint is on a private address, or Open WebUI's address check rejected it. See `allow_private_endpoints` and `extra_allowed_hosts`. |
| `invalid` | The stored subscription is malformed. The function removed it; Conduit registers the device again. |
| `gone` | The endpoint answered 404 or 410: the app was uninstalled or its push token changed. The function removed it. |
| `timeout`, `network` | The endpoint couldn't be reached in `timeout_s` seconds. Check outbound HTTPS and proxies. |
| `rate_limited`, `server_error`, `too_large`, `rejected` | The endpoint answered 429, 5xx, 413 or another 4xx. Notifications are best effort and aren't retried. |

If nothing arrives at all, check that the function is switched on and that its
id is `conduit_push`.

## Removing it

Delete the function in **Admin Panel → Functions**. Notifications stop
immediately. The subscriptions stay in user settings but are no longer used, and
Conduit shows "Needs admin setup" again.
