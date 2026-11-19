# Fake GPT-Live for a local Hermes gateway

Lets a real local Hermes Desktop Gateway (`hermes serve` from `hermes-src`)
run GPT-Live voice calls with no network and no OpenAI key, for the desktop
app's `--e2e voice-call-hermes` pass (macOS only).

A real gateway opens a GPT-Live call by exchanging the client's WebRTC offer
for an answer at `{voice.gpt_live.base_url}/live/sessions`. Pointed at
`fake_gpt_live.py` instead, the offer goes to `peer.html`, which answers it
in WebKit (`peer_host.swift`, a process of its own, never shown, never the
microphone). The page plays a steady tone as the voice, measures what it
hears from the app, and speaks GPT-Live's data-channel events with invented
lines:

1. `session.started` once the data channel opens;
2. after hearing the app for a second: the user's words ("Ask the chat for
   the harbour opening hours."), the voice's reply, then
   `session.delegation.created`;
3. the chat's answer, when it comes back as `session.commentary.append`,
   said back as the voice's words;
4. `session.closed` when asked to close.

`GET /stats` reports the sessions the gateway opened (model, voice,
delegation, whether the offer kept its closing CRLF), what the page heard
(`peer.heard`, `peer.heardPeak`) and every event it got.

## Run it

```sh
tool/local_hermes_live/live.sh start 19335   # builds the peer host once
tool/local_hermes_live/live.sh stats
tool/local_hermes_live/live.sh stop
```

`CONDUIT_GPT_LIVE_DIR` holds the build, logs and pids (default
`~/Library/Caches/conduit-dev/gpt-live`).

## The gateway's config

Add to the gateway's `$HERMES_HOME/config.yaml` (any key works; it only
reaches the fake):

```yaml
voice:
  voice_chat_mode: gpt-live
  gpt_live:
    api_key: "local-demo"
    base_url: "http://127.0.0.1:19335/v1"
    voice: "marin"
```

`GET /api/audio/voice-live/status` then answers `mode: gpt-live,
available: true`, and the app's Hermes chats start Realtime calls. The
gateway's model answers the delegated request; a scripted one should answer
"harbour opening hours" (the E2E pass expects "opens at eight").
