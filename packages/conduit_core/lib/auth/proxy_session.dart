import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// What an external sign-in left behind.
///
/// A reverse proxy (oauth2-proxy, Authelia, Authentik, Pangolin, Cloudflare
/// Tunnel) authenticates in a browser context and leaves a cookie session.
/// Some of them go further and hand Open WebUI trusted headers, in which case
/// Open WebUI issues a JWT and no second sign-in is needed.
///
/// Host-agnostic on purpose: the mobile app fills this from an in-app
/// WebView, the desktop from an Electron auth window, and neither difference
/// reaches the prevalidation below.
class ProxyAuthCapture {
  const ProxyAuthCapture({this.cookies = const <String, String>{}, this.token});

  final Map<String, String> cookies;

  /// Present when the proxy's trusted headers already authenticated the user.
  final String? token;

  /// Whether a sign-in form can be skipped entirely.
  bool get isFullyAuthenticated => (token ?? '').trim().isNotEmpty;
}

/// The outcome of [prevalidateProxySession].
sealed class ProxySessionPrevalidation {
  const ProxySessionPrevalidation();
}

/// The proxy session works and the user is signed in; commit it.
final class ProxySessionAuthenticated extends ProxySessionPrevalidation {
  const ProxySessionAuthenticated({
    required this.serverConfig,
    required this.backendConfig,
    required this.token,
    required this.user,
  });

  /// Carries the captured cookies as a `Cookie` header, and nothing secret
  /// beyond what the caller already supplied.
  final ServerConfig serverConfig;
  final BackendConfig backendConfig;
  final String token;
  final User user;
}

/// The server is a real Open WebUI and reachable through the proxy, but the
/// user still has to sign in. The caller shows a login form against
/// [serverConfig], whose cookies are what get it past the proxy.
final class ProxySessionNeedsSignIn extends ProxySessionPrevalidation {
  const ProxySessionNeedsSignIn({
    required this.serverConfig,
    required this.backendConfig,
  });

  final ServerConfig serverConfig;
  final BackendConfig backendConfig;
}

/// Why a prevalidation stopped.
enum ProxySessionFailure {
  /// The request did not reach an Open WebUI instance -- wrong host, proxy
  /// still challenging, TLS refused.
  serverUnreachable,

  /// The host answered but is not Open WebUI.
  notOpenWebUi,

  /// Trusted-header discovery claimed success but produced no usable token.
  tokenMissing,

  /// A token arrived and the server rejected it. Discovery can report success
  /// while returning an already-expired JWT, which is exactly why the token
  /// is validated before anything is persisted.
  tokenRejected,
}

final class ProxySessionRejected extends ProxySessionPrevalidation {
  const ProxySessionRejected(this.failure, {this.error});

  final ProxySessionFailure failure;
  final Object? error;
}

/// Validates an external sign-in before any of it is persisted.
///
/// Extracted from the mobile connection page. The sequence is the
/// business logic of "did this proxy session actually work", and it was
/// sitting in a Flutter widget where the sidecar could not reach it --
/// so the desktop would have had to reimplement it, which for an auth path
/// means reimplementing the reasons each step exists.
///
/// The ordering carries the security properties, and none of it is
/// incidental:
///
///  * the captured JWT is given to an operation-scoped client only, never
///    embedded in the returned [ServerConfig], so it cannot survive a logout
///    or a server switch;
///  * the server is confirmed to be Open WebUI before any credential is
///    treated as meaningful;
///  * the token is validated by an actual authenticated call before the
///    caller is allowed to commit it.
Future<ProxySessionPrevalidation> prevalidateProxySession({
  required ServerConfig serverConfig,
  required ProxyAuthCapture capture,
  required WorkerManager workerManager,
  ApiService Function({
    required ServerConfig serverConfig,
    required WorkerManager workerManager,
    String? authToken,
  })?
  createApi,
}) async {
  final configWithCookies = serverConfig.copyWith(
    customHeaders: capture.cookies.isEmpty
        ? serverConfig.customHeaders
        : mergeCapturedProxyCookiesIntoHeaders(
            headers: serverConfig.customHeaders,
            capturedCookies: capture.cookies,
          ),
  );

  final api = (createApi ?? _defaultCreateApi)(
    serverConfig: configWithCookies,
    workerManager: workerManager,
    authToken: capture.token,
  );

  try {
    final BackendConfig? backendConfig;
    try {
      backendConfig = await api.verifyAndGetConfig();
    } catch (error) {
      DebugLogger.error(
        'proxy-server-verification-error',
        scope: 'auth/proxy',
        data: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      return ProxySessionRejected(
        ProxySessionFailure.serverUnreachable,
        error: error,
      );
    }
    if (backendConfig == null) {
      return const ProxySessionRejected(ProxySessionFailure.notOpenWebUi);
    }

    if (!capture.isFullyAuthenticated) {
      return ProxySessionNeedsSignIn(
        serverConfig: configWithCookies,
        backendConfig: backendConfig,
      );
    }

    final token = capture.token!.trim();
    if (token.isEmpty) {
      return const ProxySessionRejected(ProxySessionFailure.tokenMissing);
    }

    final User user;
    try {
      user = await api.getCurrentUser(suppressAuthFailureNotification: true);
    } catch (error) {
      DebugLogger.error(
        'proxy-issued-token-validation-failed',
        scope: 'auth/proxy',
        data: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      return ProxySessionRejected(
        ProxySessionFailure.tokenRejected,
        error: error,
      );
    }

    return ProxySessionAuthenticated(
      serverConfig: configWithCookies,
      backendConfig: backendConfig,
      token: token,
      user: user,
    );
  } finally {
    api.dispose();
  }
}

ApiService _defaultCreateApi({
  required ServerConfig serverConfig,
  required WorkerManager workerManager,
  String? authToken,
}) => ApiService(
  serverConfig: serverConfig,
  workerManager: workerManager,
  authToken: authToken,
);

/// Merges proxy cookies into headers without leaving alternate-cased Cookie
/// fields or duplicate cookie names. Newly captured values are authoritative.
Map<String, String> mergeCapturedProxyCookiesIntoHeaders({
  required Map<String, String> headers,
  required Map<String, String> capturedCookies,
}) {
  final mergedHeaders = Map<String, String>.from(headers);
  final mergedCookies = <String, String>{};

  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != 'cookie') continue;
    for (final component in entry.value.split(';')) {
      final separator = component.indexOf('=');
      if (separator <= 0) continue;
      final name = component.substring(0, separator).trim();
      if (name.isEmpty) continue;
      mergedCookies[name] = component.substring(separator + 1).trim();
    }
  }

  mergedHeaders.removeWhere((key, _) => key.toLowerCase() == 'cookie');
  mergedCookies.addAll(capturedCookies);
  if (mergedCookies.isNotEmpty) {
    mergedHeaders['Cookie'] = mergedCookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }
  return mergedHeaders;
}
