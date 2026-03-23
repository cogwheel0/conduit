import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/auth/native_cookie_manager.dart';
import '../../../core/auth/webview_cookie_helper.dart';
import '../../../core/models/server_config.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'package:conduit/l10n/app_localizations.dart';

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

class _ProxyAuthPageState extends ConsumerState<ProxyAuthPage> {
  WebViewController? _controller;
  bool _isLoading = true;
  bool _cookiesCaptured = false;
  final _captureQueue = ProxyAuthCaptureQueue();
  bool _automaticCaptureRequiresJwt = false;
  String? _error;
  bool _isOnTargetServer = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initializeWebView();
    });
  }

  @override
  void dispose() {
    _controller = null;
    super.dispose();
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
    DebugLogger.auth('Initializing Proxy Auth WebView for $serverUrl');

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onWebResourceError: _onWebResourceError,
          onNavigationRequest: _onNavigationRequest,
        ),
      )
      ..setUserAgent(_buildUserAgent());

    // Don't clear cookies - preserve any existing proxy session
    if (!mounted) return;

    // Load the server URL - the proxy will intercept and show its login
    await controller.loadRequest(Uri.parse(serverUrl));

    if (!mounted) return;

    setState(() {
      _controller = controller;
    });
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
    DebugLogger.auth('Proxy auth page started: $url');
    setState(() {
      _isLoading = true;
      _error = null;
    });
  }

  Future<void> _onPageFinished(String url) async {
    if (!mounted) return;
    DebugLogger.auth('Proxy auth page finished: $url');

    setState(() {
      _isLoading = false;
    });

    if (_cookiesCaptured) return;

    final uri = Uri.parse(url);

    // Check for error parameter
    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      DebugLogger.auth('Proxy auth error from URL: $error');
      setState(() {
        _error = error;
      });
      return;
    }

    // Check if we're on our target server
    final serverUrl = widget.config.serverConfig.url;
    final serverUri = Uri.parse(serverUrl);
    if (uri.host == serverUri.host) {
      // We've reached our server - proxy auth must be complete
      _isOnTargetServer = true;
      await _checkIfOpenWebUI(url);
    }
  }

  /// Checks if we're on the OpenWebUI page and captures cookies if so.
  Future<void> _checkIfOpenWebUI(String url) async {
    if (_cookiesCaptured || !mounted) return;

    final controller = _controller;
    if (controller == null) return;

    try {
      // Check if this is an OpenWebUI page by looking for specific elements
      // or the /api/config endpoint being accessible
      final result = await controller.runJavaScriptReturningResult('''
        (function() {
          // Check for OpenWebUI specific elements or title
          var isOpenWebUI = 
            document.querySelector('div[class*="chat"]') !== null ||
            document.querySelector('[data-testid]') !== null ||
            document.title.toLowerCase().includes('open webui') ||
            document.title.toLowerCase().includes('chat');
          return isOpenWebUI ? "true" : "false";
        })()
        ''');

      if (!mounted) return;

      final isOpenWebUI = result.toString().contains('true');
      DebugLogger.auth(
        'OpenWebUI detection: $isOpenWebUI (on target server: $_isOnTargetServer)',
      );

      // If we're on the target server, capture cookies
      // The user might be on a login page or the main page
      if (_isOnTargetServer) {
        final request = await _buildAutomaticCaptureRequest(url);
        await _requestProxyCookieCapture(request);
      }
    } catch (e) {
      DebugLogger.log(
        'OpenWebUI detection failed: ${e.toString().split('\n').first}',
        scope: 'auth/proxy',
      );

      // If detection fails but we're on target server, still try to capture
      if (_isOnTargetServer) {
        try {
          final request = await _buildAutomaticCaptureRequest(url);
          await _requestProxyCookieCapture(request);
        } catch (captureError) {
          if (!mounted) return;
          setState(() {
            _error = captureError.toString();
          });
        }
      }
    }
  }

  /// Captures proxy session cookies and checks for JWT token.
  ///
  /// When oauth2-proxy uses trusted headers (like X-Forwarded-Email),
  /// OpenWebUI auto-authenticates the user after proxy auth. In this case,
  /// we can capture the JWT token and skip the sign-in page entirely.
  Future<void> _requestProxyCookieCapture(
    ProxyAuthCaptureRequest request,
  ) async {
    if (_cookiesCaptured || !mounted) return;

    final captureRequest = _captureQueue.begin(request);
    if (captureRequest == null) return;

    await _captureProxyCookies(captureRequest);
  }

  Future<void> _captureProxyCookies(ProxyAuthCaptureRequest request) async {
    if (_cookiesCaptured || !mounted) return;

    var didComplete = false;
    Object? pendingError;
    StackTrace? pendingStackTrace;
    ProxyAuthCaptureRequest? nextRequest;

    try {
      final serverUrl = widget.config.serverConfig.url;
      DebugLogger.auth('Capturing proxy cookies for $serverUrl');

      // Get cookies from native cookie store
      final cookies = await NativeCookieManager.getCookiesForUrl(serverUrl);

      if (!mounted) return;

      DebugLogger.auth(
        'Captured ${cookies.length} cookies: ${cookies.keys.toList()}',
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
      final decision = decideProxyAuthCapture(
        activeRequest: request,
        queuedRequest: _captureQueue.queuedRequest,
        jwtToken: jwtToken,
      );

      switch (decision) {
        case ProxyAuthCaptureDecision.deferToQueuedRequest:
          DebugLogger.auth(
            'Deferring proxy auth completion to a newer queued request',
          );
          break;
        case ProxyAuthCaptureDecision.waitForJwt:
          DebugLogger.auth(
            'JWT token not available yet - keeping proxy auth page open',
          );
          break;
        case ProxyAuthCaptureDecision.complete:
          if (!mounted) return;

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
      pendingError = e;
      pendingStackTrace = stackTrace;
      DebugLogger.warning('Cookie capture failed: $e', scope: 'auth/proxy');
    } finally {
      nextRequest = _captureQueue.finish(
        completed: didComplete || _cookiesCaptured,
      );
    }

    if (nextRequest != null && !_cookiesCaptured && mounted) {
      await _requestProxyCookieCapture(nextRequest);
    }

    if (pendingError != null &&
        pendingStackTrace != null &&
        !_cookiesCaptured) {
      Error.throwWithStackTrace(pendingError, pendingStackTrace);
    }
  }

  Future<ProxyAuthCaptureRequest> _buildAutomaticCaptureRequest(
    String url,
  ) async {
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
    final shouldWaitForJwt = shouldRequireJwtForAutomaticCapture(
      hasPendingJwtWait: _automaticCaptureRequiresJwt,
      currentPageShouldWait: currentPageShouldWait,
    );
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
        'Automatic proxy auth capture waiting for JWT on OAuth route: $path',
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
          'Automatic proxy auth capture can complete without JWT on $path',
        );
        return false;
      }

      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted) return false;
      }
    }

    DebugLogger.auth('Automatic proxy auth capture waiting for JWT on $path');
    return true;
  }

  Future<bool> _currentPageHasPasswordField() async {
    final controller = _controller;
    if (controller == null || !mounted) return false;

    try {
      final result = await controller.runJavaScriptReturningResult('''
        (function() {
          return document.querySelector(
            'input[type="password"], input[name="password"], #password'
          ) !== null ? "true" : "false";
        })()
        ''');

      if (!mounted) return false;
      return result.toString().contains('true');
    } catch (e) {
      DebugLogger.log(
        'Password field detection failed: ${e.toString().split('\n').first}',
        scope: 'auth/proxy',
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

    // Strategy 1: Check token cookie
    try {
      final cookieResult = await controller.runJavaScriptReturningResult('''
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
        ''');

      if (!mounted) return null;

      String tokenValue = _cleanJsString(cookieResult.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth(
          'Found JWT token in cookie - user already authenticated via '
          'trusted headers',
        );
        return tokenValue;
      }
    } catch (e) {
      DebugLogger.log(
        'Cookie JWT check failed: ${e.toString().split('\n').first}',
        scope: 'auth/proxy',
      );
    }

    if (!mounted) return null;

    // Strategy 2: Check localStorage
    try {
      final result = await controller.runJavaScriptReturningResult(
        'localStorage.getItem("token")',
      );

      if (!mounted) return null;

      String tokenValue = _cleanJsString(result.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth(
          'Found JWT token in localStorage - user already authenticated via '
          'trusted headers',
        );
        return tokenValue;
      }
    } catch (e) {
      DebugLogger.log(
        'localStorage JWT check failed: ${e.toString().split('\n').first}',
        scope: 'auth/proxy',
      );
    }

    DebugLogger.auth(
      'No JWT token found - proxy may not use trusted headers, '
      'will proceed to normal sign-in',
    );
    return null;
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

  void _onWebResourceError(WebResourceError error) {
    if (!mounted) return;
    DebugLogger.error(
      'proxy-webview-error',
      scope: 'auth/proxy',
      data: {
        'errorCode': error.errorCode,
        'description': error.description,
        'errorType': error.errorType?.name,
      },
    );

    if (error.isForMainFrame ?? false) {
      setState(() {
        _error = error.description;
        _isLoading = false;
      });
    }
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final url = request.url;
    DebugLogger.auth('Proxy auth navigation request: $url');
    return NavigationDecision.navigate;
  }

  Future<void> _refresh() async {
    final controller = _controller;
    if (controller == null || !mounted) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _cookiesCaptured = false;
      _isOnTargetServer = false;
    });
    _captureQueue.reset();
    _automaticCaptureRequiresJwt = false;

    if (!mounted) return;

    await controller.loadRequest(Uri.parse(widget.config.serverConfig.url));
  }

  /// Manual completion button for when auto-detection doesn't work.
  Future<void> _manualComplete() async {
    try {
      await _requestProxyCookieCapture(const ProxyAuthCaptureRequest.manual());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ErrorBoundary(
      child: Scaffold(
        backgroundColor: context.conduitTheme.surfaceBackground,
        extendBodyBehindAppBar: true,
        appBar: FloatingAppBar(
          leading: FloatingAppBarBackButton(
            onTap: () => context.pop(const ProxyAuthResult.failed()),
          ),
          title: FloatingAppBarTitle(
            text: l10n?.proxyAuthentication ?? 'Proxy Authentication',
          ),
          actions: [
            if (_controller != null)
              FloatingAppBarAction(
                child: FloatingAppBarIconButton(
                  icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
                  onTap: _refresh,
                ),
              ),
          ],
        ),
        body: SafeArea(child: _buildBody(l10n)),
      ),
    );
  }

  Widget _buildBody(AppLocalizations? l10n) {
    if (_error != null) {
      return _buildErrorState(l10n);
    }

    if (_controller == null || !isWebViewSupported) {
      return _buildLoadingState(l10n);
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
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
