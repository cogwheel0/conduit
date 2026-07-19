import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/native_cookie_manager.dart';
import '../../../core/auth/webview_cookie_helper.dart';
import '../../../core/auth/webview_origin.dart';
import '../../../core/models/server_config.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'package:conduit/l10n/app_localizations.dart';

/// Whether a proxy page is allowed to expose cookies or localStorage tokens.
@visibleForTesting
bool isTrustedProxyCredentialCaptureUrl({
  required String pageUrl,
  required String serverUrl,
}) => webViewUrlHasExactServerOrigin(pageUrl, serverUrl);

@visibleForTesting
String proxyCookieLookupUrl(String serverUrl) =>
    webViewCookieLookupUrl(serverUrl);

/// Runs the retry path appropriate for the current WebView lifecycle.
///
/// A failed pre-WebView cleanup leaves no controller to reload, so retry must
/// repeat initialization. Once a controller exists, reloading preserves the
/// current platform view and its proxy-auth session.
@visibleForTesting
Future<void> refreshProxyAuthWebView<Controller>({
  required Controller? controller,
  required Future<void> Function() initialize,
  required Future<void> Function(Controller controller) reload,
}) async {
  if (controller == null) {
    await initialize();
    return;
  }
  await reload(controller);
}

/// Result of proxy authentication.
class ProxyAuthResult {
  /// Whether authentication was successful.
  final bool success;

  /// Proxy session cookies to be injected into API requests.
  final Map<String, String>? cookies;

  /// JWT token if user is already authenticated via trusted headers.
  /// When oauth2-proxy uses trusted headers, OpenWebUI auto-authenticates
  /// the user after proxy auth, so no separate sign-in is needed.
  final String? jwtToken;

  const ProxyAuthResult({required this.success, this.cookies, this.jwtToken});

  /// Creates a failed result.
  const ProxyAuthResult.failed()
    : success = false,
      cookies = null,
      jwtToken = null;

  /// Creates a successful result with captured cookies.
  const ProxyAuthResult.success({this.cookies, this.jwtToken}) : success = true;

  /// Whether the user is fully authenticated (has JWT token).
  bool get isFullyAuthenticated => jwtToken != null && jwtToken!.isNotEmpty;
}

/// Configuration for the proxy authentication flow.
class ProxyAuthConfig {
  /// The server configuration to authenticate against.
  final ServerConfig serverConfig;

  /// Optional callback when proxy authentication completes successfully.
  final VoidCallback? onAuthComplete;

  const ProxyAuthConfig({required this.serverConfig, this.onAuthComplete});
}

/// Returns whether the proxy auth page should complete and pop.
///
/// Manual completion always proceeds. Automatic completion only waits for a JWT
/// when the current OpenWebUI page still needs in-WebView SSO to finish.
@visibleForTesting
bool shouldCompleteProxyAuthCapture({
  required bool isManual,
  required bool shouldWaitForJwt,
  required String? jwtToken,
}) {
  if (isManual || !shouldWaitForJwt) return true;
  return hasCapturedJwtToken(jwtToken);
}

/// Returns whether a captured JWT token is present.
@visibleForTesting
bool hasCapturedJwtToken(String? jwtToken) {
  return jwtToken != null && jwtToken.trim().isNotEmpty;
}

/// Returns whether automatic completion should wait for a JWT.
///
/// OpenWebUI's `/oauth/...` routes and `/auth` without a password field still
/// require the WebView to stay open so OpenWebUI can finish its own auth flow.
@visibleForTesting
bool shouldWaitForAutomaticProxyAuthCapture({
  required String path,
  required bool hasPasswordField,
}) {
  final normalizedPath = path.toLowerCase();
  if (normalizedPath.contains('/oauth/')) return true;

  final isAuthPath =
      normalizedPath == '/auth' || normalizedPath.startsWith('/auth/');
  return isAuthPath && !hasPasswordField;
}

/// Returns whether automatic capture should keep requiring a JWT.
///
/// Once an OpenWebUI proxy flow has shown an in-WebView SSO handoff, later
/// automatic page finishes in the same session must keep waiting for the JWT
/// until it is captured or the user explicitly continues manually.
@visibleForTesting
bool shouldRequireJwtForAutomaticCapture({
  required bool hasPendingJwtWait,
  required bool currentPageShouldWait,
}) {
  return hasPendingJwtWait || currentPageShouldWait;
}

/// Resolves the sticky automatic JWT requirement only while the asynchronous
/// page inspection still owns its original main-frame document.
@visibleForTesting
bool? resolveProxyAuthJwtRequirement({
  required bool ownsDocument,
  required bool hasPendingJwtWait,
  required bool currentPageShouldWait,
}) {
  if (!ownsDocument) return null;
  return shouldRequireJwtForAutomaticCapture(
    hasPendingJwtWait: hasPendingJwtWait,
    currentPageShouldWait: currentPageShouldWait,
  );
}

