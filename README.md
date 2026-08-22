<h1 align="center">Conduit</h1>

<p align="center">
  <img
    src="assets/icons/icon.png"
    alt="Conduit icon"
    width="96"
    height="96"
  />
</p>

<p align="center">
  <strong>A native mobile client for Open WebUI, your own model endpoints, and self-hosted agents.</strong>
</p>

<p align="center">
  <img
    alt="Latest Release"
    src="https://img.shields.io/github/v/release/cogwheel0/conduit?display_name=tag&color=0A84FF"
  />
  <img
    alt="GitHub all downloads"
    src="https://img.shields.io/github/downloads/cogwheel0/conduit/total?style=flat-square&label=Downloads&logo=github&color=111827"
  />
  <img
    alt="License: GPL-3.0"
    src="https://img.shields.io/badge/License-GPL%203.0-16A34A"
  />
</p>

<p align="center">
  <a href="https://play.google.com/store/apps/details?id=app.cogwheel.conduit">
    <img
      src="docs/store-badges/google.webp"
      alt="Get it on Google Play"
      height="56"
    />
  </a>
  <a
    href="https://apps.apple.com/us/app/conduit-open-webui-client/id6749840287"
  >
    <img
      src="docs/store-badges/apple.webp"
      alt="Download on the App Store"
      height="56"
    />
  </a>
</p>

<p align="center">
  <a href="https://vercel.com/blog/vercel-open-source-program-fall-2025-cohort#conduit">
    <img
      alt="Vercel OSS Program"
      src="https://vercel.com/oss/program-badge.svg"
      width="240"
      height="24"
      align="middle"
    />
  </a>
  &nbsp;
  <a
    href="https://trendshift.io/repositories/15397?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-15397"
    target="_blank"
    rel="noopener noreferrer"
  >
    <img
      src="https://trendshift.io/api/badge/trendshift/repositories/15397/daily?language=Dart"
      alt="cogwheel0/conduit: #1 Dart repository of the day on Trendshift"
      width="200"
      height="44"
      align="middle"
    />
  </a>
</p>

<p align="center">
  <a href="#four-ways-to-connect">Connect</a> ·
  <a href="#screenshots">Screenshots</a> ·
  <a href="#what-you-get">Features</a> ·
  <a href="#getting-started">Getting Started</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="docs/BUILDING.md">Build from Source</a>
</p>

<br>

<p align="center">
  <img
    src="https://github.com/user-attachments/assets/8531f859-a2c4-4e61-877e-9885d1413f4e"
    alt="Conduit demo"
    width="360"
  />
</p>

<br>

Open WebUI is excellent on the desktop. On mobile it breaks down at the edges:
authentication behind a reverse proxy, streaming that drops when the app
backgrounds, getting a screenshot into a prompt, starting a chat from the home
screen. Conduit is a real Flutter app built to close that gap, and as of 4.0 it
works with or without an Open WebUI server at all.

Your chats live on your device first. Nothing routes through a backend the
maintainer operates.

## Ways to connect

On first launch Conduit asks how you want to connect. Pick one, add the others
later, and skip any sign-in you don't need.

| | | |
| --- | --- | --- |
| **Open WebUI** | Your self-hosted server | Full feature set: chats, folders, notes, channels, workspace, tools, web search, image generation |
| **Direct** | OpenAI-compatible, Ollama, OpenRouter | Talk straight to a provider or a model on your own machine. No Open WebUI account required |
| **Apple On-Device** | Apple Intelligence | Run Apple's local model offline on eligible iOS 26 devices without an API key |
| **Apple PCC** | Apple Private Cloud Compute | Use Apple's private cloud model on eligible iOS 27 devices without an API key |
| **Hermes** | Your self-hosted agent | An agent that runs tools, asks before sensitive steps, and works on a schedule |

**Direct connections** cover OpenAI-compatible endpoints (Chat Completions or
Responses), LM Studio, Azure-style API versions, native Ollama, and first-party
OpenRouter. Bring an API key, or skip it for a local endpoint that doesn't want
one. Direct connections you already configured in Open WebUI come along
automatically. Keys and custom headers stay in platform secure storage.

**Apple On-Device** is an iOS-only Direct provider backed by Apple's local
SystemLanguageModel. It requires iOS 26 and Apple Intelligence, works offline,
and supports streaming, sampling controls, and JSON-schema responses with a 4K
context window. Image input, reasoning controls, and tool calling are not
available.

