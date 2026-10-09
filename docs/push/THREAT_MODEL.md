# Push notifications: what each party can see

Push notifications are optional and off until you turn them on. Each one is
encrypted on your own server, to a key that never leaves your device. This page
lists what every party in the path learns, and what it cannot learn.

```
your server ──▶ Conduit relay ──▶ Apple (APNs) / Google (FCM) ──▶ your device
your server ──▶ UnifiedPush distributor (Android, optional) ──▶ your device
```

## Your device

Your device holds the private key and auth secret for each account. They are in
the iOS Keychain (shared only with Conduit's notification extension) or in
Android storage encrypted with a Keystore key, and are never backed up or synced.
The device decrypts each push, decides whether to show it, and shows it.

## Your server (Open WebUI or Hermes)

Your server already has your chats. For push it also stores, per device, the
subscription:

- the relay endpoint
- the device's public key and auth secret
- a random device id, a label such as "iPhone", and when the device last checked in

Open WebUI keeps these in the Conduit Push function's user settings, which it
encrypts at rest. Hermes keeps them in a file only its user can read. The
server encrypts each notification, so it chooses what goes in it: a title and a
preview of at most 200 characters.

## The Conduit relay

The relay turns standard Web Push into APNs or FCM messages. It is open
source (`relay/`), it can be self-hosted, and it is stateless: no database, no
access logs, nothing written to disk.

| The relay sees | The relay never sees |
|---|---|
| The APNs or FCM token, sealed inside the endpoint URL and opened in memory for each push | Titles, previews, or any other content |
| Your server's IP address, and when it sends | Which account, server, chat or user a push is about |
| The size class of a push: 598, 1110 or 2134 bytes | The exact length of a message |
| Delivery hints: time-to-live and urgency | Your server's URL or name |
| A random 16-byte subscription id, and a 22-character topic hash keyed with the device's secret | Anything that links two subscriptions or devices together |

Rate-limit counters live in memory for minutes. Metrics are aggregate counts
by provider and result, with no other labels. The hosting provider in front of
the relay sees the same connection metadata as any web host.

An endpoint works like a password: anyone who has it can send pushes to that
device. They still cannot make Conduit show text they choose, because a push
that fails to decrypt is not displayed (or, until Apple grants filtering, shown
only as a silent generic notification). The relay also limits every endpoint
to 60 pushes a minute and 2,000 a day.

## Apple and Google

Apple (APNs) and Google (FCM) see the device token, timing, the encrypted
payload, and the generic fallback text "New notification". They cannot decrypt
the payload. On Android, FCM is only used by the Play build, and only once you
turn push on. The FOSS build has no Google code.

## UnifiedPush (Android)

If you choose a UnifiedPush distributor such as ntfy, your server posts the
encrypted payload straight to the distributor, and the Conduit relay is not
involved. The distributor sees the same things the relay would.

## Turning push off

Turning push off, signing out, or removing an account or Hermes connection
removes that device's subscription from the server and deletes its keys from
the device. If the server can't be reached at that moment, the keys are still
deleted, so nothing sent later can be read. The server forgets subscriptions
that haven't checked in for 30 days, or as soon as a push to one is refused as
gone.
