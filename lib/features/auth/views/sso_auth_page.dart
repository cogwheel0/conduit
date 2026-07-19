import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/webview_cookie_helper.dart';
import '../../../core/auth/webview_origin.dart';
import '../../../core/models/server_config.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../providers/unified_auth_providers.dart';

/// Whether an SSO page is allowed to expose cookies or localStorage tokens.
@visibleForTesting
bool isTrustedSsoTokenCaptureUrl({
  required String pageUrl,
  required String serverUrl,
}) => webViewUrlHasExactServerOrigin(pageUrl, serverUrl);

@visibleForTesting
bool isExpectedSsoRefreshLoadStart({
  required String startedUrl,
  required String expectedUrl,
}) {
  final started = Uri.tryParse(startedUrl);
  final expected = Uri.tryParse(expectedUrl);
  return started != null &&
      expected != null &&
      started.path == expected.path &&
      webViewUrlHasExactServerOrigin(startedUrl, expectedUrl);
}

/// Runs the retry path appropriate for the current WebView lifecycle.
///
/// Cleanup failures happen before a controller is created, so retry must run
/// full initialization again. Existing WebViews retain the cheaper reload
/// path and clear their current sign-in cookies first.
@visibleForTesting
Future<void> refreshSsoAuthWebView<Controller>({
  required Controller? controller,
  required Future<void> Function() initialize,
  required Future<void> Function(
    Controller controller,
    void Function() releaseSessionReset,
  )
  reload,
  required void Function(bool inProgress) setSessionResetInProgress,
}) async {
  // This callback is intentionally synchronous before the first await. Token
  // capture callbacks from the outgoing document must be fenced before cookie
  // clearing begins, and remain fenced until replacement loading has started.
  setSessionResetInProgress(true);
  var resetReleased = false;
  void releaseSessionReset() {
    if (resetReleased) return;
    resetReleased = true;
    setSessionResetInProgress(false);
  }

  try {
    if (controller == null) {
      await initialize();
      releaseSessionReset();
      return;
    }
    await reload(controller, releaseSessionReset);
  } catch (_) {
    releaseSessionReset();
    rethrow;
  }
}

@visibleForTesting
Future<bool> prepareFreshSsoWebViewSession({
  Future<bool> Function()? clearCookies,
  Future<bool> Function()? clearWebsiteData,
}) async {
  final cookiesCleared =
      await (clearCookies ?? WebViewCookieHelper.clearCookies)();
  final websiteDataCleared =
      await (clearWebsiteData ?? WebViewCookieHelper.clearWebsiteData)();
  return cookiesCleared && websiteDataCleared;
}

/// Claims a new refresh generation unless token handling already owns the flow.
@visibleForTesting
int? nextSsoAuthRefreshGeneration({
  required bool tokenCaptureStarted,
  required bool sessionResetInProgress,
  required int currentGeneration,
}) => tokenCaptureStarted || sessionResetInProgress
    ? null
    : currentGeneration + 1;

/// SSO Authentication page that uses a WebView to handle OAuth/OIDC flows.
///
/// This page loads the Open-WebUI `/auth` page in a WebView, allowing users
/// to authenticate via configured OAuth providers (Google, Microsoft, GitHub,
/// OIDC, etc.). After successful authentication, the JWT token is captured
/// from cookies or localStorage and used to authenticate in Conduit.
class SsoAuthPage extends ConsumerStatefulWidget {
  final ServerConfig? serverConfig;

  const SsoAuthPage({super.key, this.serverConfig});

  @override
  ConsumerState<SsoAuthPage> createState() => _SsoAuthPageState();
}

