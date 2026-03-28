import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../../../shared/widgets/qonduit_components.dart';
import 'package:qonduit/l10n/app_localizations.dart';

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
      await _checkIfOpenWebUI();
    }
  }

  /// Checks if we're on the OpenWebUI page and captures cookies if so.
  Future<void> _checkIfOpenWebUI() async {
    if (_cookiesCaptured || !mounted) return;

    final controller = _controller;
    if (controller == null) return;

    try {
      // Check if this is an OpenWebUI page by looking for specific elements
      // or the /api/config endpoint being accessible
      final result = await controller.runJavaScriptReturningResult(
        '''
        (function() {
          // Check for OpenWebUI specific elements or title
          var isOpenWebUI = 
            document.querySelector('div[class*="chat"]') !== null ||
            document.querySelector('[data-testid]') !== null ||
            document.title.toLowerCase().includes('open webui') ||
            document.title.toLowerCase().includes('chat');
          return isOpenWebUI ? "true" : "false";
        })()
        ''',
      );

      if (!mounted) return;

      final isOpenWebUI = result.toString().contains('true');
      DebugLogger.auth(
        'OpenWebUI detection: $isOpenWebUI (on target server: $_isOnTargetServer)',
      );

      // If we're on the target server, capture cookies
      // The user might be on a login page or the main page
      if (_isOnTargetServer) {
        await _captureProxyCookies();
      }
    } catch (e) {
      DebugLogger.log(
        'OpenWebUI detection failed: ${e.toString().split('\n').first}',
        scope: 'auth/proxy',
      );

      // If detection fails but we're on target server, still try to capture
      if (_isOnTargetServer) {
        try {
          await _captureProxyCookies();
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
  Future<void> _captureProxyCookies() async {
    if (_cookiesCaptured || !mounted) return;

    // Set flag immediately to prevent race conditions from rapid taps
    // or multiple page finish events triggering concurrent calls
    _cookiesCaptured = true;

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
      String? jwtToken = await _tryCaptureJwtToken();

      // Notify callback if provided
      widget.config.onAuthComplete?.call();

      // Pop with success result, cookies, and possibly JWT token
      if (!mounted) return;
      context.pop(ProxyAuthResult.success(cookies: cookies, jwtToken: jwtToken));
    } catch (e) {
      // Reset flag on failure so user can retry
      _cookiesCaptured = false;
      DebugLogger.warning(
        'Cookie capture failed: $e',
        scope: 'auth/proxy',
      );
      rethrow;
    }
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
      final cookieResult = await controller.runJavaScriptReturningResult(
        '''
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

    if (!mounted) return;

    await controller.loadRequest(Uri.parse(widget.config.serverConfig.url));
  }

  /// Manual completion button for when auto-detection doesn't work.
  Future<void> _manualComplete() async {
    try {
      await _captureProxyCookies();
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
        backgroundColor: context.qonduitTheme.surfaceBackground,
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
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _buildHelpBanner(l10n),
        ),
      ],
    );
  }

  Widget _buildHelpBanner(AppLocalizations? l10n) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: context.qonduitTheme.surfaceContainer.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: context.qonduitTheme.dividerColor,
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
                color: context.qonduitTheme.iconSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  l10n?.proxyAuthHelpTextSimple ??
                      'Sign in through your proxy. Once authenticated, '
                          'tap Continue to proceed to sign in.',
                  style: context.qonduitTheme.bodySmall?.copyWith(
                    color: context.qonduitTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          SizedBox(
            width: double.infinity,
            child: QonduitButton(
              text: l10n?.continueButton ?? 'Continue',
              icon:
                  Platform.isIOS
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
            style: context.qonduitTheme.bodyMedium?.copyWith(
              color: context.qonduitTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay(AppLocalizations? l10n) {
    return Positioned.fill(
      child: Container(
        color: context.qonduitTheme.surfaceBackground.withValues(alpha: 0.8),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator.adaptive(),
              const SizedBox(height: Spacing.lg),
              Text(
                l10n?.proxyAuthLoading ?? 'Loading...',
                style: context.qonduitTheme.bodyMedium?.copyWith(
                  color: context.qonduitTheme.textSecondary,
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
              color: context.qonduitTheme.error,
            ),
            const SizedBox(height: Spacing.lg),
            Text(
              l10n?.proxyAuthFailed ?? 'Authentication failed',
              style: context.qonduitTheme.headingMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              _error ?? '',
              style: context.qonduitTheme.bodyMedium?.copyWith(
                color: context.qonduitTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.xl),
            QonduitButton(
              text: l10n?.retry ?? 'Retry',
              icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
              onPressed: _refresh,
            ),
            const SizedBox(height: Spacing.md),
            QonduitButton(
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
