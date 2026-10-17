# Conduit push for Hermes Agent

A Hermes platform plugin that gives [Conduit](https://github.com/cogwheel0/conduit)
end-to-end encrypted push notifications. Hermes notifies every Conduit device
subscribed to this Hermes profile when:

- **a reply finishes**, or fails, in a chat started from Conduit;
- **a cron job delivers** with `deliver: conduit`;
- **Conduit asks for a test push**, to check that delivery works.

Replies to chats started anywhere else (Telegram, Open WebUI, the CLI, other API
clients) never trigger a push, and cron runs only reach your phone through
`deliver: conduit`.

This repository is a read-only mirror of `server-plugins/hermes/conduit/` in the
Conduit repository. Changes and issues belong there.

## Privacy and security

- Each notification is a short JSON message (a title, a preview of at most 200
  characters, and ids). It is encrypted **on your Hermes server** to a key that
  only exists on your device, using Web Push message encryption (RFC 8291,
  `aes128gcm`), and padded to one of three fixed sizes.
- The Conduit relay, Apple and Google only ever handle ciphertext. On Android
  with UnifiedPush, the relay is skipped altogether.
- Your Hermes server stores, per profile, in `conduit_push/` inside the Hermes
  home: each device's push endpoint, its public key and auth secret, a device
  label, and which notification kinds it wants (`subscriptions.json`), plus the
  API sessions Conduit is currently waiting on (`watches.json`). Both files are
  readable only by your user. A device that has not checked in for 30 days is
  dropped, and so is any device whose endpoint reports it is gone.
- Logs record only counts and error categories, never endpoints, keys or text.
- The plugin uses only `httpx` and `cryptography`, which already ship with
  Hermes. It runs no commands and adds no tools for the agent.
- **The agent can put text on your phone.** Registering `conduit` as a
  platform makes it a target for the agent's own `send_message` tool, and for
  cron jobs the agent creates. Whatever the agent writes there is pushed to
  every subscribed device. So anyone who can prompt this Hermes profile, on
  any platform it listens on (Telegram, Discord, a shared API key, ...), may
  be able to make text of their choosing appear on your lock screen. Such a
  message is titled "Hermes" instead of a job name. That label is a hint, not
  a guarantee: the agent can also write text that looks like a cron delivery,
  or create a real job. Treat these notifications like any other message from
  the agent, and enable this plugin only on profiles that just trusted people
  can prompt.

The protocol is documented in `docs/push/PROTOCOL.md` in the Conduit repository.

## Install

Hermes 0.21.2 or newer.

### From Conduit (desktop mode)

When Conduit is connected to the Hermes desktop app or `hermes serve`, turning
on push notifications in Conduit offers to install this plugin in one tap. It
installs a pinned commit, enables it, and asks you to restart Hermes once:
plugin routes and hooks load when Hermes starts.

### From the command line

```sh
hermes plugins install cogwheel0/conduit-hermes-push --ref <40-character commit SHA> --enable
hermes gateway restart
```

- `--ref` pins one exact commit. Leave it out to install the latest version.
- For a named profile, put `-p <profile>` before the subcommand, for example
  `hermes -p work plugins install ...` and `hermes -p work gateway restart`.
  Each profile needs the plugin installed and enabled on its own.
- Hermes scans plugins before installing them. This one is expected to scan clean.
- If you use the desktop app or `hermes serve` instead of the gateway, restart
  that instead.

To remove it: `hermes plugins remove conduit`, then restart Hermes.

## Cron jobs

The plugin registers a delivery platform named `conduit` whose home channel is
`devices`, meaning every subscribed device. Set a job's delivery target to
`conduit` (in Conduit, the job editor's "Notify me" switch does this), or list
it with others, for example `deliver: telegram,conduit`. No other setup is
needed.

The notification shows the job's name as its title and the start of its output
as the preview. Failure notices for a job go wherever its delivery (or
`failure_deliver`) target points, so they reach your devices too. A job set to
`deliver: all` also includes `conduit`. If the agent itself uses its message
tool to reach `conduit`, that arrives as a notification titled "Hermes" (see
[Privacy and security](#privacy-and-security)).

Cron delivery works with the gateway running, and without it: the desktop app
and `hermes serve` run cron themselves.

## How Conduit talks to the plugin

Conduit manages its subscription with small JSON requests
(`hello`, `subscribe`, `unsubscribe`, `list`, `watch`, `test`):

- **Through the gateway API server:** `POST /api/platforms/conduit/events`
  (or `/p/<profile>/api/platforms/conduit/events` on a multi-profile gateway),
  authorized with the same bearer key as the rest of the API server. Keys shorter
  than 16 characters are refused.
- **Through the dashboard (desktop mode):** `POST /api/plugins/conduit/v1/events`
  and `GET /api/plugins/conduit/v1/hello`, behind the dashboard's own sign-in.

A reply in an API server session is pushed only while Conduit holds a `watch`
on that session (at most six hours), so other apps using the same API server
stay quiet.
