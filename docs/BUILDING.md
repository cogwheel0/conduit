# Building Conduit

Everything needed to build, run, and verify Conduit from source. If you only
want to *use* the app, install it from the
[App Store](https://apps.apple.com/us/app/conduit-open-webui-client/id6749840287)
or [Google Play](https://play.google.com/store/apps/details?id=app.cogwheel.conduit)
instead.

## Requirements

| | |
| --- | --- |
| Flutter SDK | Recent stable, with Dart `3.9.2` or newer |
| Android | Java 17, Android SDK (compile/target SDK 36), Android 7.0+ (API 24) at runtime |
| iOS | Xcode with an iOS 16.0+ deployment target |
| Rust | `rustup`, with the repository-pinned Rust 1.95.0 toolchain and mobile targets |
| Backend | An Open WebUI instance, an OpenAI-compatible API, an Ollama endpoint, or a Hermes server |

## Clone

```bash
git clone --recursive https://github.com/cogwheel0/conduit.git
cd conduit
```

`--recursive` matters. Conduit vendors three submodules:

- `third_party/mermaid`: the native Mermaid renderer packages
  (`mermaid_core`, `mermaid_flutter`), referenced by path from `pubspec.yaml`.
  Without it, `flutter pub get` fails.
- `third_party/katex`: KaTeX assets for math rendering.
- `openwebui-src`: a vendored Open WebUI checkout used **only** as an API
  reference. It is not built or shipped.

For an existing clone:

```bash
git submodule update --init --recursive
```

## Run

```bash
flutter pub get
dart run build_runner build
flutter run -d ios
# or
flutter run -d android
```

`dart run build_runner build` is not optional. Riverpod providers, Freezed
models, JSON serialization, Drift tables, and Pigeon bindings all generate into
`*.g.dart` / `*.freezed.dart` files that are **git-ignored**. A fresh clone or a
new worktree has none of them, so the analyzer will report hundreds of errors
until codegen runs. If you see missing-symbol errors that look impossible, run
codegen before you start debugging.

The ChatGPT account runtime is an in-process Rust static library built through
Cargokit and Flutter Rust Bridge 2.12.0. That exact release maps to upstream
commit `62b9330ed2f900535e34d8443ff82dc54070579a`; the Dart package, Rust crate,
and generator are all locked at 2.12.0. The committed bridge output is
regenerated with:

```bash
cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked
flutter_rust_bridge_codegen generate
cargo fmt --manifest-path native/chatgpt_runtime/Cargo.toml
```

Rust honors `rust-toolchain.toml`; no external app-server process is started or
packaged.

### ChatGPT runtime boundary

The mobile runtime is stripped at its capability and API boundaries, not at
every transitive Cargo edge. Codex 0.145.0 unconditionally retains these nine
coding-oriented crates in its app-server/core graph for this PR:

- `codex-apply-patch`
- `codex-exec-server`
- `codex-file-watcher`
- `codex-git-utils`
- `codex-mcp`
- `codex-sandboxing`
- `codex-shell-command`
- `codex-shell-escalation`
- `codex-skills`

They are accepted as compiled-but-unexposed upstream dependencies. Conduit has
no generic JSON-RPC bridge, exposes only typed auth/model/thread/turn methods,
allows only the audited ChatGPT app-server methods, rejects every
server-initiated request, and disables shell, MCP, skills, workspace
environments, approvals, patching, code mode, and multi-agent features. The
V8/Deno implementation is still prohibited, and release-size limits still
apply.

`tool/audit_chatgpt_runtime_exposure.sh` enforces that boundary. Any new bridge
function, app-server method, enabled coding feature, scripting runtime, or lost
server-request rejection fails CI. Removing the nine upstream crates remains a
future size and hardening improvement, not a merge condition for this PR.

Use `--delete-conflicting-outputs` when generated files fall out of sync:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## Verify

```bash
flutter pub get
dart run build_runner build
flutter analyze
flutter test
cargo fmt --manifest-path native/chatgpt_runtime/Cargo.toml --all -- --check
cargo clippy --manifest-path native/chatgpt_runtime/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path native/chatgpt_runtime/Cargo.toml --locked --all-targets
bash tool/audit_chatgpt_runtime_exposure.sh
```

`flutter analyze` and `flutter test` are the local gates before handing work
off. GitHub Actions also verifies the ChatGPT native runtime and its committed
FRB bindings when that code changes.

### ChatGPT account acceptance condition

This PR is complete when a clean checkout can regenerate drift-free FRB
bindings, pass the Rust, Flutter, exposure, and release-size gates, build
release binaries for iOS and every Android ABI, authenticate a ChatGPT account,
complete every supported chat operation, survive relaunch, and remove all
account-owned data on explicit disconnect without affecting unrelated data.

Dependency-level removal of the nine acknowledged Codex crates above is
explicitly not part of this PR's acceptance condition. The exposure audit must
instead prove the fixed typed bridge and app-server method allowlists, disabled
coding capabilities, rejection of server-initiated requests, and absence of
V8/Deno. The PR remains draft until the real-device authentication, chat,
lifecycle, and destructive-cleanup scenarios pass on both Android and iOS.

Tests use `flutter_test` with `package:checks` for assertions and `mocktail` for
mocks. Lints come from `flutter_lints` plus `riverpod_lint`.

## Release builds

```bash
# Android
flutter build apk --release --split-per-abi --no-tree-shake-icons
flutter build appbundle --release

# iOS
flutter build ios --release --no-codesign --no-tree-shake-icons

# After both ChatGPT-enabled builds
bash tool/audit_chatgpt_release_size.sh
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
lib/
  core/                 auth, routing, models, networking, database, platform services
    auth/               token storage, interceptors, cookie + proxy handling
    database/           Drift schema, DAOs, mappers, full-text search
    services/           API client, streaming, widgets, quick actions
  features/
    auth/               server setup, login, SSO, proxy auth
    channels/           channel browsing and threaded messaging
    chat/               conversations, attachments, tools, streaming, voice call
    chatgpt/            ChatGPT account runtime, authentication, and account UI
    direct_connections/ OpenAI-compatible, Ollama, and OpenRouter profiles
    hermes/             Hermes Agent transport, approvals, scheduled jobs
    navigation/         chat shell, drawer, adaptive navigation
    notes/              note editor and AI-assisted note workflows
    notifications/      notification routing and gating
    profile/            theme, preferences, app customization
    prompts/            prompt helpers and prompt variable UI
    terminal/           WebSocket terminal sessions and file browser
    tools/              tool integration surfaces
    workspace/          native models, knowledge, prompts, tools, skills
  l10n/                 ARB translation sources
  shared/               reusable widgets, theme tokens, task infrastructure
```

## Conventions

- Diagnostics go through `DebugLogger` (`lib/core/utils/debug_logger.dart`) with
  slash-scoped `scope:` values like `auth/proxy`, `streaming/helper`, or
  `models/default`. No raw `print` calls.
- Credentials and auth tokens belong in `flutter_secure_storage` via
  `SecureCredentialStorage`. Auth-bearing headers stay scoped to Dio clients
  configured for the selected `ServerConfig.url`.
- `lib/core/services/api_service.dart` is roughly 6000 lines and mixes many
  endpoint families. Verify endpoint names against `openwebui-src/` before
  adding or changing API calls.
- Chat markdown is sanitized in `lib/features/chat/views/chat_page.dart`, but
  Chart.js blocks still render through a WebView in
  `lib/shared/widgets/markdown/markdown_config.dart`. Treat model output as
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
