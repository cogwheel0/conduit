import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter_plus/webview_flutter_plus.dart';

import '../../../core/auth/webview_cookie_helper.dart';
import '../../../core/models/server_config.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../providers/unified_auth_providers.dart';

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
  WebViewControllerPlus? _controller;
  bool _isLoading = true;
  bool _tokenCaptured = false;
  String? _error;
  String? _serverUrl;
  int _captureAttemptId = 0; // Used to cancel stale retry sequences

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
      _serverUrl = config.url;
    } else {
      final activeServer = await ref.read(activeServerProvider.future);
      if (!mounted) return;
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

    DebugLogger.auth('Initializing SSO WebView for $_serverUrl');

    final controller = WebViewControllerPlus()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onWebResourceError: _onWebResourceError,
          onNavigationRequest: _onNavigationRequest,
          onUrlChange: _onUrlChange,
        ),
      )
      ..setUserAgent(_buildUserAgent());

    // Clear cookies before loading to ensure fresh session
    if (isWebViewSupported) {
      await WebViewCookieManager().clearCookies();
    }

    if (!mounted) return;

    // Load the auth page
    await controller.loadRequest(Uri.parse('$_serverUrl/auth'));

    if (!mounted) return;

    setState(() {
      _controller = controller;
    });
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
    DebugLogger.auth('SSO page started: $url');
    // Increment attempt ID to cancel any in-progress retry sequences
    _captureAttemptId++;
    setState(() {
      _isLoading = true;
      _error = null;
    });
  }

  /// Called when URL changes (may catch changes that onPageFinished misses)
  Future<void> _onUrlChange(UrlChange change) async {
    final url = change.url;
    if (url == null) return;
    DebugLogger.auth('SSO URL changed: $url');

    // Try to capture token on URL change as well
    if (_tokenCaptured) return;

    final uri = Uri.parse(url);
    final serverUrl = _serverUrl;
    if (serverUrl == null) return;

    final serverUri = Uri.parse(serverUrl);
    if (uri.host != serverUri.host) return;

    // Attempt single token capture (no retry) - onPageFinished will handle retries
    // This provides fast capture when URL changes, while onPageFinished
    // provides the retry mechanism as a fallback
    await _attemptTokenCapture(uri, attemptId: _captureAttemptId);
  }

  Future<void> _onPageFinished(String url) async {
    DebugLogger.auth('SSO page finished: $url');

    setState(() {
      _isLoading = false;
    });

    if (_tokenCaptured) return;

    final uri = Uri.parse(url);

    // Check for error parameter (OAuth failures redirect with ?error=...)
    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      DebugLogger.auth('SSO error from URL: $error');
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

    final serverUri = Uri.parse(serverUrl);
    final isOurServer = uri.host == serverUri.host;
    if (!isOurServer) return;

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
      DebugLogger.auth('Checking for token on ${uri.path}');
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
      if (_tokenCaptured || !mounted || attemptId != _captureAttemptId) return;

      // Small delay to let frontend persist token (except on first attempt)
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 500));
        // Re-check after delay in case state changed
        if (_tokenCaptured || !mounted || attemptId != _captureAttemptId) {
          return;
        }
      }

      final found = await _attemptTokenCapture(uri, attemptId: attemptId);
      if (found) return;
    }

    // After all attempts, token not found - user may still be in auth flow
    // Only log if this is still the current attempt sequence
    if (attemptId == _captureAttemptId) {
      DebugLogger.auth(
        'No token found after $maxAttempts attempts, user may still be authenticating',
      );
    }
  }

  /// Attempts to capture the authentication token from cookies or localStorage.
  ///
  /// Returns true if a token was found and handled, false otherwise.
  /// [attemptId] is checked to abort if a new page load started.
  Future<bool> _attemptTokenCapture(Uri uri, {required int attemptId}) async {
    final controller = _controller;
    if (controller == null || !mounted) return false;

    // Abort if a new page load started
    if (attemptId != _captureAttemptId) return false;

    // Strategy 1: Check token cookie via JavaScript
    // Open-WebUI sets the token cookie with httponly=False, so it's accessible
    try {
      final cookieResult = await controller.runJavaScriptReturningResult(
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
      if (!mounted || attemptId != _captureAttemptId) return false;

      String tokenValue = _cleanJsString(cookieResult.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth('Found valid token in cookie');
        await _handleToken(tokenValue);
        return true;
      }
    } catch (e) {
      // Expected during page load - token may not be accessible yet
      DebugLogger.log(
        'Cookie read failed (expected during auth flow): ${e.toString().split('\n').first}',
        scope: 'auth/sso',
      );
    }

    // Abort if widget disposed or new page load started
    if (!mounted || attemptId != _captureAttemptId) return false;

    // Strategy 2: Check localStorage (fallback - frontend sets this)
    try {
      final result = await controller.runJavaScriptReturningResult(
        'localStorage.getItem("token")',
      );

      // Abort if widget disposed or new page load started
      if (!mounted || attemptId != _captureAttemptId) return false;

      String tokenValue = _cleanJsString(result.toString());
      if (_isValidJwtFormat(tokenValue)) {
        DebugLogger.auth('Found valid token in localStorage');
        await _handleToken(tokenValue);
        return true;
      }
    } catch (e) {
      // Expected during page load - token may not be accessible yet
      DebugLogger.log(
        'localStorage read failed (expected during auth flow): ${e.toString().split('\n').first}',
        scope: 'auth/sso',
      );
    }

    return false;
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
    if (_tokenCaptured || !mounted) return;

    final trimmedToken = token.trim();
    DebugLogger.auth('Handling captured SSO token');
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
      );

      if (!mounted) return;

      if (success) {
        DebugLogger.auth('SSO login successful');
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
        error: e,
      );
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
        _tokenCaptured = false;
      });
    }
  }

  void _onWebResourceError(WebResourceError error) {
    DebugLogger.error(
      'sso-webview-error',
      scope: 'auth/sso',
      data: {
        'errorCode': error.errorCode,
        'description': error.description,
        'errorType': error.errorType?.name,
      },
    );

    // Only show error for main frame failures
    if (error.isForMainFrame ?? false) {
      setState(() {
        _error = error.description;
        _isLoading = false;
      });
    }
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final url = request.url;
    DebugLogger.auth('SSO navigation request: $url');

    // Allow all navigation - OAuth flows require redirects to external
    // identity providers and back. The WebView is sandboxed and the token
    // is only captured when the user returns to the Open-WebUI /auth page.
    //
    // We log the URL for debugging but don't restrict navigation since:
    // 1. OAuth providers may use various redirect URLs
    // 2. The user initiated this flow intentionally
    // 3. Token capture only happens on the configured server's /auth page
    return NavigationDecision.navigate;
  }

  Future<void> _refresh() async {
    final controller = _controller;
    if (controller == null || _serverUrl == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _tokenCaptured = false;
    });

    // Clear cookies and reload (with platform guard)
    if (isWebViewSupported) {
      await WebViewCookieManager().clearCookies();
    }

    if (!mounted) return;

    await controller.loadRequest(Uri.parse('$_serverUrl/auth'));
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

    // Guard against rendering WebView on unsupported platforms
    if (_controller == null || !isWebViewSupported) {
      return _buildLoadingState(l10n);
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
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
