export 'package:conduit_core/features/librechat/services/librechat_sso.dart';

import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/services/librechat_sso.dart';
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
