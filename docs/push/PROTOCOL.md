# Conduit push protocol (`cp/1`)

Conduit push notifications are end-to-end encrypted. The user's own server
(the Open WebUI "Conduit Push" function or the Hermes `conduit` plugin)
encrypts every notification to a key that only exists on the user's device.
The Conduit relay turns standard Web Push into APNs or FCM and never sees
anything but ciphertext. On Android, UnifiedPush skips the relay entirely.

```
server (encrypts) ──Web Push──▶ relay ──APNs / FCM──▶ device (decrypts, shows)
server (encrypts) ──Web Push──▶ UnifiedPush distributor ──▶ device
```

Test vectors for every layer live in [`push/test-vectors/`](../../push/test-vectors).
The Python reference implementation is
[`server-plugins/common/conduit_webpush/`](../../server-plugins/common/conduit_webpush).

## 1. Subscription

One subscription exists per (account or Hermes connection, device). It holds:

| Field | Size | Where it lives |
|---|---|---|
| `sid` | 16 random bytes, base64url without padding (22 chars) | device, server, sealed inside the relay endpoint |
| `p256dh` | P-256 public key, uncompressed (65 bytes), base64url | device, server |
| private key | P-256 scalar | device only (iOS Keychain / Android Keystore-wrapped) |
| `auth` | 16 random bytes, base64url | device, server |
| `endpoint` | `https` URL | device, server |

The server stores a subscription as:

```json
{"sid": "…", "did": "…", "endpoint": "https://…", "p256dh": "…", "auth": "…",
 "events": ["reply", "reply_failed", "channel", "cron"], "origin": "conduit",
 "label": "iPhone", "platform": "ios", "proto": 1, "seen": 1760000000}
```

- `did` is a random per-install id. A device replaces its older entries with the same `did`.
- `origin` (Open WebUI only) is `conduit` or `any`. With `conduit`, the function only sends
  replies to chats whose completion request carried a `Conduit/…` User-Agent.
- `seen` is refreshed by every subscribe. Servers drop entries not seen for 30 days.

## 2. Inner payload

The plaintext is compact UTF-8 JSON:

```json
{"v": 1, "k": "reply", "src": "owui",
 "ids": {"chat": "c1", "msg": "m1"},
 "t": "Trip ideas", "b": "Here are three routes along the coast…",
 "ts": 1760000000, "dk": "chat:c1:m1", "g": "chat:c1"}
```

| Key | Type | Meaning |
|---|---|---|
| `v` | int | Always `1`. Devices drop any other version. |
| `k` | string | `reply`, `reply_failed`, `channel`, `cron`, or `test` |
| `src` | string | `owui` or `hermes` |
| `ids` | object | Any of `chat`, `msg`, `channel`, `session`, `turn`, `job`, `run` (strings) |
| `t` | string | Title, at most 100 code points. May be empty. |
| `b` | string | Plain-text preview, at most 200 code points. May be empty. |
| `a` | string | Optional author (channel messages), at most 64 code points |
| `ts` | int | Unix seconds when the server built the payload |
| `dk` | string | Dedup key (below) |
| `g` | string | Optional group: iOS thread identifier and Android group |
| `n` | string | Test nonce, only for `k == "test"` |

Unknown keys are ignored. Servers sanitize the preview before truncating
it. They look at the first 4000 characters only, and drop everything from a
`<details>` or `<think>` block left open by that cut. They strip `<details>`
and `<think>` blocks, fenced code, images, link markup, and Markdown markers,
then collapse whitespace, then cut on code points and append `…`.

### Dedup keys

| Event | `dk` | `g` |
|---|---|---|
| Open WebUI reply or failure | `chat:<chatId>:<messageId>` | `chat:<chatId>` |
| Open WebUI channel message | `channel:<channelId>:<messageId>` | `channel:<channelId>` |
| Hermes reply or failure | `hermes:<sessionId>:<turnId>` | `hermes:<sessionId>` |
| Hermes scheduled task | `cron:<jobId>:<runId>` | `cron:<jobId>` |
| Test | `test:<nonce>` | none |

The device prefixes `dk` with the subscription's scope to form the app-wide
key: `owui:<accountId>|chat:c1:m1`, `hermes:<connectionId>|…`, or
`direct|…`. The app's own socket-driven notifications build the same keys,
so a reply never notifies twice.

## 3. Encryption

