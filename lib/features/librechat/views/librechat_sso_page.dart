import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/auth/native_cookie_manager.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/webview_cookie_helper.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';

/// What the single sign-on page does with one navigation.
enum LibreChatSsoNavigation {
  /// Let it load: the provider's pages, and LibreChat's own sign-in routes.
  allow,

  /// LibreChat's OAuth callback: the provider sent the browser back, and
  /// this response sets the session. Let it load.
  providerReturned,

  /// A page of LibreChat's outside its sign-in routes. Once the provider has
  /// returned, this is LibreChat sending the browser on to its web app: the
  /// sign-in finished. Before that it may be a provider that shares
  /// LibreChat's address, which loads as usual.
  appPage,

  /// LibreChat sent the browser back to its sign-in page with an error.
  fail,
}

/// What to do with a navigation to [target] during single sign-on on a
/// server reached at [serverOrigins]. A path there is the server's base
/// path, which its routes are read below.
///
/// LibreChat signs in by redirecting through `/oauth/<provider>` and the
/// provider, back to `/oauth/<provider>/callback`, which sets its session
/// cookies and redirects to its web app. That last hop is cancelled: the
/// web app would renew the session on load and rotate the refresh cookie
/// under the app's feet.
@visibleForTesting
LibreChatSsoNavigation libreChatSsoNavigation(
  Uri target, {
  required Iterable<Uri> serverOrigins,
}) {
  final server = serverOrigins
      .where((origin) => _sameOrigin(origin, target))
      .firstOrNull;
  if (server == null) return LibreChatSsoNavigation.allow;
  // A server under a sub-path such as `/oauth/librechat` must not have its
  // web app read as an OAuth route.
  final base = _basePath(server);
  var path = target.path;
  if (base.isNotEmpty && (path == base || path.startsWith('$base/'))) {
    path = path.substring(base.length);
  }
  final segments = Uri(path: path).pathSegments;
  final oauth = segments.lastIndexOf('oauth');
  if (oauth >= 0 &&
      oauth == segments.length - 3 &&
      segments.last == 'callback') {
    return LibreChatSsoNavigation.providerReturned;
  }
  if (segments.contains('oauth') || segments.contains('api')) {
    return LibreChatSsoNavigation.allow;
  }
  if (segments.isNotEmpty &&
      segments.last == 'login' &&
      target.queryParameters.containsKey('error')) {
    return LibreChatSsoNavigation.fail;
  }
  return LibreChatSsoNavigation.appPage;
}

/// Where single sign-on on [baseUrl] starts, and where its session cookies
/// are read: the server's own address for itself ([serverDomain]), since
/// the provider returns there, as long as that is the configured server --
/// the same origin and the same path.
///
/// A server naming another server as its own is not followed, nor another
/// path on the same host, which can be another server behind the same
/// proxy: the session that server's sign-in leaves would be sent to the
/// configured one. (Its own web app cannot sign in that way either.)
@visibleForTesting
Uri libreChatSsoBase(String baseUrl, String? serverDomain) {
  final configured = Uri.parse(baseUrl);
  final own = serverDomain == null
      ? null
      : LibreChatServer.normalizeBaseUrl(serverDomain);
  if (own != null) {
    final domain = Uri.parse(own);
    if (_sameOrigin(domain, configured) &&
        _basePath(domain) == _basePath(configured)) {
      return domain;
    }
  }
  return configured;
}

/// Where a sign-in's session cookies are read: the server's base path, so a
/// server under a sub-path (whose proxy may scope its cookies to it) gives
/// them up too. Cookies scoped to the whole host match it as well.
@visibleForTesting
Uri libreChatSsoCookieUrl(Uri base) => Uri(
  scheme: base.scheme,
  host: base.host,
  port: base.hasPort ? base.port : null,
  path: base.path.endsWith('/') ? base.path : '${base.path}/',
);

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    _port(a) == _port(b);

String _basePath(Uri uri) => uri.path.endsWith('/')
    ? uri.path.substring(0, uri.path.length - 1)
    : uri.path;

int _port(Uri uri) =>
    uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

