# Project

Conduit is a native Flutter client for iOS and Android that connects to self-hosted Open WebUI servers. The upstream server is vendored as the `openwebui-src/` submodule and should be treated as the source of truth for Open WebUI API endpoints and behavior.

# Build, codegen, and verification

Use the README command blocks as the baseline:

```bash
flutter pub get
dart run build_runner build
flutter run -d ios
# or
flutter run -d android
```

```bash
flutter pub get
dart run build_runner build
flutter test
```

Run `dart run build_runner build` after `flutter pub get` and after switching branches or creating a fresh worktree. Generated `*.g.dart` and `*.freezed.dart` files are ignored by git but required by analyzer/test runs. `flutter test` and `flutter analyze` are local verification gates before handoff; `.github/workflows/` currently contains only `.github/workflows/l10n.yml` and `.github/workflows/release.yml`, so these checks are not run on every push.

# Architecture & layout

Top-level Dart code is split into `lib/core/` for app-wide services, models, routing, auth, storage, networking, and platform glue; `lib/features/` for product areas; `lib/shared/` for reusable widgets and utilities; and `lib/l10n/` for localization ARB files and generated localization output configured by `l10n.yaml`. Do not hand-edit generated localization Dart; edit ARB inputs and regenerate.

State management uses Riverpod 3 with generated providers. Navigation uses `go_router`. HTTP and realtime transport use Dio and `socket_io_client`. Local persistence uses Hive CE, `shared_preferences`, and `flutter_secure_storage`.

# Conventions

Use `DebugLogger` from `lib/core/utils/debug_logger.dart` for diagnostics, with slash-scoped `scope:` values such as `auth/proxy`, `streaming/helper`, or `models/default`; do not add raw `print` calls. Tests use `package:checks`, `flutter_test`, and `mocktail`. Lints come from `flutter_lints` and `riverpod_lint`.

# Auth subsystem map

Auth is spread across `lib/core/auth/`, `lib/features/auth/views/`, and `lib/features/auth/providers/unified_auth_providers.dart`. Start with `lib/features/auth/views/server_connection_page.dart` for server URL setup, custom headers, proxy detection, and reverse-proxy handoff. `lib/features/auth/views/authentication_page.dart` covers username/password, LDAP, manual JWT token entry, and SSO entry points. `lib/features/auth/views/sso_auth_page.dart` handles Open WebUI SSO/OAuth in a WebView, while `lib/features/auth/views/proxy_auth_page.dart` handles reverse-proxy login pages and cookie/JWT capture.

Cookie helpers live in `lib/core/auth/webview_cookie_helper.dart` and `lib/core/auth/native_cookie_manager.dart`. `lib/core/auth/auth_state_manager.dart` owns token restore, login, logout, and secure persistence. `lib/core/auth/api_auth_interceptor.dart` injects bearer tokens and custom headers into configured Dio requests. `lib/core/auth/token_validator.dart` handles JWT/API-key format checks and server validation. Credentials and auth tokens must live in `flutter_secure_storage` through `SecureCredentialStorage`; auth-bearing headers should stay scoped to clients configured for the selected `ServerConfig.url`.

# Gotchas

`lib/core/services/api_service.dart` is about 6000 lines and mixes many endpoint families, so verify endpoint names against `openwebui-src/` before adding or changing API calls. Markdown from chat content is sanitized in `lib/features/chat/views/chat_page.dart`, but Mermaid and ChartJS blocks can render through WebViews in `lib/shared/widgets/markdown/markdown_config.dart`; treat model output as untrusted when changing that pipeline. Fresh worktrees may be missing generated Dart files because they are git-ignored, so run build_runner before assuming analyzer failures are real source errors.
