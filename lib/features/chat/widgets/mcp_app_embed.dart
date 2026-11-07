import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit/features/direct_connections/widgets/direct_mcp_app_view.dart'
    show
        directMcpAppBridgeMessageAllowed,
        directMcpAppNetworkRequestAllowed,
        directMcpAppWebViewSettings;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/external_link_launcher.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit_core/features/mcp_apps/mcp_app_host.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

const double _initialHeight = 300;
const double _minHeight = 100;
const double _maxHeight = 1600;
const Duration _startTimeout = Duration(seconds: 30);

/// An MCP App a tool call showed in an Open WebUI chat (0.13 and later).
///
/// It loads when the user opens it, like other embedded content. The app's
/// page comes from the server's app RPC and runs in a sealed web view: no
/// storage, cookies, popups or navigation, and only the network origins the
/// app declared, which the server's content security policy enforces; an app
/// the server sends no policy for is not shown. It
/// talks to Conduit over the MCP Apps bridge ([McpAppHost]); every tool it
/// calls is confirmed by the user first.
class McpAppEmbed extends ConsumerStatefulWidget {
  const McpAppEmbed({super.key, required this.app});

  final OpenWebUiMcpApp app;

  @override
  ConsumerState<McpAppEmbed> createState() => _McpAppEmbedState();
}

class _McpAppEmbedState extends ConsumerState<McpAppEmbed> {
  bool _opened = false;
  bool _started = false;
  String? _failure;
  OpenWebUiMcpAppResource? _resource;
  McpAppHost? _host;
  InAppWebViewController? _controller;
  CancelableLoad? _load;
  Timer? _startTimer;
  double _height = _initialHeight;
  double _width = 0;
  Brightness? _brightness;

  /// The page is loaded once; it may not reload or navigate itself away.
  bool _documentLoaded = false;

  // A fresh, unreachable origin for every page an app opens, a retry or
  // another app in the same place included: the page has none of the
  // server's or the app's own, and the bridge accepts only this one. The
  // host sits straight under `.invalid`, with no parent domain shared with
  // other pages, so a cookie a page sets (Android keeps one store for the
  // whole app) reaches no other. Set by [_newPage] when the app opens.
  late Uri _documentUrl;
  late String _bridgeName;
  late String _bridgeToken;
  late String _deliverName;

  void _newPage() {
    _documentUrl = mcpAppDocumentUrl(_randomHex(18));
    _bridgeName = 'conduit_mcp_app_${_randomHex(12)}';
    _bridgeToken = _randomHex(24);
    _deliverName = '__conduitMcpDeliver_${_randomHex(12)}';
  }