/// The session cookies a finished single sign-on left in the web view, read
/// natively (they are httpOnly), as LibreChat cookies.
@visibleForTesting
LibreChatCookies libreChatCookiesFrom(Map<String, String> cookies) =>
    LibreChatCookies.of([
      for (final entry in cookies.entries)
        if (entry.key.isNotEmpty && entry.value.isNotEmpty)
          LibreChatCookie(name: entry.key, value: entry.value),
    ]);

/// Signs in to a LibreChat server through one of its single sign-on
/// providers in a web view. Pops with the session's cookies, or null when it
/// did not finish.
class LibreChatSsoPage extends StatefulWidget {
  const LibreChatSsoPage({
    super.key,
    required this.server,
    required this.info,
    required this.provider,
    @visibleForTesting this.prepareSession,
  });

  final LibreChatServer server;
  final LibreChatServerInfo info;
  final LibreChatSsoProvider provider;

  /// Clears the web view's cookies and website data, reporting whether both
  /// were cleared. Defaults to the platform's.
  final Future<bool> Function()? prepareSession;

  /// Opens the page and returns the harvested cookies, or null.
  static Future<LibreChatCookies?> open(
    BuildContext context, {
    required LibreChatServer server,
    required LibreChatServerInfo info,
    required LibreChatSsoProvider provider,
  }) => Navigator.of(context).push<LibreChatCookies>(
    PageRouteBuilder<LibreChatCookies>(
      pageBuilder: (_, _, _) =>
          LibreChatSsoPage(server: server, info: info, provider: provider),
    ),
  );

  @override
  State<LibreChatSsoPage> createState() => _LibreChatSsoPageState();
}

class _LibreChatSsoPageState extends State<LibreChatSsoPage> {
  bool _ready = false;
  bool _finishing = false;
  bool _loading = true;

  /// The web view's earlier session could not be cleared; nothing loads.
  bool _cleanupFailed = false;

  /// LibreChat's OAuth callback has loaded: the next page of LibreChat's is
  /// where the sign-in finished.
  bool _providerReturned = false;

  late final Uri _base = libreChatSsoBase(
    widget.server.baseUrl,
    widget.info.serverDomain,
  );

  late final Uri _start = Uri.parse('$_base${widget.provider.path}');

  late final List<Uri> _origins = [_base];

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  /// A fresh web session, so no earlier sign-in's cookies are taken. When it
  /// cannot be had, the page stays closed: an earlier user's session could
  /// otherwise sign this one in.
  Future<void> _prepare() async {
    if (_cleanupFailed) setState(() => _cleanupFailed = false);
    final cleared = await (widget.prepareSession ?? _clearWebSession)();
    if (!mounted) return;
    if (!cleared) {
      DebugLogger.warning(
        'librechat-sso-cleanup-failed',
        scope: 'librechat/sso',
      );
    }
    setState(() {
      _ready = cleared;
      _cleanupFailed = !cleared;
    });
  }

  static Future<bool> _clearWebSession() async {
    final cookiesCleared = await WebViewCookieHelper.clearCookies();
    final websiteDataCleared = await WebViewCookieHelper.clearWebsiteData();
    return cookiesCleared && websiteDataCleared;
  }

  Future<NavigationActionPolicy?> _onNavigation(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final url = action.request.url;
    if (url == null || _finishing) return NavigationActionPolicy.ALLOW;
    switch (libreChatSsoNavigation(url, serverOrigins: _origins)) {
      case LibreChatSsoNavigation.allow:
        return NavigationActionPolicy.ALLOW;
      case LibreChatSsoNavigation.providerReturned:
        _providerReturned = true;
        return NavigationActionPolicy.ALLOW;
      case LibreChatSsoNavigation.appPage:
        return await _finishIfSignedIn()
            ? NavigationActionPolicy.CANCEL
            : NavigationActionPolicy.ALLOW;
      case LibreChatSsoNavigation.fail:
        _close(null);
        return NavigationActionPolicy.CANCEL;
    }
  }

