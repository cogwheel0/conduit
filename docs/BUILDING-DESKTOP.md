# Building Conduit Desktop

> **The daemon is a bundle, not a single executable.** `dart compile exe`
> refuses to run once any dependency has build hooks, and `drift` brings
> `sqlite3`, which has them. `dart build cli` produces
> `apps/daemon/build/cli/<os>_<arch>/bundle/` containing `bin/conduitd` and a
> sibling `lib/libsqlite3.so`. The binary cannot be lifted out on its own, so
> packaging ships the directory.

The desktop client is an Electron shell around two Dart programs: `conduitd`,
a native sidecar that will host the shared core, and a Jaspr renderer that
talks to it over a loopback JSON-RPC WebSocket. See
[docs/desktop/PLAN.md](desktop/PLAN.md) for the architecture and the milestone
plan; this file is how to build and run it.

> Status: M0 (foundations). The shell launches, supervises the daemon, and
> completes a protocol handshake. There is no chat UI yet — that is M3.

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

Enough to use, not yet enough to switch to. The window opens on server setup
the first time; point it at an Open WebUI instance, sign in, and you get a
conversation sidebar, a transcript and a composer that streams replies.

| Works | Notes |
| --- | --- |
| Server setup, custom headers, self-signed TLS, mutual TLS | The PEM pickers validate the armour before accepting a file. |
| Password, LDAP and API-key sign-in | |
| SSO, OAuth and reverse-proxy sign-in | Opens a real browser window; the daemon validates before committing. |
| Several servers, switching between them | Switching restores the session rather than asking again. |
| Conversation list, opening a chat, sending, streaming, stopping | |
| Model picker | The choice is stored with the account, so it survives a restart. |
| Markdown replies | Headings, lists, tables, code, links. No images or embeds yet. |
| Settings: appearance, palette, language, connections, sign-out | Thirteen languages, five palettes, light/dark/system. |

| Not yet | Where it lands |
| --- | --- |
| Syntax highlighting, KaTeX, Mermaid, embeds | WP-3.5 -- markdown renders, these do not |
| Attachments, folders, search UI, rename/pin/delete | WP-3.1 to WP-3.3 |
| Notes, channels, workspace, Hermes, terminal, voice | M5 to M8 |

Run `npm test` in `desktop/electron` to check the shell still launches and
talks to the daemon; it is the only test that exercises the whole chain.

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

A pub workspace means **one** `flutter pub get` at the repo root resolves every
package into a single `pubspec.lock`. Running `dart pub get` inside a member
works too and resolves to that same lockfile.

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
apps/daemon        conduitd: loopback JSON-RPC server, will host conduit_core
apps/desktop_ui    Jaspr client-mode renderer (pure DOM, Tailwind v4)
packages/
  conduit_core     host ports + the 25 shared models (M1, extraction ongoing)
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

## Known deviations from PLAN.md

Three of the plan's assumed dependencies do not work against this repo's
pinned Dart 3.13.1, and the workarounds are load-bearing enough to write down.

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
