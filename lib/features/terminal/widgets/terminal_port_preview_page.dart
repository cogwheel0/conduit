import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_port_preview_controller.dart';
import 'package:conduit_core/features/terminal/services/terminal_port_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
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

/// Sends a form the page aims at the terminal's machine through the port
/// proxy at [target] (see [TerminalPreviewNavigator.formTarget]), as Open
/// WebUI's proxy and Open Terminal's browser sessions do for their pages,
/// so the post keeps its data. A button's own `formaction`, and a form the
/// page submits by script, go the same way.
@visibleForTesting
String terminalPreviewFormScript(String target) =>
    '''
(() => {
  'use strict';
  const target = ${jsonEncode(target)};
  const local = new Set(['localhost', '127.0.0.1', '0.0.0.0', '[::1]']);
  // Read past a control named "action", which hides the form's own.
  const action = Object.getOwnPropertyDescriptor(
    HTMLFormElement.prototype, 'action');
  const through = (value) => {
    let url;
    try { url = new URL(value, location.href); } catch (_) { return null; }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    if (!local.has(url.hostname.toLowerCase())) return null;
    const port = url.port || (url.protocol === 'https:' ? '443' : '80');
    return target + '/' + port + url.pathname + url.search + url.hash;
  };
  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    const button = event.submitter;
    if (button && button.hasAttribute('formaction')) {
      const sent = through(button.formAction);
      if (sent) button.formAction = sent;
      return;
    }
    const sent = through(action.get.call(form));
    if (sent) action.set.call(form, sent);
  }, true);
  // A form submitted by script fires no submit event.
  const submit = HTMLFormElement.prototype.submit;
  HTMLFormElement.prototype.submit = function () {
    const sent = through(action.get.call(this));
    if (sent) action.set.call(this, sent);
    return submit.call(this);
  };
})();
''';

/// A page of the app's own, at the root of [target]'s server, that puts
/// [cookies] in the web view's cookie store and then replaces itself with
/// [target]: how a private store (iOS) is given a sign-in proxy's cookies
/// before the first page loads, as the plugin can only write to the shared
/// store. Null when no cookie can be given. Names and values a Cookie header
/// could not carry are left out; over https each is sent with every request
/// to the server, framed pages included (`SameSite=None; Secure`).
@visibleForTesting
({Uri url, String document})? terminalPreviewCookieSeed({
  required Map<String, String> cookies,
  required Uri target,
}) {
  final secure = target.scheme == 'https';
  final assignments = [
    for (final entry in cookies.entries)
      if (_cookieName.hasMatch(entry.key) && _cookieValue.hasMatch(entry.value))
        '${entry.key}=${entry.value}; path=/'
            '${secure ? '; secure; samesite=none' : ''}',
  ];
  if (assignments.isEmpty) return null;
  // Inside a script element: `<` is escaped so a value cannot close it.
  String literal(String value) => jsonEncode(value).replaceAll('<', r'\u003c');
  final script = [
    for (final cookie in assignments) 'document.cookie = ${literal(cookie)};',
    'location.replace(${literal(target.toString())});',
  ].join('\n');
  return (
    url: Uri.parse('${target.scheme}://${target.authority}/'),
    document:
        '<!doctype html><meta charset="utf-8"><script>\n$script\n</script>',
  );
}

final _cookieName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
final _cookieValue = RegExp(r'^[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*$');

/// The scripts a preview's pages get: [terminalPreviewNavigationScript],
/// and [terminalPreviewFormScript] when [navigator]'s forms need it.
@visibleForTesting
List<String> terminalPreviewUserScripts(TerminalPreviewNavigator? navigator) {
  final formTarget = navigator?.formTarget;
  return [
    terminalPreviewNavigationScript,
    if (formTarget != null) terminalPreviewFormScript(formTarget),
  ];
}

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

  /// The main frame started to load [page], which may be one the
  /// navigation rules never saw.
  void loadStarted(Uri? page);
  void historyChanged({required bool canGoBack, required bool canGoForward});
  void loadFailed();

  /// [userActivated] when the platform says the user started it (Android).
  /// [linkActivated] when it says a link was followed (iOS), which a
  /// script can do too, so it counts only right after the user tapped the
  /// page.
  Future<NavigationActionPolicy> navigate(
    Uri target, {
    required bool history,
    bool userActivated = false,
    bool linkActivated = false,
  });
}

/// How long after the user taps the page a link that iOS says was followed
/// counts as tapped.
const _tapWindow = Duration(seconds: 1);