/// Returns whether the current path is owned by OpenWebUI's auth flow.
///
/// Proxy login pages can live on the same host as the target server, so host
/// matching alone is not enough to decide that automatic capture should run.
@visibleForTesting
bool isKnownOpenWebUiProxyAuthPath(String path) {
  final normalizedPath = path.toLowerCase();
  if (normalizedPath.contains('/oauth/')) return true;

  final isAuthPath =
      normalizedPath == '/auth' || normalizedPath.startsWith('/auth/');
  if (isAuthPath) return true;

  return normalizedPath.contains('/api/v1/auths/');
}

/// Returns whether automatic proxy capture should run for the current page.
///
/// Automatic capture should wait until the WebView has either loaded an
/// OpenWebUI page or reached an OpenWebUI-owned auth callback path. This
/// avoids prematurely completing on proxy login pages that happen to share the
/// same host as the configured server.
@visibleForTesting
bool shouldAttemptAutomaticProxyAuthCapture({
  required bool looksLikeOpenWebUi,
  required String path,
}) {
  return looksLikeOpenWebUi || isKnownOpenWebUiProxyAuthPath(path);
}

/// Capture request mode for proxy auth.
@visibleForTesting
enum ProxyAuthCaptureMode { automatic, manual }

/// Snapshot of the page state that triggered a proxy auth capture attempt.
@visibleForTesting
final class ProxyAuthCaptureRequest {
  const ProxyAuthCaptureRequest({
    required this.mode,
    required this.shouldWaitForJwt,
    required this.path,
  });

  const ProxyAuthCaptureRequest.automatic({
    required bool shouldWaitForJwt,
    required String path,
  }) : this(
         mode: ProxyAuthCaptureMode.automatic,
         shouldWaitForJwt: shouldWaitForJwt,
         path: path,
       );

  const ProxyAuthCaptureRequest.manual()
    : this(
        mode: ProxyAuthCaptureMode.manual,
        shouldWaitForJwt: false,
        path: 'manual',
      );

  final ProxyAuthCaptureMode mode;
  final bool shouldWaitForJwt;
  final String path;

  bool get isManual => mode == ProxyAuthCaptureMode.manual;

  @override
  bool operator ==(Object other) {
    return other is ProxyAuthCaptureRequest &&
        other.mode == mode &&
        other.shouldWaitForJwt == shouldWaitForJwt &&
        other.path == path;
  }

  @override
  int get hashCode => Object.hash(mode, shouldWaitForJwt, path);
}

/// Result of evaluating whether a capture attempt should finish.
@visibleForTesting
enum ProxyAuthCaptureDecision { complete, waitForJwt, deferToQueuedRequest }

/// Decides whether a capture attempt should complete, wait, or defer.
@visibleForTesting
ProxyAuthCaptureDecision decideProxyAuthCapture({
  required ProxyAuthCaptureRequest activeRequest,
  required ProxyAuthCaptureRequest? queuedRequest,
  required String? jwtToken,
}) {
  if (hasCapturedJwtToken(jwtToken)) {
    return ProxyAuthCaptureDecision.complete;
  }
  if (activeRequest.isManual) {
    return ProxyAuthCaptureDecision.complete;
  }
  if (queuedRequest?.isManual ?? false) {
    return ProxyAuthCaptureDecision.deferToQueuedRequest;
  }
  if (activeRequest.shouldWaitForJwt) {
    return ProxyAuthCaptureDecision.waitForJwt;
  }
  if (queuedRequest != null) {
    return ProxyAuthCaptureDecision.deferToQueuedRequest;
  }
  return shouldCompleteProxyAuthCapture(
        isManual: activeRequest.isManual,
        shouldWaitForJwt: activeRequest.shouldWaitForJwt,
        jwtToken: jwtToken,
      )
      ? ProxyAuthCaptureDecision.complete
      : ProxyAuthCaptureDecision.waitForJwt;
}

/// Small queue that coalesces repeated proxy capture requests.
///
/// Manual requests take precedence so an explicit user tap is never lost while
/// an automatic capture attempt is already in flight.
@visibleForTesting
final class ProxyAuthCaptureQueue {
  bool _inProgress = false;
  ProxyAuthCaptureRequest? _queuedRequest;

  ProxyAuthCaptureRequest? get queuedRequest => _queuedRequest;

  ProxyAuthCaptureRequest? begin(ProxyAuthCaptureRequest request) {
    if (_inProgress) {
      _queuedRequest = switch ((_queuedRequest, request)) {
        (ProxyAuthCaptureRequest(:final isManual), _) when isManual =>
          _queuedRequest,
        (_, ProxyAuthCaptureRequest(:final isManual)) when isManual => request,
        (
          ProxyAuthCaptureRequest(
            mode: ProxyAuthCaptureMode.automatic,
            :final shouldWaitForJwt,
            :final path,
          ),
          ProxyAuthCaptureRequest(
            mode: ProxyAuthCaptureMode.automatic,
            shouldWaitForJwt: final incomingShouldWait,
            path: final incomingPath,
          ),
        ) =>
          ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: shouldWaitForJwt || incomingShouldWait,
            path: incomingShouldWait ? incomingPath : path,
          ),
        _ => request,
      };
      return null;
    }