**Apple Private Cloud Compute** is an iOS-only Direct provider. It uses Apple's
Foundation Models framework, streams responses through the same chat path as
other Direct models, and requires iOS 27, Apple Intelligence availability, and
Apple's managed PCC entitlement. It supports image input, reasoning levels,
sampling and output limits, JSON-schema responses, live quota/context status,
and an optional on-device fallback for PCC network failures. Tool calling is
not enabled.

**Hermes Agent** connects to your own Hermes server. You watch its tools work
live, approve sensitive steps before they run, and let scheduled agents run
while you sleep. Conversations and schedules get their own tab, and Conduit only
exposes the capabilities your server actually reports.

## Screenshots

| Chat | Connect | Chats | Voice |
| --- | --- | --- | --- |
| <img src="docs/screenshots/1.png" alt="Multimodal chat with an image attachment and streaming response" width="200" /> | <img src="docs/screenshots/2.png" alt="Choose a Conduit chat backend" width="200" /> | <img src="docs/screenshots/3.png" alt="Chat with rich replies and Ask Conduit input" width="200" /> | <img src="docs/screenshots/4.png" alt="Voice call mode listening with call controls" width="200" /> |

## What you get

### Chat that survives mobile

Token-by-token streaming over WebSocket. The transcript holds its place while a
response grows, pinned prompts stay put, and long conversations load without
stalling the UI. Search across conversations, organize with folders, pin what
matters, or start a temporary chat that leaves nothing behind.

### Rendering that holds up on a phone

Native Flutter surfaces, not a web view wrapped in a shell:

- syntax-highlighted code blocks with copy and preview
- Mermaid diagrams rendered natively
- LaTeX and math
- expandable reasoning, tool-call, and code-execution sections
- inline citations, source cards, and follow-up suggestions
- Chart.js embeds

### A real Workspace

Models, knowledge, prompts, tools, and skills as native screens with unified
settings navigation. Sections you don't have permission for simply don't appear.

### Everything else

| Area | What's included |
| --- | --- |
| Files and media | Uploads, re-attaching previously uploaded server files, multimodal prompts, clipboard image paste, audio attachments |
| Notes | Autosave, pinning, AI-generated titles, AI enhancement, audio recording, all available offline |
| Channels | Threads and reactions, when your server enables them |
| Voice | Voice input with on-device or server speech recognition, plus a full voice-call mode |
| Home screen | Widgets on iOS and Android for new chat, mic, camera, photos, and clipboard; app quick actions; iOS App Intents and Shortcuts |
| Sharing | Share-sheet ingestion from other apps straight into a prompt |
| Terminal | Interactive sessions over WebSocket with a file browser, shown only when your server exposes it |
| Personalization | Light, dark, and system themes; five accent palettes; adaptive Material and Cupertino UI; haptics |
| Languages | 14 locales: English, German, Spanish, French, Italian, Japanese, Korean, Dutch, Russian, Simplified and Traditional Chinese, Czech, Slovak, Polish |

Server-dependent features (channels, notes, web search, image generation,
toggle filters, terminal) appear only when your deployment exposes them.

## Built for self-hosted reality

Most mobile clients assume a plain login form. Real deployments rarely look like
that.

- **Every auth path Open WebUI offers**: username and password, LDAP, manual JWT
  entry, SSO and OAuth providers.
- **Reverse proxies actually work**: `oauth2-proxy`, Authelia, Authentik,
  Pangolin, and Cloudflare Tunnel, by capturing the right cookies and session
  state on-device.
- **Custom headers during setup** for environments that require `X-API-Key`,
  `Authorization`, or organization routing headers.
- **Credentials in Keychain or Keystore**, never plain-text local storage.
- **Tracks upstream**: Conduit supports Open WebUI 0.11.

## Getting started