/// Asks the preview's rules about a navigation of the web view.
@visibleForTesting
Future<NavigationActionPolicy> terminalPreviewOverrideUrlLoading(
  TerminalPreviewWebViewHost host,
  NavigationAction action,
) async {
  final target = action.request.url?.uriValue;
  if (target == null || action.isForMainFrame != true) {
    return NavigationActionPolicy.ALLOW;
  }
  final type = action.navigationType;
  final method = action.request.method?.toUpperCase();
  return host.navigate(
    target,
    userActivated: action.hasGesture == true,
    linkActivated: type == NavigationType.LINK_ACTIVATED,
    // A form post cannot be made again with the credential added, so it
    // goes as the page sent it, like back, forward and reload.
    history:
        type == NavigationType.BACK_FORWARD ||
        type == NavigationType.RELOAD ||
        (method != null && method != 'GET'),
  );
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
    _tapTimer?.cancel();
    preview
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  /// Whether the user tapped the page within [_tapWindow], so a link iOS
  /// says was followed was most likely tapped rather than clicked by a
  /// script. One tap lets one such link leave.
  bool _tapped = false;
  Timer? _tapTimer;
  Offset? _touchOrigin;

  void _touchStarted(PointerDownEvent event) => _touchOrigin = event.position;

  void _touchCancelled(PointerCancelEvent _) => _touchOrigin = null;

  void _touchEnded(PointerUpEvent event) {
    final origin = _touchOrigin;
    _touchOrigin = null;
    // A drag scrolls the page; only a tap follows a link.
    if (origin == null || (event.position - origin).distance > kTouchSlop) {
      return;
    }
    _tapTimer?.cancel();
    _tapped = true;
    _tapTimer = Timer(_tapWindow, () => _tapped = false);
  }

  bool _takeTap() {
    final tapped = _tapped;
    _tapped = false;
    _tapTimer?.cancel();
    return tapped;
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
  void loadStarted(Uri? page) {
    loadingChanged(loading: true);
    final stray = preview.checkStartedLoad(page);
    if (stray == null) return;
    final replacement = stray is TerminalPreviewLoad
        ? stray
        : preview.returnToAddress();
    final controller = _controller;
    if (controller != null && replacement != null) {
      unawaited(_replaceLoad(controller, replacement));
    }
    if (stray case TerminalPreviewOpenExternally(:final uri)) {
      unawaited(_confirmLeave(uri));
    }
  }

  Future<void> _replaceLoad(
    InAppWebViewController controller,
    TerminalPreviewLoad load,
  ) async {
    try {
      await controller.stopLoading();
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri.uri(load.uri),
          headers: load.headers,
        ),
      );
    } catch (_) {}
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
    bool linkActivated = false,
  }) async {
    // Any navigation spends the tap before it, so a page it opens cannot
    // leave on that tap too. A link Open Terminal's pages follow by script
    // is not one iOS says was followed, yet it was tapped all the same.
    final tapped = _takeTap() && linkActivated;
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
        if (userActivated || tapped) {
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
                        child: Listener(
                          onPointerDown: _touchStarted,
                          onPointerUp: _touchEnded,
                          onPointerCancel: _touchCancelled,
                          child: widget.webViewBuilder(context, this),
                        ),
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
  final settings = terminalPreviewWebViewSettings();
  // A private store (iOS) starts without the sign-in proxy's cookies, so the
  // first page is the app's own, which gives them to it and then goes on.
  final seed = settings.incognito == true
      ? terminalPreviewCookieSeed(
          cookies: host.preview.proxyCookies,
          target: request.uri,
        )
      : null;
  // Only until the page it goes on to starts: later, the server's root is
  // one more page the preview's rules decide on.
  var seeding = seed != null;
  bool isSeed(WebUri? url) => seeding && url?.uriValue == seed?.url;
  final firstPage = request.uri;
  Future<void> syncHistory(InAppWebViewController controller) async {
    try {
      host.historyChanged(
        canGoBack: await controller.canGoBack(),
        canGoForward: await controller.canGoForward(),
      );
    } catch (_) {}
  }

  return InAppWebView(
    initialUrlRequest: seed == null
        ? URLRequest(url: WebUri.uri(request.uri), headers: request.headers)
        : null,
    initialData: seed == null
        ? null
        : InAppWebViewInitialData(
            data: seed.document,
            baseUrl: WebUri.uri(seed.url),
            historyUrl: WebUri.uri(seed.url),
          ),
    initialSettings: settings,
    initialUserScripts: UnmodifiableListView([
      for (final source in terminalPreviewUserScripts(host.preview.navigator))
        UserScript(
          source: source,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: const {'*'},
        ),
    ]),
    onWebViewCreated: host.attach,
    // The app's own first page is none of the preview's.
    shouldOverrideUrlLoading: (controller, action) async =>
        isSeed(action.request.url)
        ? NavigationActionPolicy.ALLOW
        : terminalPreviewOverrideUrlLoading(host, action),
    // A link that asks for a new window loads in this one instead, through
    // the same rules as any other (Android does so without asking).
    onCreateWindow: (controller, action) async => false,
    // Android does not ask the rules about a form post; this catches one
    // that leaves the preview's pages.
    onLoadStart: (controller, url) {
      if (isSeed(url)) return;
      seeding = false;
      host.loadStarted(url?.uriValue);
    },
    onLoadStop: (controller, url) async {
      if (isSeed(url)) return;
      host.loadingChanged(loading: false);
      host.preview.pageLoaded(url?.uriValue);
      await syncHistory(controller);
    },
    onUpdateVisitedHistory: (controller, url, isReload) async {
      if (isSeed(url)) return;
      host.preview.pageChanged(url?.uriValue);
      await syncHistory(controller);
    },
    onTitleChanged: (controller, title) => host.preview.titleChanged(title),
    onReceivedError: (controller, request, error) {
      // Should the app's own first page fail, the real one is tried without
      // the cookies.
      if (isSeed(request.url)) {
        seeding = false;
        unawaited(
          controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(firstPage))),
        );
        return;
      }
      if (request.isForMainFrame == false ||
          error.type == WebResourceErrorType.CANCELLED) {
        return;
      }
      host.loadFailed();
    },
  );
}
