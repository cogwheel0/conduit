# Building Conduit Desktop

> **The daemon is a bundle, not a single executable.** `dart compile exe`
> refuses to run once any dependency has build hooks, and `drift` brings
> `sqlite3`, which has them. `dart build cli` produces
> `apps/daemon/build/cli/<os>_<arch>/bundle/` containing `bin/conduitd` and a
> sibling `lib/libsqlite3.so`. The binary cannot be lifted out on its own, so
> packaging ships the directory.

The desktop client is an Electron shell around two Dart programs: `conduitd`,
a native sidecar that hosts the shared core, and a Jaspr renderer that talks
to it over a loopback JSON-RPC WebSocket. This file is how to build, test and
package it.

> Status: M0 to M9 are done, apart from the Apple helper (WP-8.4) and what
> needs signing certificates. M10 (hardening and the public release) is in
> progress.

## Requirements

| | |
| --- | --- |
| Flutter SDK | `3.47.1` with Dart `3.13.1` (same as the mobile app) |
| Node.js | 22 or newer, for the Electron shell and the Tailwind CLI |
| Linux only | Electron needs GTK: `libgtk-3-0 libnss3 libasound2t64 libatk-bridge2.0-0 libgbm1` |

## First build

From a fresh clone (with submodules, see [BUILDING.md](BUILDING.md#clone)):

```bash
./scripts/bootstrap_desktop.sh
cd desktop/electron && npm run dev
```

`bootstrap_desktop.sh` runs every generator in dependency order and is what CI
runs too, so "works on my machine" and "works in CI" stay the same thing.

## What works today

Everything the phone app does against Open WebUI, Hermes Agent and direct
connections, plus what a desktop adds:

| Area | What is there |
| --- | --- |
| Servers and sign-in | Several servers; password, LDAP, API key, SSO/OAuth/proxy windows; custom headers, self-signed and mutual TLS |
| Chat | Streaming, stop, regenerate and edit as branches, attachments, `/` prompts, `@` models, `#` knowledge, web search, image generation, tools, MCP, terminal |
| Rendering | Markdown, code highlighting, KaTeX, Mermaid, charts and HTML previews in a sandbox, citations, reasoning and tool-call sections |
| Organise | Folders, tags, pins, archive, search, share, export, temporary chats |
| Notes, channels, workspace | Notes with recordings, channels with threads and reactions, models/knowledge/prompts/tools/skills with access control |
| Hermes Agent | Its API server as a backend: sessions, approvals, schedules, skills |
| Terminal | Open WebUI terminal servers: a shell, files, ports and previews |
| Voice | Dictation, read aloud, voice calls, Settings → Audio |
| Desktop | Tray, open at login, `conduit://` links, "Open with Conduit", notifications, quick ask, rebindable shortcuts, What's new |

| Not yet | Where it lands |
| --- | --- |
| On-device speech and Apple models on macOS | WP-8.4, the Swift helper |
| Signed and notarized packages, store listings | WP-9.5/9.6, needs certificates and a first release |
| Local speech recognition on Windows and Linux | M11 |

Run `npm test` in `desktop/electron` to check the shell still launches and
talks to the daemon.

### Testing against a real server

`tests/live-chat.spec.ts` drives the whole product — onboarding, sign-in, the
model list, a sent message and a streamed reply — against a real Open WebUI
instance. It skips itself unless a `.env` at the repository root supplies:

```
OWUI_URL=https://chat.example.com
OWUI_EMAIL=you@example.com
OWUI_PASSWORD=...
OWUI_MODEL=gemma3:1b          # optional; see below
```

`apps/daemon/test/live_server_test.dart` does the same at the daemon level
and is much faster to iterate on when something breaks — it was where every
bug in this path was actually found.

`OWUI_MODEL` is worth setting. Without it the daemon falls back to "the first
model the server offers", which on a real deployment is as likely as not to
be one the account cannot use; the refusal is reported properly now, but a
test that picks a working model is a better test of the happy path.

`CONDUIT_SPEECH_SAMPLE`, set to a WAV of someone saying "The quick brown
fox jumps over the lazy dog.", makes both live suites test dictation and a
voice call with real words: the Electron spec plays it through Chromium's
fake microphone. Without it they check only that transcription answers.

The other Electron specs need no server: `launch.spec.ts` (the shell, the
security boundaries), `direct-only.spec.ts` and `hermes-only.spec.ts` (fake
providers), and `desktop-shell.spec.ts` (links, tray, quick ask, shortcuts).
`npm run test:unit` runs the main process's own unit tests.

**`.env` and `test-results/` are both gitignored, and must stay that way.** A
Playwright failure snapshot captures the DOM, and the DOM of a sign-in form
contains the password that was typed into it.

## The command matrix

Every generated artifact, what produces it, and where it must run. Nothing
here is checked in — all of it is git-ignored and rebuilt.

| Artifact | Command | Working directory |
| --- | --- | --- |
| Mobile freezed/json/riverpod/drift code | `dart run build_runner build` | repo root |
| Mobile localizations | `flutter gen-l10n` (implicit in `flutter pub get`) | repo root |
| `conduit_core` models | `dart run build_runner build` | `packages/conduit_core` |
| `conduit_protocol` DTOs | `dart run build_runner build` | `packages/conduit_protocol` |
| slang input JSON | `dart run tool/arb_to_slang.dart` | repo root |
| Desktop translations | `dart run slang` | `apps/desktop_ui` |
| `web/theme.css` | `dart run conduit_theme:generate_theme_css` | repo root |
| `web/app.css` | `npx tailwindcss -i styles/app.css -o ../../apps/desktop_ui/web/app.css` | `desktop/electron` |
| `web/main.dart.js` | `dart compile js -O2 -o web/main.dart.js lib/main.dart` | `apps/desktop_ui` |
| `conduitd` bundle | `dart build cli` | `apps/daemon` |
| Electron `out/*.js` | `npm run build:ts` | `desktop/electron` |

The last four are wrapped by `npm run build` and `npm run dev` in
`desktop/electron`; the ordering matters, because `theme.css` must exist before
Tailwind runs and both must exist before Electron loads `index.html`.

One source file is generated and **is** checked in: the Lucide icons,
`apps/desktop_ui/lib/src/widgets/lucide_icons.dart`. To use another icon,
add its name to `ICONS` in `desktop/electron/scripts/vendor-lucide.mjs` and
run `node scripts/vendor-lucide.mjs` in `desktop/electron`; it reads the
pinned `lucide-static` devDependency and copies the licence notices in.

A pub workspace means **one** `flutter pub get` at the repo root resolves every
package into a single `pubspec.lock`. Running `dart pub get` inside a member
works too and resolves to that same lockfile.

## Packaging

```bash
cd desktop/electron
npm run package          # daemon + release renderer + main, staged, then electron-builder
```

`npm run package` builds for the machine it runs on: the daemon is native, so
each OS and architecture is packaged on its own. `scripts/stage.mjs` gathers
the daemon bundle, the renderer (without source maps), the tray icon and
`THIRD_PARTY_NOTICES.md` into `build/stage/`, and `electron-builder.yml` packs
them next to the app. Output lands in `desktop/electron/dist/`.

Releases are built by `.github/workflows/release-desktop.yml` from a
`desktop-v<version>` tag, one runner per target, and published as a GitHub
prerelease that installed builds update from. macOS builds are signed and
notarized when `MAC_CERTIFICATE_P12_BASE64`, `MAC_CERTIFICATE_PASSWORD`,
`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` and `APPLE_TEAM_ID` are set;
Windows builds are signed with `WIN_CERTIFICATE_P12_BASE64` and
`WIN_CERTIFICATE_PASSWORD`. Without them the builds are unsigned.

Package-manager manifests live in `desktop/packaging/`; see its README.

## Verify

```bash
# Shared packages
cd packages/conduit_protocol && dart analyze --fatal-infos && dart test
cd packages/conduit_theme   && dart analyze --fatal-infos && dart test
cd apps/daemon              && dart analyze --fatal-infos && dart test
cd apps/desktop_ui          && dart analyze --fatal-infos && dart test

# The renderer and the shared packages must survive dart2js
dart run tool/check_package_boundaries.dart
cd packages/conduit_protocol
dart compile js -o build/js_golden_check.js test/js_golden_check.dart
node build/js_golden_check.js

# End to end: launches Electron, spawns the daemon, drives the window
cd desktop/electron && npx playwright test     # prefix with `xvfb-run -a` on headless Linux
```

`.github/workflows/ci.yml` runs all of it, plus the mobile app's
`flutter analyze` and `flutter test`, on every pull request.

## How the pieces fit

```text
apps/daemon        conduitd: loopback JSON-RPC server hosting conduit_core
apps/desktop_ui    Jaspr client-mode renderer (pure DOM, Tailwind v4)
packages/
  conduit_core     the shared core: models, services, providers, host ports
  conduit_markdown markdown preprocessing and the block parsers (web-safe)
  conduit_protocol DTOs + RPC contracts, shared verbatim by both sides
  conduit_theme    tweakcn palettes as plain ARGB ints, plus the CSS generator
desktop/electron   main + preload (TypeScript), build scripts, Playwright tests
```

`conduit_core` deliberately does **not** re-export its models from the top
level: there are 25 of them with names like `Model`, `User` and `Note`, and
funnelling those through one barrel would widen the namespace of every
importer. Import them by path —
`package:conduit_core/models/chat_message.dart` — which also keeps the
mapping from their old `lib/core/models/` location one-to-one.

`conduit_core` may use `dart:io`; `conduit_markdown`, `conduit_protocol` and
`conduit_theme` may not, because the renderer imports them. That is why
`conduit_markdown` does not depend on `conduit_core` even though two of its
would-be members need a model from it.

### Ports

`packages/conduit_core/lib/ports/` is where the core stops and a host begins.
A port exists wherever the Flutter app and the daemon answer a question
differently — where database files live, what "backgrounded" means, how to
reach a keychain. `lib/core/providers/host_ports.dart` declares each one as a
value-less Riverpod provider, `main.dart` binds the Flutter implementations
from `lib/platform/`, and the daemon will bind its own. Reading an unbound
port throws at startup rather than silently degrading.

`tool/check_package_boundaries.dart` also enforces the reverse direction: once
an M1 work package takes a directory off Flutter, that directory is listed in
`_flutterFreeDirectories` and CI fails if the dependency comes back.

The renderer holds no business logic. `tool/check_package_boundaries.dart`
enforces that mechanically: `apps/desktop_ui` cannot import `dio`, `drift`,
`conduit_core`, `dart:io`, or Flutter, and the shared packages cannot reach
anything that breaks `dart compile js`.

## Security model in one paragraph

Electron generates a fresh 32-byte session token every launch and passes it,
with the master key, to `conduitd` **on stdin** — never argv or the
environment, both of which any local process can read. The daemon binds
`127.0.0.1:0` and refuses a WebSocket unless the `Origin` is exactly
`app://conduit` *and* the token matches; HTTP endpoints require the same token
as a bearer header, which Electron injects for renderer requests so `<img src>`
against the daemon works without a credential in markup. The renderer runs with
`contextIsolation`, `sandbox`, and `nodeIntegration: false`, and cannot
navigate away from `app://conduit`. `desktop/electron/tests/launch.spec.ts`
asserts each of these.

## Known workarounds

Three dependencies the obvious approach would use do not work against this
repo's pinned Dart 3.13.1, and the workarounds are load-bearing enough to
write down.

**`jaspr_builder` is not a dependency.** It pins `analyzer ^12.1.0`, while the
mobile app's `riverpod_lint` needs `analyzer >=13`. A pub workspace has one
lockfile and therefore one analyzer, so the two cannot coexist. Client mode
does not need what `jaspr_builder` generates — `@client` hydration stubs and
`jaspr_options.dart` are server/SSR concerns — and the `jaspr` CLI is installed
globally (`dart pub global activate jaspr_cli`), so its own analyzer pin never
reaches this lockfile. Revisit when `jaspr_builder` supports analyzer 13.

**`jaspr_tailwind` is not a dependency.** It depends on `build_modules`, which
caps at Dart `<3.13.0-z`. Its only job is to run the standalone Tailwind CLI as
a build step, so `scripts/build-ui.mjs` runs that same pinned CLI directly.
Same output, one less pre-1.0 package.

**`jaspr serve` hot reload is not wired up.** It is a consequence of the first
item. `npm run dev -- --watch` re-runs the renderer build on change instead,
which costs a few seconds rather than being instant.

One more, which is about the ARB catalog rather than a version pin:
**slang cannot read `lib/l10n/*.arb` directly.** Its ARB importer only
recognizes an ICU plural when the plural is the entire value, its model allows
one plural parameter per key (Polish `hermesSchedulesSummary` has two), and it
needs one shape per key across all locales where the catalog has several.
`tool/arb_to_slang.dart` normalizes all three into slang's own format without
touching `lib/l10n`, which stays the single source of truth for both apps.
