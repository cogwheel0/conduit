import 'dart:async';
import 'dart:collection';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_port_preview_controller.dart';
import 'package:conduit_core/features/terminal/services/terminal_port_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/utf16_sanitizer.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import 'terminal_section_components.dart';

/// Opens a web address outside the app.
typedef TerminalPreviewExternalOpener = Future<bool> Function(Uri uri);

Future<bool> _openInSystemBrowser(Uri uri) => launchExternalLink(
  uri.toString(),
  scope: 'terminal/preview',
  mode: uri.scheme == 'http' || uri.scheme == 'https'
      ? LaunchMode.externalApplication
      : null,
);

/// Builds the web view of a preview: the real one, or a stand-in in tests.
typedef TerminalPreviewWebViewBuilder = Widget Function(
  BuildContext context,
  TerminalPreviewWebViewHost host,
);

/// Open WebUI 0.13 and Open Terminal pages report a link's destination to
/// the page that frames them rather than following it. Shown top-level here
/// they post to themselves, so this follows them: the app's navigation rules
/// then map an address on the terminal's machine into the preview and send
/// any other outside the app.
@visibleForTesting
const terminalPreviewNavigationScript = r'''
(() => {
  'use strict';
  addEventListener('message', (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || typeof data !== 'object') return;
    if (typeof data.url !== 'string') return;
    if (data.type !== 'terminal-browser-navigate' &&
        data.type !== 'terminal-browser-popup') return;
    let url;
    try { url = new URL(data.url, location.href); } catch (_) { return; }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
    if (data.replace === true) location.replace(url.href);
    else location.assign(url.href);
  });
})();
''';

/// The web view settings of a preview.
///
/// No JavaScript bridge: the page is the user's own code, or whatever it
/// loads, and has no business calling into the app. On iOS each preview gets
/// a store of its own, so a page served from Open WebUI's address never sees
/// the account's cookies. Android keeps one store for the whole app, and a
/// private one there would clear it, so it shares the store, as the system
/// web view the app used before did. A page shown through the port proxy is
/// served from Open WebUI's own address, so on Android it can read what that
/// store holds for Open WebUI, such as the `token` cookie and local storage a
/// single sign-on leaves behind. A signed browser session (Open WebUI 0.13)
/// serves its pages sandboxed and is not exposed.
@visibleForTesting
InAppWebViewSettings terminalPreviewWebViewSettings({
  TargetPlatform? platform,
}) {
  final ios = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
  return InAppWebViewSettings(
    javaScriptEnabled: true,
    javaScriptBridgeEnabled: false,
    javaScriptCanOpenWindowsAutomatically: false,
    supportMultipleWindows: false,
    useShouldOverrideUrlLoading: true,
    incognito: ios,
    sharedCookiesEnabled: false,
    thirdPartyCookiesEnabled: false,
    allowFileAccess: false,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    allowContentAccess: false,
    geolocationEnabled: false,
    mediaPlaybackRequiresUserGesture: true,
    isInspectable: kDebugMode,
  );
}

/// What a preview's web view reports to the page, and asks of it.
abstract interface class TerminalPreviewWebViewHost {
  TerminalPortPreviewController get preview;

  void attach(InAppWebViewController controller);
  void loadingChanged({required bool loading});
  void historyChanged({required bool canGoBack, required bool canGoForward});
  void loadFailed();
  Future<NavigationActionPolicy> navigate(
    Uri target, {
    required bool history,
    bool userActivated = false,
  });
}

/// A terminal port shown in the app's own web view, with back, forward,
/// reload, the page's title, and links that leave the terminal opening in
/// the system browser.
class TerminalPortPreviewPage extends StatefulWidget {
  const TerminalPortPreviewPage({
    super.key,
    required this.preview,
    this.openExternally = _openInSystemBrowser,
    this.webViewBuilder = buildTerminalPreviewWebView,
  });

  final TerminalPortPreview preview;
  final TerminalPreviewExternalOpener openExternally;
  final TerminalPreviewWebViewBuilder webViewBuilder;