class _SsoAuthPageState extends ConsumerState<SsoAuthPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  bool _tokenCaptured = false;
  String? _error;
  String? _serverUrl;
  ServerConfig? _ssoServerConfig;
  int _captureAttemptId = 0; // Used to cancel stale retry sequences
  bool _sessionResetInProgress = false;
  String? _expectedReplacementLoadUrl;
  VoidCallback? _releasePendingSessionReset;
  bool _shouldRenderWebView = false;

  @override
  void initState() {
    super.initState();
    // Defer initialization to after first frame to ensure context is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initializeWebView();
    });
  }

  @override
  void dispose() {
    // Increment attempt ID to cancel any in-flight token capture operations
    _captureAttemptId++;
    _cancelPendingSessionReset();
    // Clear controller reference (WebViewController doesn't have a dispose method,
    // but setting to null ensures callbacks check mounted state)
    _controller = null;
    super.dispose();
  }

  Future<void> _initializeWebView() async {
    // Check platform support first - auth WebViews are mobile-only here.
    if (!isWebViewSupported) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _error =
            l10n?.ssoPlatformNotSupported ??
            'SSO authentication is not supported on this platform. '
                'Please use credentials or LDAP authentication instead.';
        _isLoading = false;
      });
      return;
    }

    // Get server URL from config or active server
    final config = widget.serverConfig;
    if (config != null) {
      _ssoServerConfig = config;
      _serverUrl = config.url;
    } else {
      final activeServer = await ref.read(activeServerProvider.future);
      if (!mounted) return;
      _ssoServerConfig = activeServer;
      _serverUrl = activeServer?.url;
    }

    if (_serverUrl == null) {
      if (!mounted) return;
      setState(() {
        _error = 'No server configured';
        _isLoading = false;
      });
      return;
    }

    DebugLogger.auth(
      'Initializing SSO WebView for ${webViewOriginForLog(_serverUrl)}',
      scope: 'auth/sso',
    );

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

    // Clear cookies before loading to ensure a fresh identity boundary. A real
    // platform failure blocks this WebView; an already-empty store verifies as
    // success in WebViewCookieHelper.
    final cookiesCleared = await prepareFreshSsoWebViewSession();

    if (!mounted) return;
    if (!cookiesCleared) {
      setState(() {
        _error = 'The previous SSO session could not be cleared. Please retry.';
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
      _tokenCaptured = false;
    });
  }

  Future<void> _loadInitialAuthPage(InAppWebViewController controller) async {
    final serverUrl = _serverUrl;
    if (serverUrl == null) {
      return;
    }

    try {
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('$serverUrl/auth')),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'sso-webview-initial-load-failed',
        scope: 'auth/sso',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _error = 'The SSO sign-in page could not be loaded. Please retry.';
        _isLoading = false;
      });
    }
  }

  String _buildUserAgent() {
    // Use a standard mobile browser user agent to ensure OAuth providers work correctly
    // Note: auth WebViews are only enabled on iOS and Android here.
    if (!kIsWeb && Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    } else {
      // Android (or fallback) - use mobile Chrome
      return 'Mozilla/5.0 (Linux; Android 14) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }
  }

  void _onPageStarted(String url) {
    DebugLogger.auth(
      'SSO page started: ${webViewOriginForLog(url)}',
      scope: 'auth/sso',
    );
    final expectedUrl = _expectedReplacementLoadUrl;
    if (expectedUrl != null &&
        isExpectedSsoRefreshLoadStart(
          startedUrl: url,
          expectedUrl: expectedUrl,
        )) {
      _cancelPendingSessionReset();
    }
    // Increment attempt ID to cancel any in-progress retry sequences
    _captureAttemptId++;
    setState(() {
      _isLoading = true;
      _error = null;
    });
  }

  /// Called when URL changes (may catch changes that onPageFinished misses)
  Future<void> _onUrlChange(WebUri? url) async {
    final urlText = url?.toString();
    if (urlText == null || urlText.isEmpty) return;
    DebugLogger.auth(
      'SSO URL changed: ${webViewOriginForLog(urlText)}',
      scope: 'auth/sso',
    );

    // Try to capture token on URL change as well
    if (_tokenCaptured || _sessionResetInProgress) return;

    final serverUrl = _serverUrl;
    if (serverUrl == null) return;
    if (!isTrustedSsoTokenCaptureUrl(pageUrl: urlText, serverUrl: serverUrl)) {
      return;
    }

    final uri = Uri.parse(urlText);

    // Attempt single token capture (no retry) - onPageFinished will handle retries
    // This provides fast capture when URL changes, while onPageFinished
    // provides the retry mechanism as a fallback
    await _attemptTokenCapture(uri, attemptId: _captureAttemptId);
  }

  Future<void> _onPageFinished(String url) async {
    DebugLogger.auth(
      'SSO page finished: ${webViewOriginForLog(url)}',
      scope: 'auth/sso',
    );

    if (_sessionResetInProgress) return;

    setState(() {
      _isLoading = false;
    });

    if (_tokenCaptured) return;

    final uri = Uri.parse(url);

    // Check for error parameter (OAuth failures redirect with ?error=...)
    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      DebugLogger.auth(
        'SSO callback reported an OAuth error',
        scope: 'auth/sso',
      );
      setState(() {
        _error = error;
      });
      return;
    }

    // Check if this is a page on our server where a token might be present
    // After OAuth, Open-WebUI may redirect to:
    // - /auth (login page with token in cookie)
    // - / (root/chat page after successful auth)
    // - /api/v1/auths/callback/* (OAuth callback that sets the token)
    // We should check for tokens on any page on our server after OAuth completes
    final serverUrl = _serverUrl;
    if (serverUrl == null) return;

    if (!isTrustedSsoTokenCaptureUrl(pageUrl: url, serverUrl: serverUrl)) {
      return;
    }

    // Skip external OAuth provider pages (they won't have our token)
    // Only check pages that could have the token set
    final isAuthRelatedPath =
        uri.path == '/' ||
        uri.path.endsWith('/auth') ||
        uri.path.contains('/callback') ||
        uri.path.contains('/oauth');

    if (!isAuthRelatedPath) {
      // For other pages on our server (like /chat), still try to capture
      // the token since the user might have been redirected there after auth
      DebugLogger.auth(
        'Checking for token on configured server page',
        scope: 'auth/sso',
      );
    }

    // Wait a moment for the frontend to persist the token
    // The OAuth callback sets the cookie, then redirects to /auth or /,
    // where the frontend reads the cookie and stores it in localStorage
    final attemptId = _captureAttemptId;
    await _attemptTokenCaptureWithRetry(uri, attemptId: attemptId);
  }

  /// Attempt token capture with retries to handle timing issues.
  ///
  /// The Open-WebUI frontend needs a moment to read the token cookie
  /// and store it in localStorage after the OAuth redirect.
  ///
  /// [attemptId] is used to cancel this retry sequence if a new page load starts.
  Future<void> _attemptTokenCaptureWithRetry(
    Uri uri, {
    required int attemptId,
    int maxAttempts = 3,
  }) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      // Cancel if token captured, widget disposed, or a new page load started
      if (_tokenCaptured ||
          _sessionResetInProgress ||
          !mounted ||
          attemptId != _captureAttemptId) {
        return;
      }

      // Small delay to let frontend persist token (except on first attempt)
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 500));
        // Re-check after delay in case state changed
        if (_tokenCaptured ||
            _sessionResetInProgress ||
            !mounted ||
            attemptId != _captureAttemptId) {
          return;
        }
      }

      final found = await _attemptTokenCapture(uri, attemptId: attemptId);
      if (found) return;
    }

    // After all attempts, token not found - user may still be in auth flow
    // Only log if this is still the current attempt sequence
    if (!_sessionResetInProgress && attemptId == _captureAttemptId) {
      DebugLogger.auth(
        'No token found after $maxAttempts attempts, user may still be authenticating',
        scope: 'auth/sso',
      );
    }
  }

  /// Attempts to capture the authentication token from cookies or localStorage.
  ///
  /// Returns true if a token was found and handled, false otherwise.
  /// [attemptId] is checked to abort if a new page load started.
  Future<bool> _attemptTokenCapture(Uri uri, {required int attemptId}) async {
    final controller = _controller;
    final serverUrl = _serverUrl;
    if (controller == null ||
        serverUrl == null ||
        !mounted ||
        _sessionResetInProgress) {
      return false;
    }

    // Abort if a new page load started
    if (attemptId != _captureAttemptId) return false;
    if (!isTrustedSsoTokenCaptureUrl(
          pageUrl: uri.toString(),
          serverUrl: serverUrl,
        ) ||
        !await _captureAttemptOwnsTrustedOrigin(attemptId)) {
      return false;
    }

    // Strategy 1: Check token cookie via JavaScript
    // Open-WebUI sets the token cookie with httponly=False, so it's accessible
    try {
      final cookieResult = await controller.evaluateJavascript(
        source:
            '(function() {'
            '  var cookies = document.cookie.split(";");'
            '  for (var i = 0; i < cookies.length; i++) {'
            '    var cookie = cookies[i].trim();'
            '    if (cookie.startsWith("token=")) {'
            '      return cookie.substring(6);'
            '    }'
            '  }'
            '  return "";'
            '})()',
      );

      // Abort if widget disposed or new page load started
      if (!await _captureAttemptOwnsTrustedOrigin(attemptId)) {
        return false;
      }

      String tokenValue = _cleanJsString(cookieResult.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth('Found valid token in cookie', scope: 'auth/sso');
        await _handleToken(tokenValue);
        return true;
      }
    } catch (e) {
      // Expected during page load - token may not be accessible yet
      DebugLogger.log(
        'Cookie read failed during auth flow',
        scope: 'auth/sso',
        data: {'errorType': e.runtimeType.toString()},
      );
    }

    // Abort if widget disposed or new page load started
    if (!await _captureAttemptOwnsTrustedOrigin(attemptId)) {
      return false;
    }

    // Strategy 2: Check localStorage (fallback - frontend sets this)
    try {
      final result = await controller.evaluateJavascript(
        source: 'localStorage.getItem("token")',
      );

      // Abort if widget disposed or new page load started
      if (!await _captureAttemptOwnsTrustedOrigin(attemptId)) {
        return false;
      }

      String tokenValue = _cleanJsString(result.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth(
          'Found valid token in localStorage',
          scope: 'auth/sso',
        );
        await _handleToken(tokenValue);
        return true;
      }
    } catch (e) {
      // Expected during page load - token may not be accessible yet
      DebugLogger.log(
        'localStorage read failed during auth flow',
        scope: 'auth/sso',
        data: {'errorType': e.runtimeType.toString()},
      );
    }

    return false;
  }

  Future<bool> _captureAttemptOwnsTrustedOrigin(int attemptId) async {
    if (!mounted || _sessionResetInProgress || attemptId != _captureAttemptId) {
      return false;
    }
    final isTrusted = await _isControllerOnTrustedOrigin();
    return isTrusted &&
        mounted &&
        !_sessionResetInProgress &&
        attemptId == _captureAttemptId;
  }

  Future<bool> _isControllerOnTrustedOrigin() async {
    final controller = _controller;
    final serverUrl = _serverUrl;
    if (controller == null || serverUrl == null || !mounted) return false;

    try {
      final currentUrl = await controller.getUrl();
      return currentUrl != null &&
          isTrustedSsoTokenCaptureUrl(
            pageUrl: currentUrl.toString(),
            serverUrl: serverUrl,
          );
    } catch (error) {
      DebugLogger.log(
        'Unable to verify SSO WebView origin before token capture',
        scope: 'auth/sso',
        data: {'errorType': error.runtimeType.toString()},
      );
      return false;
    }
  }

  /// Clean JavaScript string result by removing surrounding quotes
  String _cleanJsString(String value) {
    if (value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  /// Check if a string looks like a valid JWT token.
  ///
  /// JWT tokens have 3 dot-separated segments and are typically 100+ chars.
  /// This filters out invalid values like 'null', 'undefined', empty strings,
  /// or placeholder values that might be in localStorage before OAuth completes.
  bool _isValidJwtFormat(String value) {
    if (value.isEmpty) return false;
    final trimmed = value.trim();
    // Filter out common invalid values
    if (trimmed == 'null' ||
        trimmed == 'undefined' ||
        trimmed == 'false' ||
        trimmed == 'true') {
      return false;
    }
    // JWT must have 3 segments and be reasonably long
    final segments = trimmed.split('.');
    return segments.length == 3 && trimmed.length >= 50;
  }

  Future<void> _handleToken(String token) async {
    if (_tokenCaptured || !mounted || _sessionResetInProgress) return;

    final trimmedToken = token.trim();
    DebugLogger.auth('Handling captured SSO token', scope: 'auth/sso');
    _tokenCaptured = true;

    setState(() {
      _isLoading = true;
    });

    // Capture localized error message before async gap
    final ssoFailedMessage =
        AppLocalizations.of(context)?.ssoAuthFailed ??
        'SSO authentication failed';

    try {
      final authActions = ref.read(authActionsProvider);
      final success = await authActions.loginWithApiKey(
        trimmedToken,
        rememberCredentials: true,
        authType: 'sso', // Mark as SSO-obtained token for traceability
        expectedServerConfig: _ssoServerConfig,
      );

      if (!mounted) return;

      if (success) {
        DebugLogger.auth('SSO login successful', scope: 'auth/sso');
        // Navigation is handled automatically by the router when auth state
        // changes to authenticated. The router redirect will navigate to chat.
        // We don't need to call context.go() here - it can cause race conditions.
      } else {
        setState(() {
          _error = ssoFailedMessage;
          _isLoading = false;
          _tokenCaptured = false;
        });
      }
    } catch (e) {
      DebugLogger.error(
        'sso-token-handling-failed',
        scope: 'auth/sso',
        data: {'errorType': e.runtimeType.toString()},
      );
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
        _tokenCaptured = false;
      });
    }
  }

  void _onWebResourceError(WebResourceRequest request, WebResourceError error) {
    DebugLogger.error(
      'sso-webview-error',
      scope: 'auth/sso',
      data: {
        'origin': webViewOriginForLog(request.url.toString()),
        'errorType': error.type.toString(),
      },
    );

    // Only show error for main frame failures
    if (request.isForMainFrame ?? false) {
      _cancelPendingSessionReset();
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
      'SSO navigation request: ${webViewOriginForLog(url?.toString())}',
      scope: 'auth/sso',
    );

    // Allow all navigation - OAuth flows require redirects to external
    // identity providers and back. Credential reads are separately bound to
    // the configured Open WebUI scheme, host, and effective port.
    //
    // We log only the origin for debugging but don't restrict navigation since:
    // 1. OAuth providers may use various redirect URLs
    // 2. The user initiated this flow intentionally
    // 3. Token capture only happens on the configured server origin
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final refreshGeneration = nextSsoAuthRefreshGeneration(
      tokenCaptureStarted: _tokenCaptured,
      sessionResetInProgress: _sessionResetInProgress,
      currentGeneration: _captureAttemptId,
    );
    if (refreshGeneration == null) return;

    // Fence cookie/localStorage reads synchronously, before cookie clearing or
    // WebView initialization yields. Stale captures cannot resume into the new
    // sign-in session after either await below.
    _captureAttemptId = refreshGeneration;

    try {
      await refreshSsoAuthWebView<InAppWebViewController>(
        controller: _controller,
        initialize: _initializeWebView,
        setSessionResetInProgress: (inProgress) {
          _sessionResetInProgress = inProgress;
        },
        reload: (controller, releaseSessionReset) async {
          final serverUrl = _serverUrl;
          if (serverUrl == null || !mounted) {
            releaseSessionReset();
            return;
          }

          setState(() {
            _isLoading = true;
            _error = null;
            _tokenCaptured = false;
          });

          final cookiesCleared = await prepareFreshSsoWebViewSession();
          if (!mounted) {
            releaseSessionReset();
            return;
          }
          if (!cookiesCleared) {
            setState(() {
              _error =
                  'The previous SSO session could not be cleared. Please retry.';
              _isLoading = false;
            });
            releaseSessionReset();
            return;
          }

          final replacementUrl = '$serverUrl/auth';
          _expectedReplacementLoadUrl = replacementUrl;
          _releasePendingSessionReset = releaseSessionReset;
          try {
            await controller.loadUrl(
              urlRequest: URLRequest(url: WebUri(replacementUrl)),
            );
          } catch (_) {
            _cancelPendingSessionReset();
            rethrow;
          }
        },
      );
    } catch (error, stackTrace) {
      // The helper releases its reset lease on every failure path. Clear the
      // page-owned callback as well so a failed load can neither strand the
      // refresh fence nor leave the loading overlay permanently visible.
      _cancelPendingSessionReset();
      DebugLogger.error(
        'sso-webview-refresh-load-failed',
        scope: 'auth/sso',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _error = 'The SSO sign-in page could not be reloaded. Please retry.';
        _isLoading = false;
      });
    }
  }

  void _cancelPendingSessionReset() {
    final release = _releasePendingSessionReset;
    _releasePendingSessionReset = null;
    _expectedReplacementLoadUrl = null;
    release?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ErrorBoundary(
      child: AdaptiveRouteShell(
        backgroundColor: context.conduitTheme.surfaceBackground,
        extendBodyBehindAppBar: true,
        appBar: AdaptiveAppBar(
          title: l10n?.sso ?? 'SSO',
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

    // Guard against rendering WebView on unsupported platforms.
    if (!_shouldRenderWebView || !isWebViewSupported) {
      return _buildLoadingState(l10n);
    }

    return Stack(
      children: [
        InAppWebView(
          key: ValueKey<String?>(_serverUrl),
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
            unawaited(_loadInitialAuthPage(controller));
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
          onUpdateVisitedHistory: (controller, url, _) async {
            await _onUrlChange(url);
          },
          shouldOverrideUrlLoading: _onNavigationRequest,
        ),
        if (_isLoading) _buildLoadingOverlay(l10n),
      ],
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
            l10n?.ssoLoadingLogin ?? 'Loading login page...',
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
                _tokenCaptured
                    ? (l10n?.ssoAuthenticating ?? 'Authenticating...')
                    : (l10n?.ssoLoadingLogin ?? 'Loading...'),
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
              l10n?.ssoAuthFailed ?? 'SSO authentication failed',
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
              onPressed: () => context.pop(),
              isSecondary: true,
            ),
          ],
        ),
      ),
    );
  }
}
