# Conduit Desktop (GPUI)

The native macOS app for Conduit: Rust on [GPUI Kit](https://gpui-kit.com)
0.9.0 (exact pin; gpui-pre 0.3.11) over the Dart daemon `conduitd`. Rust
1.99.1 is pinned in `rust-toolchain.toml`.

| Crate | What it is |
|---|---|
| `crates/components` (`conduit-components`) | Theme mapping (conduit_theme palettes → GPUI Kit `Theme`), window chrome helpers, and the reusable views. Views take plain view models, never protocol DTOs. |
| `crates/gallery` (`conduit-gallery`) | Design screens on synthetic data, rendered in-process to PNG; the component showcase and the a11y gate. |
| `crates/daemon` (`conduit-daemon`) | No GPUI. Supervises `conduitd` (bootstrap, ready line, restarts, graceful stop, stderr logs), the JSON-RPC client (handshake, ping, reconnect + re-subscribe, `daemonUnavailable` retry), `/upload` and `/files`, and the Keychain master key. |
| `crates/app` (`conduit-desktop`) | The app: bootstrap, main window and routing gate, Settings, native menus and the rebindable keymap, l10n generated from the ARBs, the connection and settings stores, and the macOS shell extras (`conduit://` links, Open with, answer notifications, Quick Ask, the menu-bar item, open at login). |

## Theme

`crates/components/assets/themes/palettes.json` is generated from the Dart
registry and committed:

```sh
dart run packages/conduit_theme/bin/export_theme_json.dart   # from the repo root
```

`packages/conduit_theme/test/theme_json_test.dart` fails while it is stale.

## Gallery

```sh
cargo run -p conduit-gallery -- --list
cargo run -p conduit-gallery -- --screen main-streaming --mode dark \
    --palette catppuccin --variant sidebar=surface,accent=system --out /tmp/shot.png
crates/gallery/render.sh --all /tmp/conduit-gallery
```

`render.sh` launches the gallery through a throwaway `.app` bundle with
`open`, so macOS lets it become the active app and windows draw key-window
chrome. A bare binary started from a background shell is refused activation
and renders inactive traffic lights.

Design variants (`--variant key=value,...`; baseline first):
`sidebar=material|surface`, `accent=mono|system`, `user=plain|bubble`,
`density=compact|comfortable`, `toolbar=model|title`.

## App

The dev app runs the daemon from `apps/daemon/build/cli/macos_arm64/bundle`
(`dart build cli` in `apps/daemon`) and keeps its data apart from a packaged
build: `~/Library/Application Support/Conduit Dev`, logs in
`~/Library/Logs/Conduit Dev`, and the Keychain service
`app.cogwheel.conduit.desktop.dev`, which dev builds reach through
`/usr/bin/security` so a rebuilt binary never meets a Keychain prompt.

```sh
crates/app/run.sh                                   # run through a .app wrapper
crates/app/run.sh --shots /tmp/shots --preview-route main     # smoke pass + screenshots
CONDUITD_PATH=/nonexistent crates/app/run.sh --shots /tmp/shots --expect-failure
```

The smoke pass waits for the connection (or, with `--expect-failure`, a
failed state; `--smoke-reset` then presses "Reset local data"), captures the
windows in light and dark over a synthetic backdrop, prints `SMOKE` lines and
quits, which stops the daemon. `CONDUIT_USER_DATA`, `CONDUIT_LOGS` and
`CONDUIT_FLAVOR` override the paths and flavour.

### Live passes (E2E)

`--e2e <scenario>` drives the app over the real daemon against a throwaway
local Open WebUI 0.13.2 with a fake model, a fake Hermes server and invented
accounts and chats ([`tool/local_owui`](../tool/local_owui/README.md)). It
never talks to a real server; CI does not run it. The passes, `--capture`,
`--probe` and the fixtures are compiled only with the `harness` cargo
feature, which `run.sh`, `perf.sh`, the E2E scripts and `cargo test`
turn on and release bundles leave off. Every scenario, and how to run them
one after another, is in
[docs/BUILDING-DESKTOP.md](../docs/BUILDING-DESKTOP.md#end-to-end-passes);
the first ones:

```sh
../tool/local_owui/owui.sh setup     # once: a venv with open-webui
../tool/local_owui/owui.sh up        # start and seed; writes the env file
CONDUIT_USER_DATA=/tmp/p-1 CONDUIT_LOGS=/tmp/l-1 \
  crates/app/run.sh --shots /tmp/shots --e2e sidebar
../tool/local_owui/owui.sh reset     # fresh seed after a pass that changed it
../tool/local_owui/owui.sh stop
```

The app reads the env file `owui.sh seed` wrote
(`~/Library/Caches/conduit-dev/local-owui/local-owui.env`, or
`CONDUIT_OWUI_ENV`); `--e2e-env <file>` names another. Use a throwaway
`CONDUIT_USER_DATA` and `CONDUIT_LOGS` for each pass: `owui`, `sso`,
`direct`, `hermes` and `chat-direct` start from a cleared profile.

| Scenario | What it covers |
|---|---|
| `owui` | onboarding, a wrong password, sign-in, Settings, Add account, the approval cards, sign out |
| `sso` | single sign-on in the web view window, finished with `auth.completeExternal` |
| `direct`, `hermes` | Direct against the fake model; Hermes against the fake Hermes server |
| `sidebar` | the seeded folders and chats: rename, pin, move, archive, delete, search, ⌘K |
| `chat`, `chat-direct`, `chat-smoke`, `chat-read-only` | the chat view (below) |
| `integration` | the sidebar and the chat view together |
| `shell`, `shell-notify`, `shell-close` | the macOS shell extras (below) |
| `offline-setup`, `offline` | the server out of reach at launch and conduitd killed while the window opens, then the server back (below) |

`sidebar` edits the seeded chats it then expects as seeded, so run
`owui.sh reset` before running it again.

`offline` needs two launches and a server that stops between them, so a
script runs both passes:

```sh
CONDUIT_USER_DATA=/tmp/p-1 CONDUIT_LOGS=/tmp/l-1 \
  crates/app/e2e-offline.sh --shots /tmp/shots
```

It signs in (`offline-setup`) and quits, makes a chat on the server
(`owui.sh chat`) and stops the server. Then it launches again (`offline`):
conduitd is restarted once while the window opens, the main frame must open
from what the daemon stored, with the offline banner, and once the pass
starts the server again the banner must go and the new chat must appear.

### Chat

The chat view has three harnesses: the live passes above (`chat`:
reasoning, code, math, a long and a stopped answer, versions, edits, an
attachment, a prompt form and a tool approval; `chat-direct`: Direct mode;
`chat-smoke`: the model chosen per message, and the account left as it
was; `chat-read-only`: a chat in another user's shared folder), and:

```sh
crates/app/perf.sh          # 10,000 messages, a 32K answer at 60 Hz (release)
crates/app/perf.sh a11y     # the AccessKit report tests/chat_a11y.rs checks
```

`perf.sh` prints the frame-interval percentiles while following the tail and
while scrolling through history; keep the display awake.

### Shell extras

`packaging/macos/Info.plist` is the one Info.plist for every bundle
(`run.sh` fills in the dev values): the `conduit://` scheme and the Open
with document types (`LSHandlerRank` Alternate).

```sh
# Live, on the local Open WebUI (as `chat`): links, Open with, Settings ›
# Desktop, Quick Ask, notifications, close to the menu bar, open at login
# (registered, then unregistered).
CONDUIT_USER_DATA=/tmp/p-1 CONDUIT_LOGS=/tmp/l-1 CONDUIT_SHOT_WINDOW=1 \
  crates/app/run.sh --shots /tmp/shots --e2e shell
#   shell-notify, shell-close: one part

# Real launches: `--probe <file>` writes the app's state; `open -a` the dev
# .app with a link or a file (cold, then warm). Never make the dev app the
# system's default conduit:// handler.
open -a "target/app/Conduit Dev.app" 'conduit://chat/<id>' --args --probe /tmp/state.json

target/debug/conduit-desktop --fixture shell    # Settings › Desktop and Quick Ask, AccessKit
```

`CONDUIT_SHOT_WINDOW=1` captures each window alone, for when a system alert
sits above it. Notifications need an app bundle; a bundle the system has
never asked can be checked under quiet (provisional) permission, which
needs no prompt.

## Release bundle

`packaging/macos/bundle.sh` builds the signed, notarized `Conduit.app` and
DMG (Apple Silicon, macOS 14+), with Sparkle 2 for updates; `smoke.sh`
checks a bundle; `appcast.sh` and `publish-appcast.sh` maintain the update
feed; `.github/workflows/release-desktop.yml` runs it all on `desktop-v*`
tags and leaves a draft release to publish. Building and signing are in
[docs/BUILDING-DESKTOP.md](../docs/BUILDING-DESKTOP.md); releasing (secrets,
notarization, the Sparkle key, rehearsals, dSYMs) is in
[docs/RELEASING-DESKTOP.md](../docs/RELEASING-DESKTOP.md).

```sh
packaging/macos/bundle.sh all --version 1.2.0          # ad-hoc without CONDUIT_SIGN_IDENTITY
packaging/macos/smoke.sh target/macos/Conduit-1.2.0/Conduit.app --launch
packaging/notices/notices.sh --check                   # the notices bundle.sh generates
```

## Patched dependencies

`vendor/gpui-pre` is gpui-pre 0.3.11 with three small patches (a file
dropped right after typing switches GPUI to pointer input, so `on_drop`
fires; AccessKit's debug tree carries each node's bounds; a newly focused
element scrolls into view), used through `[patch.crates-io]`.
`vendor/gpui-pre/PATCHES.md` describes each and how to update it.

## Checks

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo clippy -p conduit-desktop --lib --bins -- -D warnings   # without the harness, as released
cargo test --workspace   # includes the AccessKit walks of the gallery and the chat view
```

The a11y tests open real windows; set `CONDUIT_SKIP_UI_TESTS=1` on a machine
without a logged-in session.