    _inProgress = true;
    return request;
  }

  ProxyAuthCaptureRequest? finish({required bool completed}) {
    _inProgress = false;
    if (completed) {
      _queuedRequest = null;
      return null;
    }

    final nextRequest = _queuedRequest;
    _queuedRequest = null;
    return nextRequest;
  }

  void reset() {
    _inProgress = false;
    _queuedRequest = null;
  }
}

/// Proxy Authentication page that uses a WebView to handle authentication
/// through reverse proxies like oauth2-proxy or Pangolin.
///
/// This page loads the server URL in a WebView, allowing users to authenticate
/// through the proxy. Once the proxy auth is complete (detected by reaching
/// the actual server), the proxy session cookies are captured and returned.
///
/// The user will then be redirected to the normal sign-in flow, where the
/// proxy cookies will be injected into API requests.
class ProxyAuthPage extends ConsumerStatefulWidget {
  final ProxyAuthConfig config;

  const ProxyAuthPage({super.key, required this.config});

  @override
  ConsumerState<ProxyAuthPage> createState() => _ProxyAuthPageState();
}

/// Binds asynchronous credential capture to one main-frame document.
@visibleForTesting
final class ProxyAuthDocumentFence {
  int _generation = 0;
  String? _documentKey;

  int get generation => _generation;

  void startNavigation(String url) {
    _generation++;
    _documentKey = _key(url);
  }

  void invalidate() {
    _generation++;
    _documentKey = null;
  }

  bool ownsGeneration(int generation) => generation == _generation;

  bool ownsDocument(int generation, String url) =>
      ownsGeneration(generation) && _documentKey == _key(url);

  static String _key(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    // Fragments do not select a different credential origin/document.
    return uri.replace(fragment: '').toString();
  }
}

