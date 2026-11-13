# Building Conduit Desktop (macOS)

Conduit Desktop is the native macOS app in `desktop/`: Rust on GPUI Kit,
over the Dart daemon `conduitd` (`apps/daemon`). This page covers building
and running it, its tests (unit, end to end, performance), the release
bundle, signing, notarizing and the DMG. Releasing (the workflow, its
secrets, the Sparkle key and the signed appcast, rehearsals and update
tests) is in [RELEASING-DESKTOP.md](RELEASING-DESKTOP.md).
[`desktop/README.md`](../desktop/README.md) describes the crates, the theme
export and the design gallery.

Release builds are **Apple Silicon only** and need **macOS 14 Sonoma** or
later. They are Developer ID–signed, notarized DMGs on GitHub Releases, and
they update themselves with Sparkle 2 from one stable channel (there are no
beta releases).

## What ships

```
Conduit.app/Contents/
├── Info.plist                  packaging/macos/Info.plist, filled in by bundle.sh
├── MacOS/Conduit               the Rust app (conduit-desktop), arm64
├── Frameworks/
│   ├── Sparkle.framework       Sparkle 2, thinned to arm64 (release bundles)
│   └── libconduit_widget.dylib the widget's WidgetCenter calls (Swift)
├── PlugIns/
│   ├── ConduitWidget.appex     the desktop widget (WidgetKit, Swift)
│   └── ConduitShare.appex      the Share extension (packaging/macos/share), sandboxed
└── Resources/
    ├── <lang>.lproj/ServicesMenu.strings   the Services items' titles, 14 languages
    ├── AppIcon.icns            packaging/macos/AppIcon.icns (macOS 14/15)
    ├── Assets.car              packaging/macos/Assets.car (the icon on macOS 26+)
    ├── <lang>.lproj/InfoPlist.strings      the privacy prompts, 14 languages
    ├── THIRD_PARTY_NOTICES.md  generated for this bundle (packaging/notices)
    ├── Metadata.appintents/    the App Intents' metadata (packaging/macos/intents.sh)
    ├── <locale>.lproj/         their strings: Localizable.strings, AppShortcuts.strings
    └── conduitd/
        ├── bin/conduitd        `dart build cli` of apps/daemon (Dart AOT)
        └── lib/
            ├── libsqlite3.dylib         from the sqlite3 package's build hook
            └── libconduit_whisper.dylib whisper.cpp (apps/daemon/native/whisper)
```

The app finds `Resources/conduitd/bin/conduitd` next to its own executable
and runs in the production flavour: data in
`~/Library/Application Support/Conduit`, logs in `~/Library/Logs/Conduit`,
and the master key in the Keychain item `app.cogwheel.conduit.desktop`.

## Requirements

| | |
| --- | --- |
| Mac | Apple Silicon (the scripts build `aarch64-apple-darwin` only) |
| Xcode | 26 or later (the macOS 26 SDK), with the Metal toolchain (`xcrun metal --version`; else `xcodebuild -downloadComponent MetalToolchain`); its `swiftc` and macOS SDK build the widget |
| Rust | rustup; `desktop/rust-toolchain.toml` pins 1.99.1 |
| Flutter / Dart | as in [BUILDING.md](BUILDING.md); `dart build cli` builds conduitd |
| CMake | 3.16 or newer, for the whisper library (`CMAKE=/path/to/cmake` if it is not on `PATH`; `WHISPER_SOURCE_DIR` builds from a whisper.cpp checkout instead of fetching the pinned tag) |
| Python 3 | the notices generator, the native strings and the appcast summary |
| cargo-about 0.9 | for the bundle's third-party notices: `cargo install cargo-about --locked --features cli --version 0.9.3` |
| llvm-tools (optional) | `rustup component add llvm-tools`: `bundle.sh` strips with its `rust-objcopy`, and with Apple's `strip` without it ([RELEASING-DESKTOP.md](RELEASING-DESKTOP.md#stripping-and-dsyms)) |

The repository needs its `third_party/` submodules, `flutter pub get` and
Dart codegen (`bundle.sh` runs `build_runner` when the core's generated
files are missing).

## Develop

All commands run from `desktop/` unless they start with `tool/` or name
another folder.

### Run the dev app

```sh
(cd ../apps/daemon && dart build cli)        # conduitd, again after core, daemon or protocol changes
crates/app/run.sh                            # build and run through a .app wrapper
crates/app/run.sh --shots /tmp/shots         # the smoke pass: screenshots, then quit
crates/app/run.sh --build-only               # build the .app, don't run it
```

`run.sh` builds a debug app with its test harness (below) into
`target/app/Conduit Dev.app` and launches it with `open`, so macOS lets it
become the active app. The dev app runs `apps/daemon/build/cli/macos_arm64/bundle/bin/conduitd`
(`CONDUITD_PATH` names another) and keeps its data apart from an installed
Conduit: `~/Library/Application Support/Conduit Dev`, logs in
`~/Library/Logs/Conduit Dev`, and the Keychain service
`app.cogwheel.conduit.desktop.dev`, reached through `/usr/bin/security` so a
rebuilt binary never meets a Keychain prompt. `CONDUIT_USER_DATA`,
`CONDUIT_LOGS` and `CONDUIT_FLAVOR` override the paths and the flavour; use
throwaway folders for test runs.