Install from the [App Store](https://apps.apple.com/us/app/conduit-open-webui-client/id6749840287)
or [Google Play](https://play.google.com/store/apps/details?id=app.cogwheel.conduit),
then pick how you want to connect.

<details open>
<summary><strong>Open WebUI</strong></summary>

1. Launch Conduit and choose Open WebUI.
2. Enter your instance's base URL.
3. Add any required custom headers.
4. Sign in with username and password, LDAP, JWT, SSO, or proxy auth.
5. Pick a model and start chatting.

</details>

<details>
<summary><strong>Direct connection</strong></summary>

1. Launch Conduit and choose Direct connection.
2. Add an OpenAI-compatible or Ollama profile with its base URL and any API key
   or custom headers.
3. Test the connection, enable it, and select a discovered or manually entered
   model.
4. Choose whether new direct chats use Open WebUI history when one is signed in,
   or stay only on this device. Existing chats keep their current location.
5. Start chatting. No Open WebUI account required.

</details>

<details>
<summary><strong>Apple On-Device</strong></summary>

1. On an eligible iOS 26 device, launch Conduit and choose Apple On-Device.
2. Conduit checks Apple Intelligence and local-model availability. No API key
   or network connection is required.
3. Start chatting. New Apple-only installations keep Direct history on the
   device unless you later enable Open WebUI history.

</details>

<details>
<summary><strong>Apple Private Cloud Compute</strong></summary>

1. On an eligible iOS 27 device, launch Conduit and choose Apple Private Cloud
   Compute.
2. Conduit checks Apple Intelligence and PCC availability. No API key is
   required.
3. Start chatting. New PCC-only installations keep Direct history on the
   device unless you later enable Open WebUI history.

</details>

<details>
<summary><strong>Hermes Agent</strong></summary>

1. Launch Conduit and choose Hermes Agent.
2. Enter your Hermes server URL and `API_SERVER_KEY`.
3. Optionally set a memory key to scope the agent's long-term memory to you. One
   is generated automatically on first chat if you leave it blank.
4. Open the Hermes tab for conversations and scheduled agents.

</details>

## Privacy

- Chats, notes, and drafts are stored on your device. Notes and drafts stay
  available without a connection.
- Credentials use platform secure storage: Keychain on iOS, Keystore on
  Android.
- No third-party analytics or advertising SDKs.
- Diagnostic logging is local and transient.
- No developer-operated backend relays your data. Traffic goes from your device
  to the server or provider you configured, and nowhere else.
- Signing out lets you choose what stays behind. Clearing everything clears
  on-device chats too, and fails safely rather than half-deleting.

Full details in [PRIVACY_POLICY.md](PRIVACY_POLICY.md).

## Build from source

See **[docs/BUILDING.md](docs/BUILDING.md)** for requirements, submodules,
codegen, verification, project layout, and troubleshooting.

```bash
git clone --recursive https://github.com/cogwheel0/conduit.git
cd conduit
flutter pub get
dart run build_runner build
flutter run -d ios   # or: flutter run -d android
```

Clone recursively and run `build_runner`. The Mermaid renderer is a submodule,
and generated Dart files are git-ignored.

## Contributing

Conduit is actively developed and feedback is welcome.

- Bugs → [GitHub Issues](https://github.com/cogwheel0/conduit/issues)
- Features, deployment notes, questions →
  [GitHub Discussions](https://github.com/cogwheel0/conduit/discussions)

Unsolicited pull requests are not the primary contribution path right now. Open
an issue or discussion first so changes line up with the roadmap.

## Enterprise and white-label

For private distribution, internal deployment support, or a custom
enterprise/white-label build, open a discussion or reach the maintainer at
[cogwheel@cogwheel.app](mailto:cogwheel@cogwheel.app).

## Support

If Conduit is useful to you, you can support development through
[GitHub Sponsors](https://github.com/sponsors/cogwheel0) or
[Buy Me a Coffee](https://www.buymeacoffee.com/cogwheel0).

## Acknowledgements

- Supported by the [Vercel OSS Program](https://vercel.com/blog/vercel-open-source-program-fall-2025-cohort#conduit).
- Tested with BrowserStack.
- Code review provided by <a href="http://macroscope.com/?utm_source=open_source&utm_term=conduit">
    <picture>
      <source
        media="(prefers-color-scheme: dark)"
        srcset="https://macroscope.com/assets/Brand%20Kit/Macroscope%20Logos/svg/Macroscope%20Logotype%20-%20white.svg"
      />
      <img
        src="https://macroscope.com/assets/Brand%20Kit/Macroscope%20Logos/svg/Macroscope%20Logotype%20-%20black.svg"
        alt="Macroscope"
        height="16"
        align="middle"
      />
    </picture>
  </a>.

## License

Released under the [GPL-3.0 License](LICENSE).

Conduit is an independent client and is not affiliated with Open WebUI.