  @override
  State<TerminalPortPreviewPage> createState() =>
      _TerminalPortPreviewPageState();
}

class _TerminalPortPreviewPageState extends State<TerminalPortPreviewPage>
    implements TerminalPreviewWebViewHost {
  @override
  late final TerminalPortPreviewController preview =
      TerminalPortPreviewController(widget.preview);

  InAppWebViewController? _controller;
  bool _loading = true;
  bool _failed = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    preview.addListener(_changed);
    unawaited(preview.start());
  }

  @override
  void dispose() {
    preview
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void attach(InAppWebViewController controller) => _controller = controller;

  @override
  void loadingChanged({required bool loading}) {
    if (!mounted) return;
    setState(() {
      _loading = loading;
      // A new load replaces the failure; the end of a failed one keeps it.
      if (loading) _failed = false;
    });
  }

  @override
  void historyChanged({required bool canGoBack, required bool canGoForward}) {
    if (!mounted ||
        canGoBack == _canGoBack && canGoForward == _canGoForward) {
      return;
    }
    setState(() {
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
    });
  }

  @override
  void loadFailed() {
    if (mounted) {
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// Whether the user is being asked about leaving the preview, so a page
  /// that keeps redirecting cannot stack prompts.
  bool _askingToLeave = false;

  @override
  Future<NavigationActionPolicy> navigate(
    Uri target, {
    required bool history,
    bool userActivated = false,
  }) async {
    switch (preview.decide(target, history: history)) {
      case TerminalPreviewAllow():
        return NavigationActionPolicy.ALLOW;
      case TerminalPreviewLoad(:final uri, :final headers):
        unawaited(
          _controller?.loadUrl(
            urlRequest: URLRequest(url: WebUri.uri(uri), headers: headers),
          ),
        );
        return NavigationActionPolicy.CANCEL;
      case TerminalPreviewOpenExternally(:final uri):
        // A link the user tapped leaves at once. A redirect or a script can
        // leave without a tap (a dev server's hosted login, a loop), and a
        // link followed through Open WebUI's proxy script looks the same, so
        // the user is asked first.
        if (userActivated) {
          unawaited(widget.openExternally(uri));
        } else {
          unawaited(_confirmLeave(uri));
        }
        return NavigationActionPolicy.CANCEL;
      case TerminalPreviewBlock():
        return NavigationActionPolicy.CANCEL;
    }
  }

  Future<void> _confirmLeave(Uri uri) async {
    if (_askingToLeave || !mounted) return;
    _askingToLeave = true;
    try {
      final l10n = AppLocalizations.of(context)!;
      final leave = await ThemedDialogs.confirm(
        context,
        title: l10n.terminalOpenInBrowserAction,
        message: uri.toString(),
        confirmText: l10n.terminalOpenInBrowserAction,
      );
      if (leave && mounted) await widget.openExternally(uri);
    } finally {
      _askingToLeave = false;
    }
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    if (!_failed) {
      await controller.reload();
      return;
    }
    // A page that never arrived has nothing to reload: ask for it again.
    final navigator = preview.navigator;
    if (navigator == null) return;
    setState(() => _failed = false);
    await controller.loadUrl(
      urlRequest: URLRequest(
        url: WebUri.uri(navigator.pageUri(preview.address)),
        headers: navigator.headers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final address = sanitizeUtf16(
      TerminalPreviewNavigator.displayAddress(preview.address),
    );
    final title = sanitizeUtf16(preview.title);
    final externalUri = preview.externalUri;
    final ready = preview.navigator != null;

    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      bodySafeArea: true,
      appBar: AdaptiveAppBar(
        title: title.isEmpty ? address : title,
        subtitle: title.isEmpty ? null : address,
      ),
      body: Column(
        children: [
          Expanded(
            child: !ready
                ? const Center(child: AdaptiveProgressIndicator())
                : Stack(
                    children: [
                      Positioned.fill(
                        child: widget.webViewBuilder(context, this),
                      ),
                      if (_failed)
                        Positioned.fill(
                          child: ColoredBox(
                            color: theme.surfaceBackground,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(Spacing.lg),
                                child: Text(
                                  l10n.terminalPortPreviewLoadFailed,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: theme.textSecondary),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (_loading && !_failed)
                        const Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: AdaptiveProgressIndicator.linear(minHeight: 2),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.xs,
              ),
              child: Row(
                children: [
                  TerminalIconActionButton(
                    tooltip: l10n.back,
                    iosIcon: CupertinoIcons.chevron_back,
                    materialIcon: Icons.arrow_back_rounded,
                    onPressed: _canGoBack && _controller != null
                        ? () => unawaited(_controller!.goBack())
                        : null,
                  ),
                  const SizedBox(width: Spacing.sm),
                  TerminalIconActionButton(
                    tooltip: l10n.terminalPortPreviewForward,
                    iosIcon: CupertinoIcons.chevron_forward,
                    materialIcon: Icons.arrow_forward_rounded,
                    onPressed: _canGoForward && _controller != null
                        ? () => unawaited(_controller!.goForward())
                        : null,
                  ),
                  const Spacer(),
                  TerminalIconActionButton(
                    tooltip: l10n.terminalPortPreviewReload,
                    iosIcon: CupertinoIcons.refresh,
                    materialIcon: Icons.refresh_rounded,
                    onPressed: ready && _controller != null
                        ? () => unawaited(_reload())
                        : null,
                  ),
                  if (externalUri != null) ...[
                    const SizedBox(width: Spacing.sm),
                    TerminalIconActionButton(
                      tooltip: l10n.terminalOpenInBrowserAction,
                      iosIcon: CupertinoIcons.arrow_up_right,
                      materialIcon: Icons.open_in_new_rounded,
                      onPressed: () =>
                          unawaited(widget.openExternally(externalUri)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The preview's platform web view.
Widget buildTerminalPreviewWebView(
  BuildContext context,
  TerminalPreviewWebViewHost host,
) {
  final request = host.preview.initialRequest!;
  Future<void> syncHistory(InAppWebViewController controller) async {
    try {
      host.historyChanged(
        canGoBack: await controller.canGoBack(),
        canGoForward: await controller.canGoForward(),
      );
    } catch (_) {}
  }

  return InAppWebView(
    initialUrlRequest: URLRequest(
      url: WebUri.uri(request.uri),
      headers: request.headers,
    ),
    initialSettings: terminalPreviewWebViewSettings(),
    initialUserScripts: UnmodifiableListView([
      UserScript(
        source: terminalPreviewNavigationScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
        allowedOriginRules: const {'*'},
      ),
    ]),
    onWebViewCreated: host.attach,
    shouldOverrideUrlLoading: (controller, action) async {
      final target = action.request.url?.uriValue;
      if (target == null || action.isForMainFrame != true) {
        return NavigationActionPolicy.ALLOW;
      }
      final type = action.navigationType;
      final method = action.request.method?.toUpperCase();
      return host.navigate(
        target,
        userActivated:
            action.hasGesture == true || type == NavigationType.LINK_ACTIVATED,
        // A form post cannot be made again with the credential added, so it
        // goes as the page sent it, like back, forward and reload.
        history:
            type == NavigationType.BACK_FORWARD ||
            type == NavigationType.RELOAD ||
            (method != null && method != 'GET'),
      );
    },
    // A link that asks for a new window loads in this one instead, through
    // the same rules as any other (Android does so without asking).
    onCreateWindow: (controller, action) async => false,
    onLoadStart: (controller, url) => host.loadingChanged(loading: true),
    onLoadStop: (controller, url) async {
      host.loadingChanged(loading: false);
      host.preview.pageLoaded(url?.uriValue);
      await syncHistory(controller);
    },
    onUpdateVisitedHistory: (controller, url, isReload) async {
      host.preview.pageChanged(url?.uriValue);
      await syncHistory(controller);
    },
    onTitleChanged: (controller, title) => host.preview.titleChanged(title),
    onReceivedError: (controller, request, error) {
      if (request.isForMainFrame == false ||
          error.type == WebResourceErrorType.CANCELLED) {
        return;
      }
      host.loadFailed();
    },
  );
}
