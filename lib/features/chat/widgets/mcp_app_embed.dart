import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/features/direct_connections/widgets/direct_mcp_app_view.dart'
    show
        directMcpAppBridgeMessageAllowed,
        directMcpAppNetworkRequestAllowed,
        directMcpAppWebViewSettings;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/utils/external_link_launcher.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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
/// app declared, which the server's content security policy enforces. It
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

  // A fresh, unreachable origin per app: the page has none of the server's
  // or the app's own, and the bridge accepts only this one.
  late final Uri _documentUrl = Uri.parse(
    'https://${_randomHex(18)}.mcp-app.invalid/index.html',
  );
  late final String _bridgeName = 'conduit_mcp_app_${_randomHex(12)}';
  late final String _bridgeToken = _randomHex(24);
  late final String _deliverName = '__conduitMcpDeliver_${_randomHex(12)}';

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
  void dispose() {
    _startTimer?.cancel();
    _load?.cancel();
    final host = _host;
    _host = null;
    if (host != null) unawaited(host.teardown(timeout: Duration.zero));
    super.dispose();
  }

  Future<void> _open() async {
    final api = ref.read(apiServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _opened = true;
      _failure = null;
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
        openLink: (url) => launchExternalLink(url.toString(), scope: 'mcp-app'),
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
        unawaited(_host?.teardown(timeout: Duration.zero));
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

  Future<bool> _confirmToolCall(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context)!;
    var details = const JsonEncoder.withIndent('  ').convert(arguments);
    if (details.length > 2000) details = '${details.substring(0, 2000)}…';
    return ThemedDialogs.confirm(
      context,
      title: l10n.mcpAppToolCallTitle,
      message:
          '${l10n.mcpAppToolCallMessage(widget.app.serverId, name)}\n\n$details',
      confirmText: l10n.mcpAppToolCallAllow,
      cancelText: l10n.directMcpApprovalDeny,
    );
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
    return '<meta http-equiv="X-DNS-Prefetch-Control" content="off">'
        '${csp(resource.csp)}${csp(resource.additionalCsp)}'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<style>*{scrollbar-width:none}::-webkit-scrollbar{display:none}</style>'
        '${resource.html}';
  }

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
          callback: (data) async {
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
      shouldOverrideUrlLoading: (_, action) async {
        final url = action.request.url?.uriValue;
        if (action.isForMainFrame == true && url == _documentUrl) {
          return NavigationActionPolicy.ALLOW;
        }
        // The app opens links through the bridge; a link the user taps in
        // the page opens in the browser.
        if (url != null &&
            action.hasGesture == true &&
            parseAllowedExternalLink(url.toString()) != null) {
          unawaited(launchExternalLink(url.toString(), scope: 'mcp-app'));
        }
        return NavigationActionPolicy.CANCEL;
      },
      shouldInterceptAjaxRequest: (_, request) async {
        if (!directMcpAppNetworkRequestAllowed(request.url?.uriValue, connect)) {
          request.action = AjaxRequestAction.ABORT;
        }
        request.withCredentials = false;
        return request;
      },
      shouldInterceptFetchRequest: (_, request) async {
        if (!directMcpAppNetworkRequestAllowed(request.url?.uriValue, connect)) {
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
      onDownloadStarting: (_, _) async => DownloadStartResponse(
        action: DownloadStartResponseAction.CANCEL,
        handled: true,
      ),
    );
  }
}

/// The script an MCP App page starts with: its `postMessage` to the host
/// reaches Conduit through [bridgeName], with [bridgeToken], and Conduit's
/// messages arrive as `message` events from the page's parent, which is the
/// page itself in a web view, through [deliverName]. Navigation, popups and
/// device access are refused, as in a sandboxed frame.
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
  window.postMessage = deliverToHost;
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
  addEventListener('submit', (event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
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
                child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
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