  final Set<Factory<OneSequenceGestureRecognizer>> _gestures = {
    Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_brightness != null && _brightness != brightness) {
      _host?.hostContextChanged({'theme': _themeName(brightness)});
    }
    _brightness = brightness;
  }

  @override
  void didUpdateWidget(covariant McpAppEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another version of the reply calls the same tool with other data: the
    // open app showed the old one, so it closes and is offered again.
    if (oldWidget.app != widget.app) _close();
  }

  @override
  void deactivate() {
    // The web view still exists here, so the app hears that it is going.
    _stop();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // Moved elsewhere: the app was told it is going, so it is offered again.
    // The element rebuilds on activation, so no setState is needed.
    if (_opened) _close(rebuild: false);
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _startTimer?.cancel();
    _load?.cancel();
    final host = _host;
    _host = null;
    host?.teardown();
  }

  void _close({bool rebuild = true}) {
    _stop();
    void reset() {
      _opened = false;
      _started = false;
      _failure = null;
      _resource = null;
      _controller = null;
      _documentLoaded = false;
      _height = _initialHeight;
    }

    rebuild ? setState(reset) : reset();
  }

  Future<void> _open() async {
    final api = ref.read(apiServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _opened = true;
      _failure = null;
      // A retry opens a new web view, which loads the page afresh, under a
      // host of its own like any other page.
      _documentLoaded = false;
      _controller = null;
      _newPage();
    });
    if (api == null) {
      setState(() => _failure = l10n.mcpAppLoadFailed(l10n.errorMessage));
      return;
    }
    final load = CancelableLoad();
    _load = load;
    try {
      final json = await api.runMcpAppRequest(
        widget.app,
        method: 'ui/resource',
        cancelToken: load.token,
      );
      if (!mounted || load.cancelled) return;
      final resource = OpenWebUiMcpAppResource.fromJson(json);
      _resource = resource;
      _host = McpAppHost(
        app: widget.app,
        resource: resource,
        runRequest: (method, params) =>
            api.runMcpAppRequest(widget.app, method: method, params: params),
        confirmToolCall: _confirmToolCall,
        openLink: _confirmOpenLink,
        send: _deliver,
        hostContext: _hostContext,
        onSizeChanged: (height) {
          if (!mounted) return;
          setState(() => _height = height.clamp(_minHeight, _maxHeight));
        },
        onInitialized: () {
          _startTimer?.cancel();
          if (mounted) setState(() => _started = true);
        },
      );
      _startTimer = Timer(_startTimeout, () {
        if (!mounted || _started) return;
        setState(() => _failure = l10n.mcpAppDidNotStart);
        _host?.teardown();
        _host = null;
      });
      setState(() {});
    } on McpAppRpcException catch (error) {
      if (mounted && !load.cancelled) {
        setState(() => _failure = l10n.mcpAppLoadFailed(error.message));
      }
    } catch (error, stackTrace) {
      if (load.cancelled) return;
      DebugLogger.error(
        'mcp-app-load-failed',
        scope: 'chat/mcp-app',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _failure = l10n.mcpAppLoadFailed(l10n.errorMessage));
      }
    }
  }

  Map<String, dynamic> _hostContext() => {
    'theme': _themeName(_brightness ?? Brightness.light),
    'platform': 'mobile',
    'displayMode': 'inline',
    'availableDisplayModes': const ['inline'],
    'locale': Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en',
    'deviceCapabilities': const {'touch': true, 'hover': false},
    'containerDimensions': {
      if (_width > 0) 'width': _width,
      'maxHeight': _maxHeight,
    },
  };

  static String _themeName(Brightness brightness) =>
      brightness == Brightness.dark ? 'dark' : 'light';

  /// Asks before the app runs a tool. Every argument it would send is shown,
  /// as in the web client; long ones scroll rather than being cut short.
  Future<bool> _confirmToolCall(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context)!;
    final details = const JsonEncoder.withIndent('  ').convert(arguments);
    final allowed = await ThemedDialogs.showCustom<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = dialogContext.conduitTheme;
        return ThemedDialogs.buildBase(
          context: dialogContext,
          title: l10n.mcpAppToolCallTitle,
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.mcpAppToolCallMessage(widget.app.serverId, name)),
              const SizedBox(height: Spacing.sm),
              Text(
                details,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textSecondary,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          actions: [
            ConduitTextButton(
              text: l10n.directMcpApprovalDeny,
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            ConduitTextButton(
              text: l10n.mcpAppToolCallAllow,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              isPrimary: true,
            ),
          ],
        );
      },
    );
    return allowed ?? false;
  }

  /// A link the app asks to open opens only once the user agrees: the app
  /// can ask at any time, not only when the user tapped something.
  Future<bool> _confirmOpenLink(Uri url) async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context)!;
    final allowed = await ThemedDialogs.confirm(
      context,
      title: l10n.mcpAppOpenLinkTitle,
      message: url.toString(),
      confirmText: l10n.mcpAppOpenLinkConfirm,
    );
    if (!allowed) return false;
    return launchExternalLink(url.toString(), scope: 'mcp-app');
  }

  void _deliver(String message) {
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      controller.evaluateJavascript(
        source: '$_deliverName(${jsonEncode(message)});',
      ),
    );
  }

  String _document(OpenWebUiMcpAppResource resource) {
    String csp(String policy) => policy.trim().isEmpty
        ? ''
        : '<meta http-equiv="Content-Security-Policy" '
              'content="${const HtmlEscape(HtmlEscapeMode.attribute).convert(policy)}">';
    // The host's tags go before the app's page, as in the web client. An
    // app that opens with a doctype keeps it first, so it is laid out in
    // standards mode as written; one without stays in quirks mode, as there.
    final doctype = _leadingDoctype.firstMatch(resource.html);
    final page = doctype == null
        ? resource.html
        : resource.html.substring(doctype.end);
    return '${doctype?.group(1) ?? ''}'
        '<meta http-equiv="X-DNS-Prefetch-Control" content="off">'
        '${csp(resource.csp)}${csp(resource.additionalCsp)}'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<style>*{scrollbar-width:none}::-webkit-scrollbar{display:none}</style>'
        '$page';
  }

  // Comments may come before the doctype and it still counts, so they move
  // with it.
  static final _leadingDoctype = RegExp(
    r'^(\s*(?:<!--[\s\S]*?-->\s*)*<!doctype[^>]*>)',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final failure = _failure;
    if (failure != null) {
      return _McpAppCard(
        title: widget.app.toolName,
        message: failure,
        actionLabel: _opened ? l10n.retry : null,
        onAction: _opened ? _open : null,
      );
    }
    if (!_opened) {
      return _McpAppCard(
        title: widget.app.toolName,
        message: l10n.mcpAppPreviewDescription(widget.app.serverId),
        actionLabel: l10n.mcpAppOpen,
        onAction: _open,
      );
    }
    final resource = _resource;
    if (resource == null || _host == null) {
      return const _McpAppLoading(height: _initialHeight);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite && constraints.maxWidth != _width) {
          final width = constraints.maxWidth;
          final changed = _width > 0;
          _width = width;
          if (changed) {
            _host?.hostContextChanged({
              'containerDimensions': {'width': width, 'maxHeight': _maxHeight},
            });
          }
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          child: SizedBox(
            key: const ValueKey<String>('mcp-app-view'),
            height: _height,
            child: Stack(
              children: [
                Positioned.fill(child: _webView(resource)),
                if (!_started)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(child: AdaptiveProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _webView(OpenWebUiMcpAppResource resource) {
    final origin = _documentUrl.origin;
    final connect = resource.declaredDomains('connectDomains');
    final allowedRequests = [
      ...connect,
      ...resource.declaredDomains('resourceDomains'),
      ...resource.declaredDomains('frameDomains'),
      ...resource.declaredDomains('baseUriDomains'),
    ];
    return InAppWebView(
      gestureRecognizers: _gestures,
      initialData: InAppWebViewInitialData(
        data: _document(resource),
        baseUrl: WebUri(_documentUrl.toString()),
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: mcpAppBridgeScript(
            bridgeName: _bridgeName,
            bridgeToken: _bridgeToken,
            deliverName: _deliverName,
          ),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: {origin},
        ),
      ]),
      initialSettings: directMcpAppWebViewSettings(origin)
        ..transparentBackground = true,
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: _bridgeName,
          // Typed: the plugin hands a handler that takes any argument only
          // the bare arguments, without the origin the bridge checks.
          callback: (JavaScriptHandlerFunctionData data) async {
            if (!directMcpAppBridgeMessageAllowed(
              data,
              expectedOrigin: origin,
              expectedToken: _bridgeToken,
            )) {
              return false;
            }
            await _host?.receive(data.args[1] as String);
            return true;
          },
        );
      },
      // Android loads the page without asking shouldOverrideUrlLoading, so
      // its start is what marks it loaded there.
      onLoadStart: (_, url) {
        if (url?.uriValue == _documentUrl) _documentLoaded = true;
      },
      shouldOverrideUrlLoading: (_, action) async {
        final url = action.request.url?.uriValue;
        if (action.isForMainFrame == true) {
          if (url == _documentUrl && !_documentLoaded) {
            _documentLoaded = true;
            return NavigationActionPolicy.ALLOW;
          }
          // The app opens links through the bridge; a link the user taps in
          // the page opens in the browser. The page itself stays.
          final tapped =
              action.hasGesture == true ||
              action.navigationType == NavigationType.LINK_ACTIVATED;
          if (url != null &&
              tapped &&
              parseAllowedExternalLink(url.toString()) != null) {
            unawaited(launchExternalLink(url.toString(), scope: 'mcp-app'));
          }
          return NavigationActionPolicy.CANCEL;
        }
        // Frames from the domains the app declared, which its content
        // security policy also allows; iOS asks here for those too.
        final frames = resource.declaredDomains('frameDomains');
        return url != null &&
                (url.scheme == 'about' ||
                    directMcpAppNetworkRequestAllowed(url, frames))
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      shouldInterceptAjaxRequest: (_, request) async {
        if (!mcpAppScriptRequestAllowed(
          mcpAppParsedUrl(request.url),
          connect,
          pageScheme: _documentUrl.scheme,
        )) {
          request.action = AjaxRequestAction.ABORT;
        }
        request.withCredentials = false;
        return request;
      },
      shouldInterceptFetchRequest: (_, request) async {
        if (!mcpAppScriptRequestAllowed(
          mcpAppParsedUrl(request.url),
          connect,
          pageScheme: _documentUrl.scheme,
        )) {
          request.action = FetchRequestAction.ABORT;
        }
        request.credentials = FetchRequestCredentialDefault(value: 'omit');
        return request;
      },
      shouldInterceptRequest: (_, request) async {
        final url = request.url.uriValue;
        if (url == _documentUrl ||
            url.scheme == 'data' ||
            url.scheme == 'blob' ||
            directMcpAppNetworkRequestAllowed(url, allowedRequests)) {
          return null;
        }
        return WebResourceResponse(
          statusCode: 403,
          reasonPhrase: 'Blocked',
          headers: const {},
          contentType: 'text/plain',
          contentEncoding: 'utf-8',
          data: Uint8List(0),
        );
      },
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, _) async =>
          PermissionResponse(action: PermissionResponseAction.DENY),
      // Without an answer here Android opens its file picker and hands the
      // chosen files to the page.
      onShowFileChooser: (_, _) async =>
          ShowFileChooserResponse(handledByClient: true, filePaths: null),
      onDownloadStarting: (_, _) async => DownloadStartResponse(
        action: DownloadStartResponseAction.CANCEL,
        handled: true,
      ),
    );
  }
}

/// The address an app's page is loaded under: `https://mcp-app-{token}.invalid`,
/// a host of its own that no other app shares a parent domain with.
@visibleForTesting
Uri mcpAppDocumentUrl(String token) =>
    Uri.parse('https://mcp-app-$token.invalid/index.html');

/// [url] as a [Uri], or null when it does not parse. The web view would
/// still clean such an address up and go there, a tab inside its port for
/// one, but its [WebUri.uriValue] is empty, which would read as a path.
@visibleForTesting
Uri? mcpAppParsedUrl(WebUri? url) =>
    url != null && url.isValidUri ? url.uriValue : null;

/// Whether an app's page may make a fetch or XHR request to [url], which
/// the web view's hooks report as the page wrote it.
///
/// An absolute address must be one the app declared in [connect]; one
/// starting `//` takes the page's scheme ([pageScheme]) first. A path is
/// left to the page: the browser resolves it against the page's base
/// address, and the app's content security policy, which a page must have
/// to be shown, holds both that base (`base-uri`) and where the request
/// then goes (`connect-src`), neither of which the hooks can see.
@visibleForTesting
bool mcpAppScriptRequestAllowed(
  Uri? url,
  List<String> connect, {
  required String pageScheme,
}) {
  if (url == null) return false;
  if (!url.hasScheme) {
    if (!url.hasAuthority) return true;
    url = url.replace(scheme: pageScheme);
  }
  return directMcpAppNetworkRequestAllowed(url, connect);
}

/// The script an MCP App page starts with: its `postMessage` to the host
/// reaches Conduit through [bridgeName], with [bridgeToken], and Conduit's
/// messages arrive as `message` events from the page's parent, which is the
/// page itself in a web view, through [deliverName]. Navigation, popups and
/// device access are refused, as in a sandboxed frame. A form's submit still
/// reaches the app's own handlers, but it loads no page.
@visibleForTesting
String mcpAppBridgeScript({
  required String bridgeName,
  required String bridgeToken,
  required String deliverName,
}) =>
    '''
(() => {
  'use strict';
  const bridgeName = ${jsonEncode(bridgeName)};
  const bridgeToken = ${jsonEncode(bridgeToken)};
  const queue = [];
  const nativePostMessage = window.postMessage.bind(window);
  const deliverToHost = (message) => {
    let payload;
    try { payload = JSON.stringify(message); } catch (_) { return; }
    const bridge = window.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      bridge.callHandler(bridgeName, bridgeToken, payload);
    } else {
      queue.push(message);
    }
  };
  // The page's parent is the page itself in a web view: what it posts over
  // the MCP Apps bridge goes to Conduit, and anything else, such as a
  // library's own scheduling, stays the page's.
  window.postMessage = (message, ...rest) => {
    if (message && typeof message === 'object' && message.jsonrpc === '2.0') {
      deliverToHost(message);
    } else {
      nativePostMessage(message, ...rest);
    }
  };
  window.addEventListener('flutterInAppWebViewPlatformReady', () => {
    while (queue.length) deliverToHost(queue.shift());
  }, {once: true});
  Object.defineProperty(window, ${jsonEncode(deliverName)}, {
    value: (payload) => {
      let data;
      try { data = JSON.parse(payload); } catch (_) { return; }
      window.dispatchEvent(new MessageEvent('message', {data, source: window, origin: location.origin}));
    },
    writable: false,
    configurable: false,
  });
  window.open = () => null;
  // Cancelled first, before any of the app's handlers, which cannot undo it.
  addEventListener('submit', (event) => {
    event.preventDefault();
  }, true);
  const denied = () => Promise.reject(new DOMException('Denied', 'NotAllowedError'));
  const replace = (object, name, value) => {
    try { Object.defineProperty(object, name, {value, configurable: false}); } catch (_) {}
  };
  if (navigator.serviceWorker) replace(navigator.serviceWorker, 'register', denied);
  if (navigator.clipboard) {
    replace(navigator.clipboard, 'read', denied);
    replace(navigator.clipboard, 'readText', denied);
  }
  if (navigator.mediaDevices) replace(navigator.mediaDevices, 'getUserMedia', denied);
  if (navigator.geolocation) {
    replace(navigator.geolocation, 'getCurrentPosition', (_, error) => error && error({code: 1}));
    replace(navigator.geolocation, 'watchPosition', (_, error) => { error && error({code: 1}); return 0; });
  }
})();
''';

/// A request that is dropped when its widget goes away.
@visibleForTesting
final class CancelableLoad {
  final token = CancelToken();
  bool get cancelled => token.isCancelled;
  void cancel() {
    if (!token.isCancelled) token.cancel('closed');
  }
}

String _randomHex(int bytes) {
  final random = Random.secure();
  return [
    for (var i = 0; i < bytes; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

class _McpAppCard extends StatelessWidget {
  const _McpAppCard({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return DecoratedBox(
      key: const ValueKey<String>('mcp-app-card'),
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border.all(color: theme.cardBorder),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.widgets_outlined, size: 16, color: theme.iconSecondary),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMediumStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              message,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Spacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: AdaptiveButton(
                  onPressed: onAction,
                  label: actionLabel!,
                  style: AdaptiveButtonStyle.plain,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _McpAppLoading extends StatelessWidget {
  const _McpAppLoading({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border.all(color: theme.cardBorder),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: SizedBox(
        height: height,
        child: const Center(child: AdaptiveProgressIndicator()),
      ),
    );
  }
}