  /// A redirect a platform did not offer for interception still lands here
  /// as it starts loading.
  void _onLoadStart(InAppWebViewController controller, WebUri? url) {
    if (url == null || _finishing) return;
    switch (libreChatSsoNavigation(url, serverOrigins: _origins)) {
      case LibreChatSsoNavigation.allow:
        return;
      case LibreChatSsoNavigation.providerReturned:
        _providerReturned = true;
      case LibreChatSsoNavigation.appPage:
        unawaited(() async {
          if (await _finishIfSignedIn()) await controller.stopLoading();
        }());
      case LibreChatSsoNavigation.fail:
        unawaited(controller.stopLoading());
        _close(null);
    }
  }

  /// At a page of LibreChat's: finishes when the sign-in did, which is once
  /// the provider returned through LibreChat's callback, or once a session
  /// is there (a platform may not show the callback). Returns whether it
  /// finished.
  Future<bool> _finishIfSignedIn() async {
    final providerReturned = _providerReturned;
    final cookies = await _sessionCookies();
    if (_finishing) return true;
    // Left while the cookies were read (Cancel, or system Back, which pops
    // the page without [_close] and leaves it mounted until its exit
    // finishes): the web view's cookies may be a later sign-in's by now, and
    // are not this page's to clear.
    if (!mounted ||
        _closed ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return false;
    }
    if (!providerReturned && !cookies.hasRefreshToken) return false;
    _finishing = true;
    DebugLogger.auth('librechat-sso-finished', scope: 'librechat/sso');
    // The app keeps the session from here on; the web view forgets it. A
    // failed clear leaves it for the next sign-in's fresh start, which does
    // not open over it.
    if (!await WebViewCookieHelper.clearCookies()) {
      DebugLogger.warning('librechat-sso-clear-failed', scope: 'librechat/sso');
    }
    _close(cookies.hasRefreshToken ? cookies : null);
    return true;
  }

  Future<LibreChatCookies> _sessionCookies() async => libreChatCookiesFrom(
    await NativeCookieManager.getCookiesForUrl(
      libreChatSsoCookieUrl(_base).toString(),
    ),
  );

  bool _closed = false;

  /// Leaves the page, once: a sign-in finishing after Cancel (its cookies
  /// were still being read) must not pop the page underneath as well.
  void _close(LibreChatCookies? cookies) {
    // System Back may have popped the page already, bypassing this.
    if (!mounted || _closed || !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    _closed = true;
    Navigator.of(context).pop(cookies);
  }

  String get _userAgent {
    if (!kIsWeb && Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1';
    }
    return 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = widget.provider.label;
    return ConnectionWebAuthScaffold(
      title: label ?? l10n.libreChatTitle,
      onBack: () => _close(null),
      backLabel: l10n.cancel,
      body: _cleanupFailed
          ? _cleanupFailedState(l10n)
          : !_ready || !isWebViewSupported
          ? _loadingState(l10n)
          : Stack(
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri.uri(_start)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    useShouldOverrideUrlLoading: true,
                    userAgent: _userAgent,
                  ),
                  shouldOverrideUrlLoading: _onNavigation,
                  onLoadStart: _onLoadStart,
                  onLoadStop: (_, _) {
                    if (mounted) setState(() => _loading = false);
                  },
                  onReceivedError: (_, request, _) {
                    if (request.isForMainFrame ?? false) _close(null);
                  },
                ),
                if (_loading) _loadingState(l10n),
              ],
            ),
    );
  }

  Widget _cleanupFailedState(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return ColoredBox(
      key: const Key('librechat-sso-cleanup-failed'),
      color: theme.surfaceBackground,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.pagePadding),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.ssoAuthFailed,
                textAlign: TextAlign.center,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textPrimary,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              ConduitButton(
                key: const Key('librechat-sso-retry'),
                text: l10n.retry,
                isFullWidth: true,
                onPressed: () => unawaited(_prepare()),
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                text: l10n.cancel,
                isSecondary: true,
                isFullWidth: true,
                onPressed: () => _close(null),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadingState(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return ColoredBox(
      color: theme.surfaceBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AdaptiveProgressIndicator(),
            const SizedBox(height: Spacing.md),
            Text(
              l10n.ssoLoadingLogin,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