class _ProxyAuthPageState extends ConsumerState<ProxyAuthPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _cookiesCaptured = false;
  final _captureQueue = ProxyAuthCaptureQueue();
  final _documentFence = ProxyAuthDocumentFence();
  bool _automaticCaptureRequiresJwt = false;
  String? _error;
  bool _isOnTargetServer = false;
  bool _shouldRenderWebView = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initializeWebView();
    });
  }

  @override
  void dispose() {
    _documentFence.invalidate();
    _captureQueue.reset();
    _controller = null;
    super.dispose();
  }

  bool _ownsCaptureGeneration(int generation) =>
      mounted && _documentFence.ownsGeneration(generation);

  bool _ownsCaptureDocument(int generation, String url) =>
      mounted && _documentFence.ownsDocument(generation, url);

  void _invalidateCaptureQueue({String? navigationUrl}) {
    if (navigationUrl == null) {
      _documentFence.invalidate();
    } else {
      _documentFence.startNavigation(navigationUrl);
    }
    _captureQueue.reset();
  }

  Future<void> _initializeWebView() async {
    if (!isWebViewSupported) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _error =
            l10n?.proxyAuthPlatformNotSupported ??
            'Proxy authentication requires a mobile device. '
                'Please authenticate through a browser first.';
        _isLoading = false;
      });
      return;
    }

    final serverUrl = widget.config.serverConfig.url;
    DebugLogger.auth(
      'Initializing Proxy Auth WebView for ${webViewOriginForLog(serverUrl)}',
      scope: 'auth/proxy',
    );

    // Don't clear cookies - preserve any existing proxy session. Do wait for
    // a logout purge that was already requested before this flow so that purge
    // cannot erase cookies/storage after the new WebView starts loading.
    final webViewDataReady =
        await WebViewCookieHelper.ensurePendingLogoutDataCleared();
    if (!mounted) return;
    if (!webViewDataReady) {
      setState(() {
        _error =
            'The previous web sign-in session could not be cleared. '
            'Please retry.';
        _isLoading = false;
        _shouldRenderWebView = false;
      });
      return;
    }

    setState(() {
      _controller = null;
      _shouldRenderWebView = true;
      _isLoading = true;
      _error = null;
      _cookiesCaptured = false;
      _isOnTargetServer = false;
    });
  }

  Future<void> _loadInitialServerPage(InAppWebViewController controller) async {
    final serverUrl = widget.config.serverConfig.url;
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(serverUrl)));
    } catch (error, stackTrace) {
      DebugLogger.error(
        'proxy-webview-initial-load-failed',
        scope: 'auth/proxy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _error = 'The sign-in page could not be loaded. Please retry.';
        _isLoading = false;
      });
    }
  }

  String _buildUserAgent() {
    if (!kIsWeb && Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    } else {
      return 'Mozilla/5.0 (Linux; Android 14) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }
  }

  void _onPageStarted(String url) {
    if (!mounted) return;
    // Invalidate capture synchronously before any state update. Same-origin
    // proxy pages are distinct documents; origin checks alone cannot stop an
    // async capture from the previous page from completing after navigation.
    _invalidateCaptureQueue(navigationUrl: url);
    DebugLogger.auth(
      'Proxy auth page started: ${webViewOriginForLog(url)}',
      scope: 'auth/proxy',
    );
    final isOnTargetServer = isTrustedProxyCredentialCaptureUrl(
      pageUrl: url,
      serverUrl: widget.config.serverConfig.url,
    );
    setState(() {
      _isLoading = true;
      _error = null;
      _isOnTargetServer = isOnTargetServer;
    });
  }

  Future<void> _onPageFinished(String url) async {
    if (!mounted) return;
    final generation = _documentFence.generation;
    if (!_ownsCaptureDocument(generation, url)) return;
    DebugLogger.auth(
      'Proxy auth page finished: ${webViewOriginForLog(url)}',
      scope: 'auth/proxy',
    );

    setState(() {
      _isLoading = false;
    });

    if (_cookiesCaptured) return;

    final uri = Uri.tryParse(url);
    if (uri == null) {
      _isOnTargetServer = false;
      return;
    }

    // Check for error parameter
    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      DebugLogger.auth(
        'Proxy auth callback reported an OAuth error',
        scope: 'auth/proxy',
      );
      setState(() {
        _error = error;
      });
      return;
    }

    // Check if we're on our target server
    final serverUrl = widget.config.serverConfig.url;
    final isOnTargetServer = isTrustedProxyCredentialCaptureUrl(
      pageUrl: url,
      serverUrl: serverUrl,
    );
    _isOnTargetServer = isOnTargetServer;
    if (isOnTargetServer) {
      // We've reached our server - proxy auth must be complete
      _isOnTargetServer = true;
      await _checkIfOpenWebUI(url, generation);
    }
  }

  /// Checks if we're on the OpenWebUI page and captures cookies if so.
  Future<void> _checkIfOpenWebUI(String url, int generation) async {
    if (_cookiesCaptured || !_ownsCaptureDocument(generation, url)) return;

    final controller = _controller;
    if (controller == null) return;
    final serverUrl = widget.config.serverConfig.url;
    if (!isTrustedProxyCredentialCaptureUrl(
          pageUrl: url,
          serverUrl: serverUrl,
        ) ||
        !await _isControllerOnTargetOrigin()) {
      _isOnTargetServer = false;
      return;
    }
    if (!_ownsCaptureDocument(generation, url)) return;
    final path = Uri.parse(url).path;

    try {
      // Check if this is an OpenWebUI page by looking for specific elements
      // or the /api/config endpoint being accessible
      final result = await controller.evaluateJavascript(
        source: '''
        (function() {
          var title = (document.title || "").toLowerCase();
          var hasKnownIds =
            document.getElementById("auth-page") !== null ||
            document.getElementById("auth-container") !== null;
          var hasBrandMarkers =
            document.querySelector('meta[name="apple-mobile-web-app-title"]') !== null ||
            document.querySelector('link[rel*="icon"][href*="/static/favicon"]') !== null;
          var hasUiMarkers =
            document.querySelector('div[class*="chat"]') !== null ||
            document.querySelector('[data-testid]') !== null;
          // Check for OpenWebUI specific elements or title
          var isOpenWebUI =
            hasKnownIds ||
            hasBrandMarkers ||
            hasUiMarkers ||
            title.includes('open webui') ||
            title.includes('chat');
          return isOpenWebUI ? "true" : "false";
        })()
        ''',
      );

      if (!_ownsCaptureDocument(generation, url) ||
          !await _isControllerOnTargetOrigin() ||
          !_ownsCaptureDocument(generation, url)) {
        _isOnTargetServer = false;
        return;
      }

      final isOpenWebUI = result.toString().contains('true');
      DebugLogger.auth(
        'OpenWebUI detection: $isOpenWebUI (on target server: $_isOnTargetServer)',
        scope: 'auth/proxy',
      );

      if (!_isOnTargetServer) {
        return;
      }

      if (shouldAttemptAutomaticProxyAuthCapture(
        looksLikeOpenWebUi: isOpenWebUI,
        path: path,
      )) {
        final request = await _buildAutomaticCaptureRequest(url, generation);
        if (request == null || !_ownsCaptureDocument(generation, url)) return;
        await _requestProxyCookieCapture(
          request,
          expectedGeneration: generation,
        );
        return;
      }

      DebugLogger.auth(
        'Same-host page does not look like OpenWebUI yet; waiting',
        scope: 'auth/proxy',
      );
    } catch (e) {
      DebugLogger.log(
        'OpenWebUI detection failed',
        scope: 'auth/proxy',
        data: {'errorType': e.runtimeType.toString()},
      );

      // If detection fails, only fall back to automatic capture on OpenWebUI's
      // own auth routes. Same-host proxy login pages must stay in the WebView.
      if (_ownsCaptureDocument(generation, url) &&
          _isOnTargetServer &&
          isKnownOpenWebUiProxyAuthPath(path)) {
        try {
          final request = await _buildAutomaticCaptureRequest(url, generation);
          if (request == null || !_ownsCaptureDocument(generation, url)) return;
          await _requestProxyCookieCapture(
            request,
            expectedGeneration: generation,
          );
        } catch (captureError, captureStackTrace) {
          if (!_ownsCaptureDocument(generation, url)) return;
          DebugLogger.error(
            'automatic-proxy-capture-failed',
            scope: 'auth/proxy',
            error: captureError,
            stackTrace: captureStackTrace,
            data: {'errorType': captureError.runtimeType.toString()},
          );
          setState(() {
            _error =
                'The proxy sign-in session could not be captured. '
                'Please retry or continue manually.';
          });
        }
      } else {
        DebugLogger.auth(
          'Skipping automatic proxy capture on non-OpenWebUI page',
          scope: 'auth/proxy',
        );
      }
    }
  }

  /// Captures proxy session cookies and checks for JWT token.
  ///
  /// When oauth2-proxy uses trusted headers (like X-Forwarded-Email),
  /// OpenWebUI auto-authenticates the user after proxy auth. In this case,
  /// we can capture the JWT token and skip the sign-in page entirely.
  Future<void> _requestProxyCookieCapture(
    ProxyAuthCaptureRequest request, {
    int? expectedGeneration,
  }) async {
    if (_cookiesCaptured || !mounted) return;
    final generation = expectedGeneration ?? _documentFence.generation;
    if (!_ownsCaptureGeneration(generation)) return;
    if (!await _isControllerOnTargetOrigin()) {
      if (!_ownsCaptureGeneration(generation)) return;
      _isOnTargetServer = false;
      DebugLogger.auth(
        'Skipping proxy credential capture outside the configured origin',
        scope: 'auth/proxy',
      );
      return;
    }
    if (!_ownsCaptureGeneration(generation)) return;

    final captureRequest = _captureQueue.begin(request);
    if (captureRequest == null) return;

    await _captureProxyCookies(captureRequest, generation);
  }

  Future<void> _captureProxyCookies(
    ProxyAuthCaptureRequest request,
    int generation,
  ) async {
    if (_cookiesCaptured || !_ownsCaptureGeneration(generation)) return;

    var didComplete = false;
    Object? pendingError;
    StackTrace? pendingStackTrace;
    ProxyAuthCaptureRequest? nextRequest;

    try {
      if (!await _isControllerOnTargetOrigin()) {
        if (!_ownsCaptureGeneration(generation)) return;
        _isOnTargetServer = false;
        return;
      }
      if (!_ownsCaptureGeneration(generation)) return;

      final serverUrl = widget.config.serverConfig.url;
      DebugLogger.auth(
        'Capturing proxy cookies for ${webViewOriginForLog(serverUrl)}',
        scope: 'auth/proxy',
      );

      // Get cookies from native cookie store
      final cookies = await NativeCookieManager.getCookiesForUrl(
        proxyCookieLookupUrl(serverUrl),
      );

      if (!_ownsCaptureGeneration(generation)) return;
      if (!await _isControllerOnTargetOrigin()) {
        if (!_ownsCaptureGeneration(generation)) return;
        _isOnTargetServer = false;
        return;
      }
      if (!_ownsCaptureGeneration(generation)) return;

      DebugLogger.auth(
        'Captured ${cookies.length} proxy cookies',
        scope: 'auth/proxy',
      );

      if (cookies.isEmpty) {
        DebugLogger.warning(
          'No cookies captured - proxy may use HttpOnly cookies not accessible',
          scope: 'auth/proxy',
        );
      }

      // Check if OpenWebUI has already authenticated via trusted headers
      // This happens when oauth2-proxy sets X-Forwarded-Email and OpenWebUI
      // auto-creates/logs in the user
      final jwtToken = await _tryCaptureJwtTokenWithRetry();
      if (!_ownsCaptureGeneration(generation)) return;
      if (!await _isControllerOnTargetOrigin()) {
        if (!_ownsCaptureGeneration(generation)) return;
        _isOnTargetServer = false;
        return;
      }
      if (!_ownsCaptureGeneration(generation)) return;
      final decision = decideProxyAuthCapture(
        activeRequest: request,
        queuedRequest: _captureQueue.queuedRequest,
        jwtToken: jwtToken,
      );

      switch (decision) {
        case ProxyAuthCaptureDecision.deferToQueuedRequest:
          DebugLogger.auth(
            'Deferring proxy auth completion to a newer queued request',
            scope: 'auth/proxy',
          );
          break;
        case ProxyAuthCaptureDecision.waitForJwt:
          DebugLogger.auth(
            'JWT token not available yet - keeping proxy auth page open',
            scope: 'auth/proxy',
          );
          break;
        case ProxyAuthCaptureDecision.complete:
          if (!mounted || !_ownsCaptureGeneration(generation)) return;

          _cookiesCaptured = true;
          didComplete = true;

          // Notify callback if provided.
          widget.config.onAuthComplete?.call();

          // Pop with success result, cookies, and possibly JWT token.
          context.pop(
            ProxyAuthResult.success(cookies: cookies, jwtToken: jwtToken),
          );
      }
    } catch (e, stackTrace) {
      if (!_ownsCaptureGeneration(generation)) return;
      pendingError = e;
      pendingStackTrace = stackTrace;
      DebugLogger.warning(
        'Cookie capture failed',
        scope: 'auth/proxy',
        data: {'errorType': e.runtimeType.toString()},
      );
    } finally {
      if (_ownsCaptureGeneration(generation)) {
        nextRequest = _captureQueue.finish(
          completed: didComplete || _cookiesCaptured,
        );
      }
    }

    if (nextRequest != null &&
        !_cookiesCaptured &&
        _ownsCaptureGeneration(generation)) {
      await _requestProxyCookieCapture(nextRequest);
    }

    if (pendingError != null &&
        pendingStackTrace != null &&
        !_cookiesCaptured &&
        _ownsCaptureGeneration(generation)) {
      Error.throwWithStackTrace(pendingError, pendingStackTrace);
    }
  }

  Future<ProxyAuthCaptureRequest?> _buildAutomaticCaptureRequest(
    String url,
    int generation,
  ) async {
    if (!_ownsCaptureDocument(generation, url)) return null;
    final path = Uri.tryParse(url)?.path ?? '/';
    if (_automaticCaptureRequiresJwt) {
      return ProxyAuthCaptureRequest.automatic(
        shouldWaitForJwt: true,
        path: path,
      );
    }

    final currentPageShouldWait = await _shouldWaitForAutomaticProxyAuthCapture(
      path,
    );
    final shouldWaitForJwt = resolveProxyAuthJwtRequirement(
      ownsDocument: _ownsCaptureDocument(generation, url),
      hasPendingJwtWait: _automaticCaptureRequiresJwt,
      currentPageShouldWait: currentPageShouldWait,
    );
    if (shouldWaitForJwt == null) return null;
    if (shouldWaitForJwt) {
      _automaticCaptureRequiresJwt = true;
    }

    return ProxyAuthCaptureRequest.automatic(
      shouldWaitForJwt: shouldWaitForJwt,
      path: path,
    );
  }

  Future<bool> _shouldWaitForAutomaticProxyAuthCapture(String path) async {
    if (path.toLowerCase().contains('/oauth/')) {
      DebugLogger.auth(
        'Automatic proxy auth capture waiting for JWT on OAuth route',
        scope: 'auth/proxy',
      );
      return true;
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      final hasPasswordField = await _currentPageHasPasswordField();
      final shouldWait = shouldWaitForAutomaticProxyAuthCapture(
        path: path,
        hasPasswordField: hasPasswordField,
      );

      if (!shouldWait) {
        DebugLogger.auth(
          'Automatic proxy auth capture can complete without JWT',
          scope: 'auth/proxy',
        );
        return false;
      }

      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return false;
      }
    }

    DebugLogger.auth(
      'Automatic proxy auth capture waiting for JWT',
      scope: 'auth/proxy',
    );
    return true;
  }

  Future<bool> _currentPageHasPasswordField() async {
    final controller = _controller;
    if (controller == null || !mounted) return false;
    if (!await _isControllerOnTargetOrigin()) return false;

    try {
      final result = await controller.evaluateJavascript(
        source: '''
        (function() {
          return document.querySelector(
            'input[type="password"], input[name="password"], #password'
          ) !== null ? "true" : "false";
        })()
        ''',
      );

      if (!mounted || !await _isControllerOnTargetOrigin()) return false;
      return result.toString().contains('true');
    } catch (e) {
      DebugLogger.log(
        'Password field detection failed',
        scope: 'auth/proxy',
        data: {'errorType': e.runtimeType.toString()},
      );
      return false;
    }
  }

  Future<String?> _tryCaptureJwtTokenWithRetry() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final jwtToken = await _tryCaptureJwtToken();
      if (hasCapturedJwtToken(jwtToken)) {
        return jwtToken;
      }

      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return null;
      }
    }

    return null;
  }

  /// Attempts to capture the JWT token from cookies or localStorage.
  ///
  /// If the proxy uses trusted headers, OpenWebUI will have already
  /// authenticated the user and set a JWT token.
  Future<String?> _tryCaptureJwtToken() async {
    final controller = _controller;
    if (controller == null || !mounted) return null;
    if (!await _isControllerOnTargetOrigin()) return null;

    // Strategy 1: Check token cookie
    try {
      final cookieResult = await controller.evaluateJavascript(
        source: '''
        (function() {
          var cookies = document.cookie.split(";");
          for (var i = 0; i < cookies.length; i++) {
            var cookie = cookies[i].trim();
            if (cookie.startsWith("token=")) {
              return cookie.substring(6);
            }
          }
          return "";
        })()
        ''',
      );

      if (!mounted || !await _isControllerOnTargetOrigin()) return null;

      String tokenValue = _cleanJsString(cookieResult.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth(
          'Found JWT token in cookie - user already authenticated via '
          'trusted headers',
          scope: 'auth/proxy',
        );
        return tokenValue;
      }
    } catch (e) {
      DebugLogger.log(
        'Cookie JWT check failed',
        scope: 'auth/proxy',
        data: {'errorType': e.runtimeType.toString()},
      );
    }

    if (!mounted || !await _isControllerOnTargetOrigin()) return null;

    // Strategy 2: Check localStorage
    try {
      final result = await controller.evaluateJavascript(
        source: 'localStorage.getItem("token")',
      );

      if (!mounted || !await _isControllerOnTargetOrigin()) return null;

      String tokenValue = _cleanJsString(result.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth(
          'Found JWT token in localStorage - user already authenticated via '
          'trusted headers',
          scope: 'auth/proxy',
        );
        return tokenValue;
      }
    } catch (e) {
      DebugLogger.log(
        'localStorage JWT check failed',
        scope: 'auth/proxy',
        data: {'errorType': e.runtimeType.toString()},
      );
    }

    DebugLogger.auth(
      'No JWT token found - proxy may not use trusted headers, '
      'will proceed to normal sign-in',
      scope: 'auth/proxy',
    );
    return null;
  }

  Future<bool> _isControllerOnTargetOrigin() async {
    final controller = _controller;
    if (controller == null || !mounted) return false;

    try {
      final currentUrl = await controller.getUrl();
      return currentUrl != null &&
          isTrustedProxyCredentialCaptureUrl(
            pageUrl: currentUrl.toString(),
            serverUrl: widget.config.serverConfig.url,
          );
    } catch (error) {
      DebugLogger.log(
        'Unable to verify proxy WebView origin before credential capture',
        scope: 'auth/proxy',
        data: {'errorType': error.runtimeType.toString()},
      );
      return false;
    }
  }

  String _cleanJsString(String value) {
    if (value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  bool _isValidJwtFormat(String value) {
    if (value.isEmpty) return false;
    final trimmed = value.trim();
    if (trimmed == 'null' ||
        trimmed == 'undefined' ||
        trimmed == 'false' ||
        trimmed == 'true') {
      return false;
    }
    final segments = trimmed.split('.');
    return segments.length == 3 && trimmed.length >= 50;
  }

  void _onWebResourceError(WebResourceRequest request, WebResourceError error) {
    if (!mounted) return;
    DebugLogger.error(
      'proxy-webview-error',
      scope: 'auth/proxy',
      data: {
        'origin': webViewOriginForLog(request.url.toString()),
        'errorType': error.type.toString(),
      },
    );

    if (request.isForMainFrame ?? false) {
      setState(() {
        _error = error.description;
        _isLoading = false;
      });
    }
  }

  Future<NavigationActionPolicy?> _onNavigationRequest(
    InAppWebViewController controller,
    NavigationAction request,
  ) async {
    final url = request.request.url;
    DebugLogger.auth(
      'Proxy auth navigation request: ${webViewOriginForLog(url?.toString())}',
      scope: 'auth/proxy',
    );
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    // Invalidate in-flight cookie/JWT work before any reload await. Its
    // finally block must not finish or mutate the fresh queue.
    _invalidateCaptureQueue();

    try {
      await refreshProxyAuthWebView<InAppWebViewController>(
        controller: _controller,
        initialize: _initializeWebView,
        reload: (controller) async {
          if (!mounted) return;
          setState(() {
            _isLoading = true;
            _error = null;
            _cookiesCaptured = false;
            _isOnTargetServer = false;
          });
          _automaticCaptureRequiresJwt = false;

          if (!mounted) return;
          await controller.loadUrl(
            urlRequest: URLRequest(url: WebUri(widget.config.serverConfig.url)),
          );
        },
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'proxy-webview-refresh-load-failed',
        scope: 'auth/proxy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _error = 'The sign-in page could not be reloaded. Please retry.';
        _isLoading = false;
      });
    }
  }

  /// Manual completion button for when auto-detection doesn't work.
  Future<void> _manualComplete() async {
    try {
      await _requestProxyCookieCapture(const ProxyAuthCaptureRequest.manual());
    } catch (error, stackTrace) {
      DebugLogger.error(
        'manual-proxy-capture-failed',
        scope: 'auth/proxy',
        error: error,
        stackTrace: stackTrace,
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      setState(() {
        _error =
            'The proxy sign-in session could not be captured. '
            'Please retry or continue manually.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ErrorBoundary(
      child: AdaptiveRouteShell(
        backgroundColor: context.conduitTheme.surfaceBackground,
        extendBodyBehindAppBar: true,
        appBar: AdaptiveAppBar(
          title: l10n?.proxyAuthentication ?? 'Proxy Authentication',
          actions: [
            if (_controller != null)
              AdaptiveAppBarAction(
                iosSymbol: 'arrow.clockwise',
                icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
                onPressed: _refresh,
              ),
          ],
        ),
        bodySafeArea: true,
        body: _buildBody(l10n),
      ),
    );
  }

  Widget _buildBody(AppLocalizations? l10n) {
    if (_error != null) {
      return _buildErrorState(l10n);
    }

    if (!_shouldRenderWebView || !isWebViewSupported) {
      return _buildLoadingState(l10n);
    }

    return Stack(
      children: [
        InAppWebView(
          key: ValueKey<String>(widget.config.serverConfig.url),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            userAgent: _buildUserAgent(),
          ),
          onWebViewCreated: (controller) {
            if (mounted) {
              setState(() {
                _controller = controller;
              });
            } else {
              _controller = controller;
            }
            unawaited(_loadInitialServerPage(controller));
          },
          onLoadStart: (controller, url) {
            _onPageStarted(url?.toString() ?? '');
          },
          onLoadStop: (controller, url) async {
            final urlText = url?.toString();
            if (urlText == null || urlText.isEmpty) {
              return;
            }
            await _onPageFinished(urlText);
          },
          onReceivedError: (controller, request, error) {
            _onWebResourceError(request, error);
          },
          shouldOverrideUrlLoading: _onNavigationRequest,
        ),
        if (_isLoading) _buildLoadingOverlay(l10n),
        // Help text and manual continue button at the bottom
        Positioned(left: 0, right: 0, bottom: 0, child: _buildHelpBanner(l10n)),
      ],
    );
  }

  Widget _buildHelpBanner(AppLocalizations? l10n) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: context.conduitTheme.surfaceContainer.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: context.conduitTheme.dividerColor,
            width: BorderWidth.standard,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Platform.isIOS ? CupertinoIcons.info : Icons.info_outline,
                size: IconSize.small,
                color: context.conduitTheme.iconSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  l10n?.proxyAuthHelpTextSimple ??
                      'Sign in through your proxy. Once authenticated, '
                          'tap Continue to proceed to sign in.',
                  style: context.conduitTheme.bodySmall?.copyWith(
                    color: context.conduitTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          SizedBox(
            width: double.infinity,
            child: ConduitButton(
              text: l10n?.continueButton ?? 'Continue',
              icon: Platform.isIOS
                  ? CupertinoIcons.arrow_right
                  : Icons.arrow_forward,
              onPressed: _manualComplete,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState(AppLocalizations? l10n) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator.adaptive(),
          const SizedBox(height: Spacing.lg),
          Text(
            l10n?.proxyAuthLoading ?? 'Loading authentication page...',
            style: context.conduitTheme.bodyMedium?.copyWith(
              color: context.conduitTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay(AppLocalizations? l10n) {
    return Positioned.fill(
      child: Container(
        color: context.conduitTheme.surfaceBackground.withValues(alpha: 0.8),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator.adaptive(),
              const SizedBox(height: Spacing.lg),
              Text(
                l10n?.proxyAuthLoading ?? 'Loading...',
                style: context.conduitTheme.bodyMedium?.copyWith(
                  color: context.conduitTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(AppLocalizations? l10n) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.pagePadding),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Platform.isIOS
                  ? CupertinoIcons.exclamationmark_circle
                  : Icons.error_outline,
              size: IconSize.xxl,
              color: context.conduitTheme.error,
            ),
            const SizedBox(height: Spacing.lg),
            Text(
              l10n?.proxyAuthFailed ?? 'Authentication failed',
              style: context.conduitTheme.headingMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              _error ?? '',
              style: context.conduitTheme.bodyMedium?.copyWith(
                color: context.conduitTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.xl),
            ConduitButton(
              text: l10n?.retry ?? 'Retry',
              icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
              onPressed: _refresh,
            ),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              text: l10n?.back ?? 'Back',
              icon: Platform.isIOS ? CupertinoIcons.back : Icons.arrow_back,
              onPressed: () => context.pop(const ProxyAuthResult.failed()),
              isSecondary: true,
            ),
          ],
        ),
      ),
    );
  }
}
