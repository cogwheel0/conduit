# Building Conduit

Everything needed to build, run, and verify Conduit from source. If you only
want to *use* the app, install it from the
[App Store](https://apps.apple.com/us/app/conduit-open-webui-client/id6749840287)
or [Google Play](https://play.google.com/store/apps/details?id=app.cogwheel.conduit)
instead.

## Requirements

| | |
| --- | --- |
| Flutter SDK | Flutter `3.47.0` or newer, with Dart `3.13.0` or newer |
| Android | Java 17+, AGP 9.2.1, KGP 2.4.0, Gradle 9.4.1, `compileSdk` 37, Android 7.0+ (API 24) at runtime. `minSdk` and `targetSdk` are inherited from the Flutter SDK rather than pinned here |
| iOS | Xcode with an iOS 16.0+ deployment target |
| Backend | An Open WebUI instance, an OpenAI-compatible API, an Ollama endpoint, or a Hermes server |

Apple On-Device requires Xcode 26 and an iOS 26 device that supports Apple
Intelligence. It uses the local SystemLanguageModel with a 4K context window;
image input, reasoning controls, and tool parameters are rejected.

Apple Private Cloud Compute additionally requires Xcode 27, an iOS 27 device
that supports Apple Intelligence, and Apple's managed PCC entitlement. The iOS
build keeps PCC compiled out on older SDKs while retaining the iOS 16 deployment
target. PCC accepts image data URLs and Direct generation parameters including
`temperature`, `max_tokens`, `top_p`, `top_k`, `seed`, and OpenAI-style
`response_format.json_schema`; tool parameters are rejected.

## Clone

```bash
git clone --recursive https://github.com/cogwheel0/conduit.git
cd conduit
```

`--recursive` matters. Conduit vendors four submodules:

- `third_party/mermaid`: the native Mermaid renderer packages
  (`mermaid_core`, `mermaid_flutter`), referenced by path from `pubspec.yaml`.
  Without it, `flutter pub get` fails.
- `third_party/katex`: KaTeX assets for math rendering.
- `openwebui-src`: a vendored Open WebUI checkout used **only** as an API
  reference. It is not built or shipped.
- `hermes-src`: a vendored Hermes Agent checkout (NousResearch/hermes-agent)
  used **only** as the reference for the Hermes gateway RPC and REST contracts
  (`tui_gateway/`, `gateway/platforms/api_server.py`). It is not built or
  shipped.

For an existing clone:

```bash
git submodule update --init --recursive
```

## Run

```bash
flutter pub get
dart run build_runner build
XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/ArmOnly.xcconfig" flutter run -d ios
# or
flutter run -d android
```

`dart run build_runner build` is not optional. Riverpod providers, Freezed
models, JSON serialization, and Drift tables generate into `*.g.dart` /
`*.freezed.dart` files that are **git-ignored**. A fresh clone or a new worktree
has none of them, so the analyzer will report hundreds of errors until codegen
runs. If you see missing-symbol errors that look impossible, run codegen before
you start debugging.

The Pigeon bindings are the exception:
`lib/platform/conduit_platform_apis.g.dart`,
`ios/Runner/ConduitPlatformApis.g.swift` and
`android/app/src/main/kotlin/app/cogwheel/conduit/ConduitPlatformApis.g.kt` are
all **checked in**, because Pigeon regenerates on its own pinned toolchain
instead of `build_runner`. Never edit them by hand, and see the separate Pigeon
steps below before regenerating.

The iOS simulator build targets Apple Silicon only. The `XCODE_XCCONFIG_FILE`
setting excludes x86_64 from Swift packages as well as the app and extensions.
Use an ARM emulator or device for Android development.

Pigeon remains pinned separately because its analyzer constraint does not
overlap the Dart 3.13-compatible Riverpod and Freezed generators. Install its
isolated tool dependencies before regenerating platform bindings:

```bash
dart pub get --directory tool/pigeon_codegen
dart tool/pigeon_codegen/bin/generate.dart
```

`vad` 0.0.8 still declares Record 6.x support. The root pubspec temporarily
pins VAD and overrides `record` to 7.1.1; Conduit passes VAD a PCM stream owned
by `VoiceInputService`, so VAD never creates its incompatible internal
recorder. Remove the override and exact VAD pin when [upstream issue
#22](https://github.com/keyur2maru/vad/issues/22) ships Record 7 support. Keep
the Conduit-owned stream until upstream can also preserve externally managed
iOS audio sessions.

## Verify

```bash
flutter pub get
dart run build_runner build
flutter analyze
dart run tool/run_test_shards.dart
```

`flutter analyze` and the test suite are the local gates before handing work
off. `tool/run_test_shards.dart` runs every test file through a few combined
entrypoints, which is much faster than plain `flutter test`; use
`flutter test <file>` for a single file. CI (`.github/workflows/ci.yml`) runs
the analyzer and this test runner on pushes to `main` and on pull requests.

Tests use `flutter_test` with `package:checks` for assertions and `mocktail` for
mocks. Lints come from `flutter_lints` plus `riverpod_lint`.

## Release builds

```bash
# Android
flutter build apk --target-platform android-arm,android-arm64 --release
flutter build appbundle --target-platform android-arm,android-arm64 --release

# iOS
XCODE_XCCONFIG_FILE="$PWD/ios/Flutter/ArmOnly.xcconfig" flutter build ios --release
```

`scripts/release.sh` drives the tagged release flow used by the maintainer.

## Localization

Translations live in `lib/l10n/*.arb`, configured by `l10n.yaml`. English
(`app_en.arb`) is the template; every other locale mirrors its keys.

Do not hand-edit the generated localization Dart. Edit the ARB inputs and let
codegen regenerate. Two helpers validate the result, and CI runs the same
checks:

```bash
dart run tool/validate_arb_locales.dart
dart run tool/verify_arb_descriptions.dart
```

Every key in `app_en.arb` needs an `@key` entry with a `description`, and that
description is the only context a translator gets.

## Project layout

```text
packages/               The pub workspace members. Most of the logic lives here.
  conduit_core/         Flutter-free business logic: ports, providers, Drift
                        schema + DAOs, sync engine, transports, parsers, models
  conduit_markdown/     Pure-Dart model-output parsing (shared with the renderer)
  conduit_theme/        Palette + theme registry, Flutter-free
  conduit_ddgs/         On-device web search for Direct models

lib/                    The Flutter app: UI, adapters, and what has not moved yet
  core/                 App-level wiring: auth, network, persistence, providers,
                        router, services, utils
    auth/               token storage, interceptors, cookie + proxy handling
    services/           app-side services: media upload, native sheets,
                        background streaming, CallKit, haptics
  features/
    auth/               server setup, login, SSO, proxy auth
    channels/           channel browsing and threaded messaging
    chat/               conversations, attachments, tools, streaming, voice call
    direct_connections/ OpenAI-compatible, Ollama, and OpenRouter profiles
    hermes/             Hermes Agent transport, approvals, scheduled jobs
    navigation/         chat shell, drawer, adaptive navigation
    notes/              note editor and AI-assisted note workflows
    notifications/      notification routing and gating
    profile/            theme, preferences, app customization
    prompts/            prompt helpers and prompt variable UI
    release_notes/      in-app release notes and the what's-new banner
    terminal/           WebSocket terminal sessions and file browser
    workspace/          native models, knowledge, prompts, tools, skills
  l10n/                 ARB translation sources
  platform/             The Flutter implementations of the core's ports: the
                        plugins behind path/keychain/cookies/audio, the Pigeon
                        adapter, and the frame profiler
  shared/               reusable widgets, theme tokens, task infrastructure
```

Many `lib/features/**/` paths still exist only as three-line `export` shims
forwarding to `packages/conduit_core`, so the old import paths keep working
while the code moves out from under the app. `tool/check_package_boundaries.dart`
holds the import rules that keep the mobile app, the `conduitd` sidecar, and the
desktop renderer from each re-implementing the same logic.

## Conventions

- Diagnostics go through `DebugLogger`
  (`packages/conduit_core/lib/utils/debug_logger.dart`) with slash-scoped
  `scope:` values like `auth/proxy`, `streaming/helper`, or `models/default`.
  No raw `print` calls.
- Credentials and auth tokens belong in `flutter_secure_storage` via
  `SecureCredentialStorage`. Auth-bearing headers stay scoped to Dio clients
  configured for the selected `ServerConfig.url`.
- `packages/conduit_core/lib/services/api_service.dart` is a barrel over twenty
  `api_service_*.dart` mixins, one per endpoint family (the largest,
  `api_service_base.dart`, is ~2100 lines). Verify endpoint names against
  `openwebui-src/` before adding or changing API calls.
- Model output is normalized by `ConduitMarkdownPreprocessor`
  (`packages/conduit_markdown/lib/src/markdown_preprocessor.dart`) before it
  reaches the renderer. Chart.js blocks still execute the model's own HTML and
  JavaScript in a WebView with `javaScriptEnabled: true` and no CSP
  (`lib/shared/widgets/markdown/markdown_config.dart`). Treat model output as
  untrusted when touching that pipeline.

## Platform permissions

**Android** requests microphone, camera, and optional location access for voice
input, image capture, and location sharing. Attachments go through the system
photo picker, so no broad storage permission is needed.

**iOS** requests microphone, speech recognition, camera, photo library, and
optional location-when-in-use access for the same workflows.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `flutter pub get` cannot resolve `mermaid_core` | Submodules are missing. Run `git submodule update --init --recursive`. |
| Analyzer reports errors in files you never touched | Generated code is missing. Run `dart run build_runner build`. |
| Codegen fails with output conflicts | `dart run build_runner build --delete-conflicting-outputs` |
| iOS device build fails | `cd ios && pod install`, then confirm signing in Xcode. |
| Android build fails | Check the Java 17 / Gradle toolchain, then `flutter clean`. |
| Streaming stalls against your server | Confirm `ENABLE_WEBSOCKET_SUPPORT="true"` on the Open WebUI deployment. |