Dev bundles are signed ad hoc. That is enough for everything except what
macOS ties to a signing team: Shortcuts lists an ad-hoc app's actions but
does not run them, and macOS lists the widget only when provisioning
profiles vouch for it ([Signing and App Intents](#signing-and-app-intents),
[The desktop widget](#the-desktop-widget)). Signing dev bundles with your
own development identity is opt-in: set `CONDUIT_SIGN_IDENTITY`, as for a
bundle ([Apple Development test builds](#apple-development-test-builds)).
`CONDUIT_DEV_WIDGET=1` embeds the widget in the dev bundle.

### The test harness (`harness` feature)

The E2E passes (`--e2e`), the design capture (`--capture`), `--probe` and
the runs over canned data (`--fixture`, `--chat-fixture` and the other
`--*-fixture` flags) are compiled only with the `conduit-desktop` crate's
`harness` cargo feature:

- `crates/app/run.sh`, `perf.sh`, `e2e-offline.sh`, `e2e-dictation.sh` and
  `hc-capture.sh` build with it;
- `cargo test` and `cargo clippy --all-targets` build with it (the crate's
  dev-dependency on itself turns it on);
- release bundles (`packaging/macos/bundle.sh`) build without it. A build
  without it refuses those flags (exit status 64), and `bundle.sh verify`
  runs `packaging/macos/harness_check.sh`, which checks the binary's symbols
  and strings for the harness and that each flag is refused. The one
  exception is a test bundle built with `bundle.sh --test-harness` for an
  update test: a harness build, never for distribution, which `verify`
  checks the other way round.

For a plain cargo build with the harness:
`cargo build -p conduit-desktop --features harness`.

### Checks

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo clippy -p conduit-desktop --lib --bins --locked -- -D warnings   # without the harness, as released
cargo test --workspace --locked
```

Some tests open real windows (the AccessKit walks of the gallery, the chat
view and the shell windows, and the web views' media policy); set
`CONDUIT_SKIP_UI_TESTS=1` on a machine without a logged-in session. On the
Dart side, `conduitd` and the protocol have their own suites (`dart test` in
`apps/daemon` and `packages/conduit_protocol`), and
`dart run tool/generate_rust.dart --check` in `packages/conduit_protocol`
fails when `desktop/crates/protocol/src/generated.rs` is stale.
`dart run tool/check_changed.dart`, from the repository root, runs the fast
ones of these for what a branch changed (`cargo fmt`, `cargo check`, the
codegen check, and the Dart analyzers and tests). CI runs the Rust checks,
the codegen check, the notices check and the release bundle
(`.github/workflows/desktop.yml`); it does not run the E2E passes.

### Local test servers

The daemon's live tests, the signed-in run of `apps/daemon/tool/smoke.dart`
and the app's `--e2e` passes run against throwaway servers on this Mac,
never a real one. Each has its own README:

| Tool | What it starts |
| --- | --- |
| [`tool/local_owui`](../tool/local_owui/README.md) | Open WebUI 0.13.2 in a venv, seeded with invented users, folders, chats, notes, channels, a knowledge base and files; a fake model (streaming, tools, images, speech, transcription), a fake Hermes API server, a fake Open Terminal, a sign-in proxy, a two-step sign-in account and a synthetic "other site" for remote pictures |
| [`tool/local_librechat`](../tool/local_librechat/README.md) | a fake LibreChat server for the LibreChat passes and tests |
| [`tool/local_hermes_live`](../tool/local_hermes_live/README.md) | a fake live-voice vendor and a loopback TURN relay, for a Hermes voice call |

```sh
tool/local_owui/owui.sh setup     # once: a venv with open-webui 0.13.2
tool/local_owui/owui.sh up        # start it with its fakes, seed it
(cd apps/daemon && dart test test/live_server_test.dart)
(cd desktop && crates/app/run.sh --shots /tmp/shots --e2e chat)
tool/local_owui/owui.sh reset     # a fresh seed
tool/local_owui/owui.sh stop
```

`owui.sh` writes the seed's credentials to an env file
(`~/Library/Caches/conduit-dev/local-owui/local-owui.env`, or
`CONDUIT_OWUI_ENV`) that the tests and the app read; `--e2e-env <file>`
names another. Without that file the live tests skip, as in CI. Ports and
folders are set with `CONDUIT_OWUI_PORT`, `CONDUIT_OWUI_DIR` and the
variables in its README, so several checkouts can each run their own.

The Hermes passes (`hermes-sessions`, `hermes-rooms`, `hermes-cards`,
`hermes-admin`, `hermes-extras`, `voice-call-hermes`) also need a real
local Hermes gateway: `hermes serve` from the `hermes-src` submodule with a
scripted model and synthetic chats, whose URL and token go into the env
file (`HERMES_GATEWAY_URL`, `HERMES_GATEWAY_TOKEN`; the pass's module doc
in `crates/app/src/e2e/` lists what it reads).

### End-to-end passes

`--e2e <scenario>` drives the app over the real daemon, in-process, through
the same view methods the controls call, with screenshots in light and dark
and AccessKit checks of each screen. `crates/app/src/e2e.rs` describes
every scenario; each lives in `crates/app/src/e2e/`.

```sh
CONDUIT_USER_DATA=/tmp/p-1 CONDUIT_LOGS=/tmp/l-1 \
  crates/app/run.sh --shots /tmp/shots --e2e sidebar
```

| Area | Scenarios |
| --- | --- |
| Sign-in and accounts | `owui`, `sso`, `sign-in-two-step`, `sign-in-proxy`, `onboarding-apple` |
| Sidebar and navigation | `sidebar`, `sections`, `integration` |
| Chat | `chat`, `chat-smoke`, `chat-read-only`, `composer`, `chat-settings`, `actions`, `rendering`, `rendering-media` |
| Voice | `dictation` and `dictation-recovered` (`e2e-dictation.sh`), `read-aloud`, `voice-call` |
| Direct, Apple and LibreChat | `direct`, `direct-advanced`, `chat-direct`, `apple`, `apple-only`, `librechat` |
| Hermes | `hermes`, `hermes-sessions`, `hermes-rooms`, `hermes-cards`, `hermes-admin`, `hermes-extras`, `voice-call-hermes` |
| Apps | `notes`, `channels`, `workspace`, `calendar`, `tasks`, `terminal`, `apps-leftovers` |
| Settings | `settings`, `notifications`, `integrations` |
| The Mac | `shell`, `shell-notify`, `shell-close`, `share`, `share-system`, `widget`, `intents`, `mac-extras-2` |
| Accessibility | `a11y-sweep` |
| Offline | `offline-setup` and `offline` (`e2e-offline.sh`) |

- Give each pass a throwaway `CONDUIT_USER_DATA` and `CONDUIT_LOGS`, and
  reset the server (`owui.sh reset`) before each one when running several:
  passes change the seed, and `rendering` restarts the server.
- Run one GUI pass at a time: another Conduit window takes the activation
  and greys the screenshots' chrome.
- A scripted run never asks macOS for a permission (microphone, speech,
  notifications, location): it uses stand-ins (a WAV for the microphone, a
  fixed position for `{{USER_LOCATION}}`) or skips what needs the real
  thing. If a system prompt still appears, stop and find which pass raised
  it.
- `a11y-sweep` expects `CONDUIT_FULL_KEYBOARD_ACCESS=1` (Full Keyboard
  Access simulated in the app; the system setting is never changed), as the
  design capture does. `CONDUIT_REDUCE_MOTION` likewise overrides Reduce
  Motion for the app alone.
- A pass prints `SMOKE e2e ok …` or `SMOKE FAILED …` lines and ends with
  `SMOKE e2e <scenario> passed|FAILED`.

### Performance

Long lists and streams must keep up with the display: frame-interval p95
within one 60 Hz refresh (16.7 ms). Release builds, run through a bundle
with the display awake (`pmset -g assertions`):

```sh
crates/app/perf.sh          # 10,000 messages, a 32K-character answer streamed at 60 Hz
crates/app/perf.sh a11y     # the chat view's AccessKit report (tests/chat_a11y.rs)
```

The other lists have fixtures, flags of the app's binary run inside a
bundle as `perf.sh` does: `--fixture perf` (the sidebar) and `--fixture
notes-perf`, `--chat-fixture diagrams`, `--channel-fixture perf`,
`--rooms-fixture`, `--terminal-fixture`, `--workspace-fixture perf`,
`--calendar-fixture perf` and `--tasks-fixture perf` (each module's doc,
`crates/app/src/*fixture.rs`, says what it measures). Each prints `FIXTURE … p50/p95/p99` lines; compare
builds at a low system load, since the interval p95 jumps past 16.7 ms as
soon as other work competes for the CPU.

### Design capture

`crates/app/hc-capture.sh` captures every screen and state in light and
dark, hover, pressed and focus states, open menus, and frame strips of the
transitions, against a fresh local Open WebUI, into
`~/Library/Caches/conduit-dev/capture/captures/` (`CONDUIT_HC_DIR` moves it;
`--out DIR` for one run). It builds a release app with the harness and runs
it on a throwaway profile; `--only` limits it to some phases. Its helpers
(`crates/app/hc/`) compose the strips and contact sheets and list the
app's English strings by surface.

## Build the release bundle locally

```sh
desktop/packaging/macos/bundle.sh                    # = all, version 0.0.0, ad-hoc
desktop/packaging/macos/bundle.sh all --version 1.2.0
desktop/packaging/macos/smoke.sh desktop/target/macos/Conduit-1.2.0/Conduit.app --launch
```

Output goes to `desktop/target/macos/Conduit-<version>/` (`Conduit.app`,
`Conduit-<version>.dmg`, the dSYMs and `Conduit-<version>-dSYMs.zip`, the
entitlements used, the verification report).
A second run moves the previous folder aside; the scripts never delete.

`bundle.sh` runs these steps, each also available on its own (the release
workflow calls them one by one so secrets reach only the steps that need
them):

| Command | Does |
| --- | --- |
| `build` | `cargo build --release --target aarch64-apple-darwin` (with `MACOSX_DEPLOYMENT_TARGET=14.0`, line tables for the dSYMs, without the test harness), `dart build cli` for conduitd, CMake for libconduit_whisper, the widget and the Share extension, then assembles the `.app` with its privacy prompts, App Intents metadata and third-party notices, and strips the binaries it built, keeping their dSYMs |
| `sign` | signs inside out with the hardened runtime (below) |
| `notarize-app` | zips the app, `xcrun notarytool submit --wait`, `xcrun stapler staple` |
| `dmg` | `hdiutil` image holding `Conduit.app` and an `Applications` link; signed when there is an identity |
| `notarize-dmg` | notarizes and staples the DMG |
| `verify` | `plutil -lint`; minimum OS, URL scheme, document types and icon in Info.plist; the privacy prompts in every language; the App Intents; the notices; no test harness in the binary (`harness_check.sh`); every Mach-O arm64-only (`lipo`) and no newer than macOS 14 (`vtool`), and the binaries built here exactly 14.0, stripped, each with a matching dSYM; conduitd links nothing outside the system and the bundle; `codesign --verify --deep --strict`; `spctl -a -vv`; `SURequireSignedFeed`; sizes |

Options: `--version`, `--out DIR`, `--release` (CI: a missing identity,
notarization credentials, Sparkle key or icon fails instead of warning),
`--rehearsal` (the release's strictness on a test bundle id; see
[RELEASING-DESKTOP.md](RELEASING-DESKTOP.md#rehearsals)),
`--skip-rust/--skip-daemon/--skip-whisper` to reuse earlier builds
(`--skip-whisper` refuses a library built for a newer macOS than the
bundle's).
`--bundle-id` and `--test-env` exist only for local tests and rehearsals
and are refused with `--release`. `--test-harness` builds a test bundle
*with* the test harness, for tests that drive a bundle through `--probe`
(an update test): every step says "harness build, not for distribution",
`verify` checks the harness is in, and `--release` and Developer ID
identities refuse it.

Without `CONDUIT_SIGN_IDENTITY` the bundle is signed ad hoc: it runs on the
Mac that built it, and Gatekeeper (`spctl`) rejects it anywhere else.

## Privacy prompts

The app asks macOS for the microphone (dictation and voice calls), speech
recognition (dictation On This Mac, which runs on the Mac only), the local
network (servers you add there) and location (only for a prompt that names
`{{USER_LOCATION}}` while the account's location setting is on). The
usage strings are `desktopUsage*` keys in `lib/l10n/desktop`;
`packaging/macos/native_strings.py infoplist` writes them into Info.plist
and each language's `InfoPlist.strings` (`bundle.sh` and `run.sh` both run
it), and `bundle.sh verify` checks every language has them. A usage key
with no catalog entry fails the build.

Other platform features need no prompt of their own: Continuity Camera in
the composer's + menu (Take Photo, Scan Documents and Add Sketch from a
nearby iPhone or iPad; AppKit adds the items), notifications (asked once,
like any app), and the terminal, an `alacritty_terminal` emulator
(Apache-2.0) over a socket to the terminal server.

## Inline diagrams and the Preview window

Mermaid diagrams and Chart.js charts in answers are drawn to pictures by
one hidden web view per window, and the Preview window shows them live;
neither has network access. Both use the same scripts: the repository's
`assets/chartjs.min.js` (the mobile app's copy) and
`desktop/crates/app/assets/preview/mermaid.min.js`, mermaid 12.2.0, pinned
by its SHA-256 in that folder's README (a unit test fails if the file and
the pin disagree). It is committed so that every checkout builds offline;
the `third_party/mermaid` submodule is a Dart port with no JavaScript.

## Apple's on-device model

Apple's Foundation Models (macOS 26 and later) are a Direct backend, as on
the iPhone. The chat runs in conduitd (the core's Direct engine and its
Apple adapter); the model is a Swift API, so it runs in the app:
`desktop/crates/app/apple/ConduitAppleModels.swift` is compiled by
`packaging/macos/apple_models.sh` (from `crates/app/build.rs`) into a static
library the app links, with FoundationModels linked weakly so the app still
runs on macOS 14 and 15. The daemon asks for status and runs with the
`apple.command` event; the window answers and streams with `apple.report`.

Both Xcode 26 and Xcode 27 build it. macOS 27's parts (token usage on
replies, macOS 27's error types) need the macOS 27 SDK, so they are compiled
only when the active Xcode has it (`#if canImport(FoundationModels,
_version: 2.0)`, besides the `#available(macOS 27.0, *)` check at run
time). With Xcode 26 the build says what it leaves out as cargo warnings
(`packaging/macos/apple_models.sh sdk-gaps` lists them).

Only Apple On-Device is offered. Private Cloud Compute needs the
`com.apple.developer.private-cloud-compute` entitlement, and without it
FoundationModels stops the app with a fatal error on the first request, so
the Mac build never compiles it in and the daemon never offers it.

`CONDUIT_APPLE_ENGINE=fake` (debug builds only) puts a scripted model in
Apple's place; `--e2e apple` reads the Mac's real status first, then uses
it.

## Local speech recognition (Whisper)

conduitd transcribes on the Mac with whisper.cpp when Settings › Audio
chooses a local Whisper model: `apps/daemon/native/whisper` builds
`libconduit_whisper.dylib` (CMake, the whisper.cpp tag pinned in its
`CMakeLists.txt`), which the bundle carries in `Resources/conduitd/lib`.
The model itself is not bundled: it is downloaded once, when the user
asks for it, from Hugging Face (`ggerganov/whisper.cpp`). Dev runs find the
library through `CONDUIT_WHISPER_LIB`.

## Versions and build numbers

A release is a tag `desktop-v<version>`, where the version is `X.Y.Z`
(stable releases only: a `-beta.N` tag is refused).
`CFBundleShortVersionString` is the version as written; `CFBundleVersion`
(what Sparkle compares) is one integer:

```
X*1000000 + Y*10000 + Z*100 + 99        1.2.0 → 1020099   1.2.1 → 1020199
```

so Y and Z stay below 100. A `-beta.N` version still builds locally, with N
in place of 99 (it sorts before its release), but never ships. The app
shows both in Settings › About (`CONDUIT_VERSION` and `CONDUIT_BUILD` are
compiled in by `bundle.sh`).

## Signing

`CONDUIT_SIGN_IDENTITY` is the codesign identity: a "Developer ID
Application: …" name or its SHA-1 (`security find-identity -v -p codesigning`).
The order, all with `--options runtime` and a secure timestamp:

1. `Resources/conduitd/lib/*.dylib`
2. `Resources/conduitd/bin/conduitd` with `conduitd.entitlements`, identifier `app.cogwheel.conduit.desktop.conduitd`
3. Sparkle, in Sparkle's documented order: `XPCServices/Installer.xpc`,
   `XPCServices/Downloader.xpc` (keeping its entitlements), `Autoupdate`,
   `Updater.app`, then `Sparkle.framework`
4. `Frameworks/libconduit_widget.dylib`, then `PlugIns/ConduitWidget.appex`
   with `widget/ConduitWidget.entitlements`
5. `PlugIns/ConduitShare.appex` with `Share.entitlements` (filled in for the bundle id)
6. `Conduit.app` with `Conduit.entitlements`

Entitlements (`desktop/packaging/macos/`):

| File | Keys | Why |
| --- | --- | --- |
| `Conduit.entitlements` | `network.client`, `network.server` | the app is a loopback client and server of conduitd and a client of your servers (enforced only under the App Sandbox, which Conduit does not use) |
| `Conduit.entitlements` | `device.audio-input`, `personal-information.location` | the hardened runtime refuses the microphone and CoreLocation without them |
| `conduitd.entitlements` | `cs.allow-unsigned-executable-memory` | the Dart VM maps executable memory at run time; `allow-jit` alone is not enough |
| `widget/ConduitWidget.entitlements` | `app-sandbox` | app extensions run in the App Sandbox |
| both of the app's and the widget's, added when signing | `application-groups`: `WIDGET_APP_GROUP` | the widget reads the app's snapshot from the group's container ([The desktop widget](#the-desktop-widget)) |
| both, with provisioning profiles only | `com.apple.application-identifier`, `com.apple.developer.team-identifier` | what each profile vouches for |
| `share/Share.entitlements` | `app-sandbox`, `temporary-exception.files.home-relative-path.read-write` for `~/Library/Caches/<bundle id>.share-inbox/` | every app extension is sandboxed; the inbox is the one folder it hands shares through (see below) |

Ad-hoc builds add `cs.disable-library-validation` to both, because without a
team ID dyld refuses the bundle's own libraries (libsqlite3, the whisper
library, Sparkle). Team-signed builds (Developer ID, or Apple Development
for local tests) keep library validation: every binary carries the same
team, which `verify` and `smoke.sh` check (`TeamIdentifier` on each Mach-O).

### Apple Development test builds

An Apple Development certificate (any team, from Xcode's Accounts
settings) gives a local test build a team ID, which ad-hoc signing lacks.
That is what lets Shortcuts and Spotlight run the App Intents
([Signing and App Intents](#signing-and-app-intents)), and the app and its
widget use a team-prefixed app group. It is for test bundle ids only:

```sh
security find-identity -v -p codesigning     # pick a valid "Apple Development" row's SHA-1
CONDUIT_SIGN_IDENTITY=<SHA-1> desktop/packaging/macos/bundle.sh build --bundle-id app.cogwheel.conduit.desktop.mytest \
  --test-env CONDUIT_FLAVOR=dev --test-env CONDUIT_USER_DATA=/tmp/conduit-test/data --test-env CONDUIT_LOGS=/tmp/conduit-test/logs
CONDUIT_SIGN_IDENTITY=<SHA-1> desktop/packaging/macos/bundle.sh sign --bundle-id app.cogwheel.conduit.desktop.mytest
CONDUIT_SIGN_IDENTITY=<SHA-1> desktop/crates/app/run.sh      # the dev bundle, Conduit Dev.app
```

- The team comes from the certificate (`TEAM_ID` in `release.env`, when
  set, must agree). The identity is named by its SHA-1; one the keychain
  holds as revoked, expired or not at all is refused, since `find-identity
  -v` still lists revoked certificates.
- `bundle.sh` refuses an Apple Development identity for the release id
  `app.cogwheel.conduit.desktop` and with `--release`, signs without a
  secure timestamp (as Xcode signs Debug builds; nothing is notarized) and
  skips notarization. `verify` notes that Gatekeeper rejects it, as it does
  ad-hoc builds.
- `run.sh` signs the dev bundle through `packaging/macos/sign-dev.sh`: the
  hardened runtime with `Conduit.entitlements`, and with
  `CONDUIT_DEV_WIDGET=1` the widget and its library, in the app group
  `<TEAMID>.app.cogwheel.conduit.desktop.dev`. Without
  `CONDUIT_SIGN_IDENTITY` it signs ad hoc, as before.
- The logs never print a certificate's holder: `verify` shows `Authority`
  lines by kind only (`Apple Development: …`).

App groups and shared folders, by signature:

| What | Ad-hoc | Team-signed (Apple Development, Developer ID) |
| --- | --- | --- |
| Widget snapshot (app writes, widget reads) | group `app.cogwheel.conduit.desktop[.dev]` or the test id, which macOS refuses ad-hoc code (no snapshot reaches the widget) | group `<TEAMID>.app.cogwheel.conduit.desktop` (release), `<TEAMID>.app.cogwheel.conduit.desktop.dev` (dev bundle), `<TEAMID>.<test id>` (test bundles); no provisioning profile needed |
| Share inbox (Share extension writes, app reads) | `~/Library/Caches/<bundle id>.share-inbox/` through a temporary exception | the same (works for every signature; see [The Share menu and the Services menu](#the-share-menu-and-the-services-menu)) |

Nothing else is shared: the App Intents live in the app, and Keychain items
need no access group.

## The Share menu and the Services menu

**Share extension** (`packaging/macos/share/`): "Conduit" in every app's
Share menu takes text, web links and up to ten files, images or movies, and
shows a small sheet with an optional message, Cancel and Open in Conduit.
`share/build.sh` compiles it with `swiftc` (no Xcode project) and fills its
Info.plist; `bundle.sh` embeds and signs it before the app.

The hand-off works with ad-hoc and Developer ID signatures alike. The
sandboxed extension copies what it was given into
`~/Library/Caches/<bundle id>.share-inbox/<uuid>/` (a `manifest.json` and
`files/<n>/<name>`; written as `<uuid>.part`, then renamed), and opens
`conduit://share/<uuid>` **with its own containing app** (never whichever
app owns `conduit://`). The app reads the share once
(`shell/share_inbox.rs`), opens a new chat with the message and text in the
composer and the files attached, nothing sent, and clears taken shares
after ten minutes and abandoned ones after a day. Why not an App Group: since
macOS 15 a group container needs a team ID prefix or a provisioning profile,
or the system asks the user before the app may read it, and an ad-hoc build
has no team ID. A home-relative temporary exception needs neither (the Mac
App Store would refuse it; Conduit is not sold there).

Limits of an ad-hoc build: Gatekeeper refuses it on other Macs, and
PlugInKit only offers the extension once the app is registered with
LaunchServices (a first launch, or `lsregister`) and the extension is turned
on (System Settings › General › Login Items & Extensions › Sharing, or
`pluginkit -e use -i <bundle id>.share`).

**Services** (`NSServices` in `Info.plist`, `shell/services.rs`): "Ask
Conduit" opens Quick Ask with the selected text quoted (a new chat when Quick
Ask is off or not set up), and "New Conduit Chat With Selection" opens a new
chat with it. Their titles are translated by `ServicesMenu.strings`, which
`share/build.sh` writes from the ARB catalogs (`native_strings.py table`).
Dev bundles (`crates/app/run.sh`) leave `NSServices` out, so worktree builds
never appear in the Services menu.

**Tests:**

- `share/test.sh`: the inbox's tests (`share/tests/InboxTests.swift`, which
  checks the manifest against `share/tests/manifest-v1.json`, as the app's
  `share_inbox` tests do) and a type-check of the extension and its preview.
- `share/preview.sh DIR`: the sheet's content in light and dark, drawn off
  screen by the extension's own view controller over synthetic items
  (built with `-D SHARE_PREVIEW`, which the extension never is).
- `crates/app/run.sh --shots DIR --e2e share`: the app's side, against the
  local Open WebUI: a share staged as the extension stages it, its link, the
  new chat, the upload and the send; the Services provider called as macOS
  calls it.
- `share/e2e-system.sh APP --shots DIR`: a bundle built with a **test**
  bundle id (`bundle.sh --bundle-id … --test-env CONDUIT_FLAVOR=dev …`; the
  release id is refused) registered with LaunchServices and PlugInKit; the
  real sheet opened from another app (`share/tests/ShareDriver.swift`) and
  the copy the sandboxed extension stages; that share finished as Open in
  Conduit finishes it and its link delivered to the test app;
  `NSPerformService("Ask Conduit")` once only the test bundle provides it;
  then everything unregistered. It never opens another app's extension.
- By hand: the real sheet's Open in Conduit and Cancel, and its look in
  place. Since macOS 13 the sheet is a remote view in windows ShareKit lays
  over the host; it takes no synthetic keys from the host and cannot be
  captured without Screen Recording permission.

## Notarization

`notarize-app` and `notarize-dmg` use either

- `CONDUIT_NOTARY_PROFILE`: a profile made once with
  `xcrun notarytool store-credentials <name> --key AuthKey_XXXX.p8 --key-id … --issuer …`
  (or with an Apple ID and app-specific password), or
- `CONDUIT_NOTARY_KEY_FILE` + `CONDUIT_NOTARY_KEY_ID` + `CONDUIT_NOTARY_ISSUER`:
  an App Store Connect API key, which is what CI uses.

With neither, or with an ad-hoc signature, both steps are skipped with a
message (`--release` makes that an error). A rejected submission prints
Apple's log. The app is stapled before it goes into the DMG, and the DMG is
stapled too, so both work offline.

## Updates (Sparkle 2)

`bundle.sh` embeds Sparkle (pinned in `release.env`, checksum checked) only
when `SPARKLE_PUBLIC_ED_KEY` is set, with the feed URL, the public key and
`SURequireSignedFeed` in Info.plist. The app loads it at run time
(`crates/app/src/shell/updater.rs`): **Conduit › Check for Updates…** in the
app menu, and **Settings › About** with Check Now and "Check for Updates
Automatically". There is one stable channel, so there is nothing to choose.
Without the framework (dev builds) the menu item is disabled and About says
updates come with the installed app. Sparkle's decisions go to the app log
(`updates: found …`, `none`, `downloaded`, `installing`, `stopped: …`).

The Sparkle key, the signed appcast and where it is hosted, the release
workflow (tags make **draft** releases; publishing a draft makes its feed
live), its secrets, rehearsals and testing an update on one Mac are in
[RELEASING-DESKTOP.md](RELEASING-DESKTOP.md).

## The desktop widget

`PlugIns/ConduitWidget.appex` is a WidgetKit extension (small, medium and
large; desktop and Notification Center): Ask Conduit (Quick Ask), New
Chat, Voice Call, and the newest chats, each a `conduit://` link the app
opens (`quick-ask`, `new`, `call`, `chat/<id>`). Its sources are Swift in
`desktop/packaging/macos/widget/`, built by `widget/build.sh` with `swiftc`
(no Xcode project); `bundle.sh build` runs it.

**Data.** The widget never talks to conduitd. The app writes
`widget-snapshot.json` (ids, titles and times of the six newest chats,
whether anyone is signed in, the app's language; never message text; no
chats when signed out; owner-only) into the app group's container
`~/Library/Group Containers/<WIDGET_APP_GROUP>/`, and asks WidgetKit to
reload through `libconduit_widget.dylib` (`WidgetCenter` is Swift-only,
and it honours only the app that contains the widget). The group is
`WIDGET_APP_GROUP` in `release.env`, `@TEAM_ID@` replaced by the signing
team (`TEAM_ID`, or the identity's certificate); `bundle.sh sign` writes it
into both Info.plists (`ConduitAppGroup`) and both entitlements.

**What it needs from Apple.** Checked on macOS 27.0.1 with throwaway test
bundles (never the release id):

| Signature | The app's group container | macOS lists the widget |
| --- | --- | --- |
| ad-hoc (`-`), any group id | refused (EPERM, no prompt) | no: chronod logs "Ignoring restricted or unknown extension" and drops its descriptors |
| Apple Development certificate, team-prefixed group, no profile | works | no, the same: ExtensionKit's discovery logs "Extension is not entitled to run in the App Sandbox", then chronod "purging instead because we shouldn't cache it" (checked again on macOS 27.0.1 with `run.sh` and `bundle.sh` test bundles; also from `~/Applications`, and with `com.apple.application-identifier` claimed) |
| Apple Development + Mac Development provisioning profiles | expected to work | expected: a profile is what vouches for the sandbox entitlement (steps below) |
| Developer ID + Developer ID provisioning profiles | expected to work | expected (not testable here) |

`pluginkit -m` shows every variant registered; `WidgetCenter` answers the
app in all of them. So a release needs, besides the Developer ID
certificate:

1. In the Apple Developer account (Certificates, IDs & Profiles): App IDs
   `app.cogwheel.conduit.desktop` and `app.cogwheel.conduit.desktop.widget`,
   both with the **App Groups** capability, and the group
   (`<TEAMID>.app.cogwheel.conduit.desktop`, or a registered `group.…` id
   set in `WIDGET_APP_GROUP`).
2. Two **Developer ID** provisioning profiles, one per App ID, from the
   Developer ID certificate.
3. Locally: `CONDUIT_APP_PROFILE=… CONDUIT_WIDGET_PROFILE=… bundle.sh`; in
   CI: the two optional secrets above (base64 of each profile). `bundle.sh`
   embeds them as `embedded.provisionprofile`, checks each one is for
   `<TEAMID>.<bundle id>`, and adds the application and team identifiers to
   the entitlements.

For development, the same with an Apple Development certificate and Mac
Development profiles naming this Mac, which Xcode's automatic signing
makes:

1. In Xcode, make a throwaway macOS App project (it is never built into
   Conduit) with your team and the bundle id
   `app.cogwheel.conduit.desktop.dev`, and add a **Widget Extension**
   target with the id `app.cogwheel.conduit.desktop.dev.widget`.
2. In Signing & Capabilities, for both targets: **Automatically manage
   signing** on, the same team; add **App Groups** and in it
   `<TEAMID>.app.cogwheel.conduit.desktop.dev` (the group `run.sh` uses
   when team-signed; a test bundle from `bundle.sh --bundle-id <id>` uses
   `<TEAMID>.<id>`, with App IDs `<id>` and `<id>.widget`).
3. Build once (⌘B). Xcode registers both App IDs and this Mac with the
   team, and saves a "Mac Team Provisioning Profile" for each id in
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Find them:

   ```sh
   cd ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
   for f in *; do printf '%s %s\n' "$f" "$(security cms -D -i "$f" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - -)"; done
   ```

4. Run the dev bundle with them:

   ```sh
   CONDUIT_SIGN_IDENTITY=<SHA-1> CONDUIT_DEV_WIDGET=1 \
   CONDUIT_APP_PROFILE=<…>.provisionprofile CONDUIT_WIDGET_PROFILE=<…>.provisionprofile \
     desktop/crates/app/run.sh
   ```

   (`bundle.sh sign` takes the same two variables for a test bundle.) Each
   profile must be for `<TEAMID>.<bundle id>`; both are embedded and the
   identifiers they vouch for added to the entitlements.

**Trying it.** `CONDUIT_DEV_WIDGET=1 crates/app/run.sh` embeds the widget
in the dev bundle (ad-hoc, group `app.cogwheel.conduit.desktop.dev`; with
`CONDUIT_SIGN_IDENTITY`, `<TEAMID>.app.cogwheel.conduit.desktop.dev`): the
app loads the library and asks for reloads, but macOS won't list the
widget without the profiles above. `CONDUIT_WIDGET_SNAPSHOT=<file>` sends the snapshot to a file
instead (the `--e2e widget` pass does). `widget/render.sh OUT_DIR` draws
the widget's views to PNGs (light and dark, each family and state) from
`widget/Fixtures/snapshot.json`, which the app's writer test keeps equal to
what the app writes. The widget's words come from the ARBs
(`desktopWidget*`, "Yesterday" and the weekdays): `widget/build.sh` and
`render.sh` generate `WidgetStrings.swift` with `native_strings.py widget`
before compiling.

## Third-party notices

`THIRD_PARTY_NOTICES.md` is generated, not committed: `bundle.sh build`
writes it into each bundle's `Resources` (Settings › About opens it), and
CI's `desktop.yml` runs the generator's check on every pull request.

```sh
desktop/packaging/notices/notices.sh             # desktop/target/notices/THIRD_PARTY_NOTICES.md
desktop/packaging/notices/notices.sh --check     # generate to a temporary folder only
```

It lists the components bundled directly (the vendored and modified
gpui-pre, Sparkle, whisper.cpp, SQLite, the Dart runtime, mermaid, Chart.js,
noVNC, Lucide, the KaTeX fonts), every Rust crate in the `conduit-desktop`
binary (cargo-about, `about.toml`, `about.hbs`) and every Dart package in
conduitd, each grouped by licence text. Every run fails unless the set is
complete: each crate `cargo tree` puts in the app for Apple Silicon is
listed with an accepted licence, each Dart package has a licence file, and
each bundled component's text is found. Licence texts that are not in a
package on disk live in `desktop/packaging/notices/texts/`; see
[`desktop/packaging/notices/README.md`](../desktop/packaging/notices/README.md).

## App icon

The macOS icon is the iOS app icon
(`ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png`,
the white hub-and-spokes mark on blue) placed on Apple's macOS icon grid:
`icon-master.swift` scales it, unchanged, into an 824 x 824 tile with
continuous corners centred on the 1024 px canvas, with a soft drop shadow,
and writes `packaging/macos/AppIcon-master.png`. `icon.sh` then makes both
icon files from the master (sips and iconutil for the PNGs, Xcode's actool
for the catalog; never ImageMagick):

```sh
xcrun swift desktop/packaging/macos/icon-master.swift \
  ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png \
  desktop/packaging/macos/AppIcon-master.png
desktop/packaging/macos/icon.sh desktop/packaging/macos/AppIcon-master.png
```

| File | Info.plist | Shown by |
| --- | --- | --- |
| `Assets.car` (asset-catalog AppIcon) | `CFBundleIconName` | macOS 26 and later. With only an `.icns`, macOS 27 draws the icon shrunk inside a grey squircle at small sizes (checked with `NSWorkspace.icon(forFile:)` at 32 px). |
| `AppIcon.icns` (16 to 512 px at 1x and 2x) | `CFBundleIconFile` | macOS 14 and 15 |

All three files are committed, so builds never render. `bundle.sh` copies
both into `Contents/Resources`, and `verify` checks them (`--release` fails
without them). On macOS 26+ the system adds its own glass edge and lighting
to the tile; the artwork itself is the iOS icon's.

## Shortcuts and App Intents

Conduit's actions in Shortcuts, Spotlight and Siri (Ask Conduit, New Chat,
Open Chat, Start Voice Call, Show Quick Ask, and their App Shortcuts) are
App Intents written in Swift, in `desktop/crates/app/intents/`. They are
built without Xcode:

1. `crates/app/build.rs` runs `packaging/macos/intents.sh compile`: `swiftc`
   (Swift 6, `-parse-as-library`, the deployment target) makes one object
   and the compiler's constant values, and `libtool` a static library that
   the Rust binary links whole. AppKit registers the process with the App
   Intents runtime at launch; nothing in Rust names the intents.
2. `bundle.sh` (and `crates/app/run.sh` for the dev bundle) runs
   `intents.sh bundle`, which recompiles for the constant values and runs
   Apple's `appintentsmetadataprocessor` as Xcode's "Extract App Intents
   Metadata" step does, into `Resources/Metadata.appintents`. Then
   `native_strings.py intents` writes each locale's `Localizable.strings` and
   `AppShortcuts.strings` from `lib/l10n/desktop` (`desktopIntent*` keys).
   A string the intents show with no ARB key fails the bundle, and
   `cargo test` (`intents::tests`) checks the same before any bundle.
3. `verify` and `smoke.sh` run `intents.sh verify` (five actions, the chat
   entity and its query, five App Shortcuts, every locale's strings), and
   `smoke.sh --launch` checks that every type the metadata names is in the
   binary (`SMOKE intents <n> types resolve`).

Each intent's `perform()` hands the app one JSON request over a C function
(`conduit_intents_request`, `src/intents.rs`) and gets one reply. The app
does the work through conduitd: Ask Conduit is `intents.ask` (a new chat,
then the answer, up to two minutes), Open Chat's list is `intents.chats`,
and New Chat and Open Chat take the `conduit://` links' path. The intents
are in the app rather than in an App Intents extension: an extension must
be sandboxed, could only reach conduitd through an app group (which needs
a team ID), and could do nothing while the app is not running, since
conduitd is the app's child.

`--e2e intents` runs the Swift intents' own `perform()` and query in the
app's process against the local Open WebUI; Shortcuts itself can't be
driven from a test (`shortcuts run` only runs shortcuts in the user's
library).

### Signing and App Intents

| Signature | Shortcuts and Spotlight list the actions | The actions run |
| --- | --- | --- |
| Ad-hoc (`-`, local builds) | yes, once Launch Services has launched the bundle (before that, linkd logs "not trusted for binding") | no: linkd refuses the app's runtime registration ("requiresValidatedBundle", "Unable to get teamId") |
| Apple Development (a free or paid team; [test builds](#apple-development-test-builds)), no profile | yes | yes, as far as linkd goes: it accepts the running app ("Accepting [pid]:<bundle id>" on `com.apple.linkd.autoShortcut`, where the ad-hoc build is rejected); a run from Shortcuts itself is checked by hand |
| Developer ID (releases) | yes | yes, as for any notarized app |

No entitlement or provisioning profile is needed for App Intents, and the
metadata (`Metadata.appintents`) names no team: linkd takes the team from
the running app's signature. To see what linkd did with a
bundle: `/usr/bin/log show --last 10m --predicate 'process == "linkd" AND
eventMessage CONTAINS "<bundle id>"'`. Test bundles are registered with
Launch Services when they are launched; take them out afterwards with
`lsregister -u <path to the .app>` (`LSREGISTER` in `lib.sh`).

## Troubleshooting

- **"Launchd job spawn failed" / error 162 on launch**: a binary was
  overwritten in place; `bundle.sh` always assembles a new bundle.
- **Keychain prompts with ad-hoc builds**: an item created by an ad-hoc
  binary belongs to that exact build. Test ad-hoc bundles with
  `CONDUIT_FLAVOR=dev` (the dev Keychain item through `/usr/bin/security`) and
  throwaway `CONDUIT_USER_DATA`/`CONDUIT_LOGS`.
- **dyld refuses `libsqlite3.dylib` or Sparkle**: library validation; ad-hoc
  builds need `disable-library-validation` (bundle.sh adds it), Developer ID
  builds need everything signed with the same team.
- **`sqlite3` hook download fails** in `dart build cli` (HTTP 504 leaves a
  `.tmp` and a hash error): retry, or copy a verified `libsqlite3.dylib`
  into the hook's cache.
- **Sparkle says "An error occurred in retrieving update information"**: the
  feed URL is unreachable or not an appcast yet (the first release creates
  it).