Web Push message encryption ([RFC 8291](https://www.rfc-editor.org/rfc/rfc8291))
with the `aes128gcm` content coding ([RFC 8188](https://www.rfc-editor.org/rfc/rfc8188)):

- A fresh ephemeral P-256 key pair and a fresh 16-byte salt are used for every message.
- There is exactly one record, and the record size field is always `4096`.
- Header: `salt (16) ‖ rs = 4096 (uint32 BE) ‖ idlen = 65 (1) ‖ as_public (65)`. That is 86 bytes.
- The plaintext is followed by the delimiter `0x02` and then zero bytes. The padding takes
  the AES-GCM output (padded plaintext plus the 16-byte tag) to exactly
  **512, 1024 or 2048 bytes**, whichever is the smallest that fits. A payload
  that doesn't fit in 2048 bytes is rejected; senders shorten `b` and try again.
- So a body is always 598, 1110 or 2134 bytes.

Receivers must check that `idlen == 65`, that `rs >= 18`, that the body
holds exactly one record (`ciphertext length <= rs`), that the last non-zero
byte of the decrypted record is `0x02`, and that the body is at most 2134
bytes.

## 4. Sending (server → relay or distributor)

`POST <endpoint>` with the body above and these headers:

| Header | Value |
|---|---|
| `Content-Encoding` | `aes128gcm` |
| `Content-Type` | `application/octet-stream` |
| `TTL` | seconds: `reply`, `reply_failed` and `channel` 86400; `cron` 259200; `test` 300 |
| `Urgency` | `high`, or `normal` for `cron` |
| `Topic` | first 22 chars of `base64url(HMAC-SHA256(auth, dk))` |

`Topic` lets the relay collapse retries of the same message without learning
anything: it is keyed with the per-subscription `auth` secret.

Responses:

| Status | Sender action |
|---|---|
| 201, 202 | Delivered to Apple, Google or the distributor. |
| 404, 410 | Subscription is dead. Delete it. |
| 413 | Body too large. Not retried. |
| 429, 5xx | Dropped. Notifications are best effort and are not retried. |

No VAPID is used in protocol 1. An endpoint is an unguessable capability.

## 5. Relay API

The relay is stateless. It keeps no database and no access logs.

### `GET /v1/info`

```json
{"proto": 1, "active_kid": 1, "max_body": 2134, "providers": ["apns", "fcm"]}
```

### `POST /v1/register`

```json
{"provider": "apns", "token": "<hex APNs token or FCM token>",
 "app": "app.cogwheel.conduit", "env": "prod", "sid": "<22-char sid>"}
```

- `provider`: `apns` or `fcm`
- `env`: `prod` or `dev`. It only matters for APNs, where it selects the sandbox host.
- `app`: must be in the relay's allow-list for that provider.

`200 {"endpoint": "https://relay.example/v1/push/<sealed>", "kid": 1}`

Errors:

| Status | `error` |
|---|---|
| 400 | `invalid_request` |
| 403 | `app_not_allowed` |
| 429 | `rate_limited` (with `Retry-After`) |
| 503 | `provider_unconfigured` |

`sealed` is `base64url(0x01 ‖ kid (1) ‖ nonce (24) ‖ XChaCha20-Poly1305(K[kid],
nonce, aad = "cp-relay/1" ‖ kid, json))`. The sealed JSON is
`{"p": provider, "e": env, "a": app, "s": sid, "t": token, "i": issued_at}`.
Only the relay can open it. The relay can rotate `K` by adding a key id: devices
re-register when `/v1/info` reports a newer `active_kid` than their endpoint
carries (the second byte of `sealed`). Retired key ids answer 410.

### `POST /v1/push/{sealed}`

This is a standard Web Push receiver. It answers `201` once Apple or Google has
accepted the message.

| Status | Meaning |
|---|---|
| 400 | Missing `TTL`, a malformed body header, or a body that couldn't be read |
| 404 | The endpoint can't be opened |
| 408 | The body didn't arrive within 10 seconds of the headers |
| 410 | APNs or FCM says the token is gone, or the key id is retired |
| 413 | Body over 2134 bytes |
| 415 | Not `aes128gcm` |
| 429 | Rate limited |
| 502, 503 | The provider failed |

APNs request (`apns-push-type: alert`, `apns-priority` 10, or 5 for `Urgency`
`normal` and lower, `apns-expiration` = now + TTL, `apns-collapse-id` = `Topic`):

```json
{"aps": {"alert": {"title-loc-key": "push.fallback.title", "loc-key": "push.fallback.body"},
         "mutable-content": 1, "sound": "default"},
 "cp": {"v": 1, "s": "<sid>", "d": "<base64url body>"}}
```

If the Notification Service Extension can't run, iOS shows the localized
fallback ("New notification"), never content.

FCM HTTP v1 request (data only, `android.priority` `HIGH` or `NORMAL`, `android.ttl` = TTL,
`android.restricted_package_name` = the registered `app`, so the token can only reach that
package, and no `collapse_key`: FCM keeps only four collapse keys per offline device, and
every message has its own `Topic`, so the device would get an arbitrary four back):

```json
{"message": {"token": "<token>", "data": {"cp_v": "1", "cp_s": "<sid>", "cp_d": "<base64url body>"}}}
```

### Health and metrics

- `GET /healthz` returns 200 while the process is up.
- `GET /readyz` returns 200 when every configured provider can authenticate.
- Metrics are aggregate counters only, served on a separate internal address.

## 6. UnifiedPush

On Android, the user can pick a UnifiedPush distributor (ntfy and others).
The distributor's endpoint is the subscription endpoint, and the server posts
the same body to it. The connector instance is the `sid`.

## 7. Receiving (device)

1. Find the subscription by `sid`. If it is unknown, the push is dropped
   (shown as a passive generic notification until Apple grants the filtering
   entitlement).
2. Decrypt, parse `cp/1`, and build the app-wide dedup key.
3. A `test` push records `n` so the app can mark the subscription as
   verified, even if the steps below don't show it.
4. If the user switched push, this kind or this account off on the device,
   drop the push (shown as a passive generic notification until Apple grants
   the filtering entitlement). A dropped push claims nothing.
5. Claim the key in the shared ledger. If it was already shown, drop the push.
   Until Apple grants the filtering entitlement, iOS instead shows it again
   with its decrypted content, silently and as passive, because a push with
   the same `Topic` replaces the earlier notification on screen.
6. Show it: title `t` (or a localized fallback for the kind), body `b`, and the
   account label as the subtitle when more than one account is subscribed.
   The thread or group is `<scope>|<g>`, so one server can't merge its
   notifications into another account's. A tap opens the item in that account;
   on iOS the extension signs the tap so the app only acts on taps it wrote.
