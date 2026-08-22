import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/direct_mcp_app.dart';
import '../services/direct_mcp_apps_protocol.dart';

typedef DirectMcpAppMessageHandler = FutureOr<void> Function(
  DirectMcpAppInboundMessage message,
);

/// Debug-only containment spike. MCP Apps capability negotiation remains off.
final class DirectMcpAppView extends StatefulWidget {
  const DirectMcpAppView({
    required this.serverId,
    required this.generation,
    required this.html,
    required this.resourcePolicy,
    required this.protocol,
    required this.onMessage,
    this.onRejected,
    super.key,
  });

  final String serverId;
  final int generation;
  final String html;
  final DirectMcpAppResourcePolicy resourcePolicy;

  /// A generation-bound instance; changed sessions must provide a new one.
  final DirectMcpAppsProtocol protocol;
  final DirectMcpAppMessageHandler onMessage;
  final ValueChanged<String>? onRejected;

  @override
  State<DirectMcpAppView> createState() => _DirectMcpAppViewState();
}

final class _DirectMcpAppViewState extends State<DirectMcpAppView> {
  InAppWebViewController? _controller;
  late Uri _documentUrl;
  late String _bridgeName;
  late String _bridgeToken;
  var _session = 0;
  var _initialNavigationAllowed = true;

  @override
  void initState() {
    super.initState();
    _resetSession();
  }

  @override
  void didUpdateWidget(covariant DirectMcpAppView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.generation == widget.generation) {
      return;
    }
    assert(
      !identical(oldWidget.protocol, widget.protocol),
      'A changed MCP App session requires a new protocol instance.',
    );
    _destroySession(oldWidget.protocol);
    _resetSession();
  }

  @override
  void dispose() {
    _destroySession(widget.protocol);
    super.dispose();
  }

  void _resetSession() {
    final originToken = _randomHexToken(18);
    _documentUrl = Uri.parse('https://$originToken.mcp-app.invalid/index.html');
    _bridgeName = 'conduit_mcp_app_${_randomToken(18)}';
    _bridgeToken = _randomToken(32);
    _initialNavigationAllowed = true;
    _session++;
  }

  void _destroySession(DirectMcpAppsProtocol protocol) {
    _session++;
    protocol.close();
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeJavaScriptHandler(handlerName: _bridgeName);
    unawaited(controller.stopLoading());
    unawaited(controller.removeAllUserScripts());
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    final session = _session;
    final origin = _documentUrl.origin;
    return InAppWebView(
      key: ValueKey((widget.serverId, widget.generation, session)),
      initialData: InAppWebViewInitialData(
        data: directMcpAppContainedHtml(widget.html, widget.resourcePolicy),
        baseUrl: WebUri(_documentUrl.toString()),
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: directMcpAppBootstrapScript(_bridgeName, _bridgeToken),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: {origin},
        ),
      ]),
      initialSettings: directMcpAppWebViewSettings(origin),
      onWebViewCreated: (controller) {
        if (session != _session) return;
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: _bridgeName,
          callback: (JavaScriptHandlerFunctionData data) async {
            if (session != _session ||
                !directMcpAppBridgeMessageAllowed(
                  data,
                  expectedOrigin: origin,
                  expectedToken: _bridgeToken,
                )) {
              widget.onRejected?.call('bridge');
              return false;
            }
            final payload = data.args[1] as String;
            try {
              await widget.onMessage(widget.protocol.decodeInbound(payload));
              return true;
            } on DirectMcpAppsProtocolException {
              widget.onRejected?.call('protocol');
              return false;
            }
          },
        );
      },
      onLoadStart: (_, url) {
        if (url?.uriValue == _documentUrl) {
          _initialNavigationAllowed = false;
        }
      },
      shouldOverrideUrlLoading: (_, action) async {
        final url = action.request.url?.uriValue;
        if (_initialNavigationAllowed &&
            action.isForMainFrame == true &&
            url == _documentUrl) {
          _initialNavigationAllowed = false;
          return NavigationActionPolicy.ALLOW;
        }
        widget.onRejected?.call('navigation');
        return NavigationActionPolicy.CANCEL;
      },
      shouldInterceptAjaxRequest: (_, request) async {
        if (!directMcpAppNetworkRequestAllowed(
          request.url?.uriValue,
          widget.resourcePolicy.connectDomains,
        )) {
          request.action = AjaxRequestAction.ABORT;
          widget.onRejected?.call('network');
        }
        request.headers = AjaxRequestHeaders({});
        request.withCredentials = false;
        return request;
      },
      shouldInterceptFetchRequest: (_, request) async {
        if (!directMcpAppNetworkRequestAllowed(
          request.url?.uriValue,
          widget.resourcePolicy.connectDomains,
        )) {
          request.action = FetchRequestAction.ABORT;
          widget.onRejected?.call('network');
        }
        request.headers = <String, String>{};
        request.credentials = FetchRequestCredentialDefault(value: 'omit');
        return request;
      },
      shouldInterceptRequest: (_, request) async {
        final url = request.url.uriValue;
        if (url == _documentUrl ||
            directMcpAppNetworkRequestAllowed(
              url,
              widget.resourcePolicy.connectDomains,
            ) ||
            directMcpAppNetworkRequestAllowed(
              url,
              widget.resourcePolicy.resourceDomains,
            ) ||
            directMcpAppNetworkRequestAllowed(
              url,
              widget.resourcePolicy.frameDomains,
            ) ||
            directMcpAppNetworkRequestAllowed(
              url,
              widget.resourcePolicy.baseUriDomains,
            )) {
          return null;
        }
        widget.onRejected?.call('subresource');
        return WebResourceResponse(
          statusCode: 403,
          reasonPhrase: 'Blocked',
          headers: const {},
          contentType: 'text/plain',
          contentEncoding: 'utf-8',
          data: Uint8List(0),
        );
      },
      onCreateWindow: (_, _) async {
        widget.onRejected?.call('popup');
        return false;
      },
      onPermissionRequest: (_, _) async {
        widget.onRejected?.call('permission');
        return PermissionResponse(action: PermissionResponseAction.DENY);
      },
      onGeolocationPermissionsShowPrompt: (_, origin) async {
        widget.onRejected?.call('permission');
        return GeolocationPermissionShowPromptResponse(
          origin: origin,
          allow: false,
          retain: false,
        );
      },
      onShowFileChooser: (_, _) async {
        widget.onRejected?.call('file-chooser');
        return ShowFileChooserResponse(handledByClient: true, filePaths: null);
      },
      onDownloadStarting: (_, _) async {
        widget.onRejected?.call('download');
        return DownloadStartResponse(
          action: DownloadStartResponseAction.CANCEL,
          handled: true,
        );
      },
    );
  }
}

InAppWebViewSettings directMcpAppWebViewSettings(String origin) =>
    InAppWebViewSettings(
      javaScriptEnabled: true,
      javaScriptCanOpenWindowsAutomatically: false,
      supportMultipleWindows: false,
      useShouldOverrideUrlLoading: true,
      useShouldInterceptAjaxRequest: true,
      useShouldInterceptFetchRequest: true,
      useShouldInterceptRequest: true,
      useOnDownloadStart: true,
      useOnShowFileChooser: true,
      incognito: true,
      cacheEnabled: false,
      domStorageEnabled: false,
      databaseEnabled: false,
      sharedCookiesEnabled: false,
      thirdPartyCookiesEnabled: false,
      allowContentAccess: false,
      allowFileAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      mediaPlaybackRequiresUserGesture: true,
      allowsInlineMediaPlayback: false,
      allowsAirPlayForMediaPlayback: false,
      allowsPictureInPictureMediaPlayback: false,
      geolocationEnabled: false,
      disableContextMenu: true,
      allowsLinkPreview: false,
      isInspectable: false,
      javaScriptHandlersForMainFrameOnly: true,
      javaScriptHandlersOriginAllowList: {origin},
    );

String directMcpAppContainedHtml(
  String html,
  DirectMcpAppResourcePolicy policy,
) {
  final csp = <String>[
    "default-src 'none'",
    "script-src 'unsafe-inline' ${policy.resourceDomains.join(' ')}".trim(),
    "style-src 'unsafe-inline' ${policy.resourceDomains.join(' ')}".trim(),
    _cspDirective('img-src', policy.resourceDomains),
    _cspDirective('font-src', policy.resourceDomains),
    _cspDirective('media-src', policy.resourceDomains),
    _cspDirective('connect-src', policy.connectDomains),
    _cspDirective('frame-src', policy.frameDomains),
    _cspDirective('child-src', policy.frameDomains),
    _cspDirective('base-uri', policy.baseUriDomains),
    "worker-src 'none'",
    "object-src 'none'",
    "manifest-src 'none'",
    "form-action 'none'",
  ].join('; ');
  final escaped = csp
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;');
  return '<meta http-equiv="X-DNS-Prefetch-Control" content="off">'
      '<meta http-equiv="Content-Security-Policy" content="$escaped">$html';
}

String _cspDirective(String name, List<String> domains) =>
    domains.isEmpty ? "$name 'none'" : '$name ${domains.join(' ')}';

bool directMcpAppNetworkRequestAllowed(Uri? target, List<String> allowlist) {
  if (target == null || target.userInfo.isNotEmpty) return false;
  return allowlist.any((allowed) {
    final wildcard = allowed.contains('://*.');
    final parsed = Uri.tryParse(
      wildcard ? allowed.replaceFirst('://*.', '://wildcard.') : allowed,
    );
    if (parsed == null) return false;
    if (target.scheme != parsed.scheme || target.port != parsed.port) {
      return false;
    }
    if (!wildcard) return target.host == parsed.host;
    final suffix = parsed.host.substring('wildcard'.length);
    return target.host.endsWith(suffix) && target.host.length > suffix.length;
  });
}

bool directMcpAppBridgeMessageAllowed(
  JavaScriptHandlerFunctionData data, {
  required String expectedOrigin,
  required String expectedToken,
}) {
  final request = data.requestUrl.uriValue;
  return data.isMainFrame &&
      data.origin.uriValue.origin == expectedOrigin &&
      request.origin == expectedOrigin &&
      data.args.length == 2 &&
      data.args[0] == expectedToken &&
      data.args[1] is String;
}

String directMcpAppBootstrapScript(String bridgeName, String bridgeToken) =>
    '''
(() => {
  'use strict';
  const bridgeName = ${jsonEncode(bridgeName)};
  const bridgeToken = ${jsonEncode(bridgeToken)};
  const queue = [];
  const deliver = (message) => {
    let payload;
    try { payload = JSON.stringify(message); } catch (_) { return; }
    const bridge = window.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      bridge.callHandler(bridgeName, bridgeToken, payload);
    } else {
      queue.push(message);
    }
  };
  window.postMessage = deliver;
  window.addEventListener('flutterInAppWebViewPlatformReady', () => {
    while (queue.length) deliver(queue.shift());
  }, {once: true});
  window.open = () => null;
  history.pushState = () => {};
  history.replaceState = () => {};
  addEventListener('click', (event) => {
    const target = event.target && event.target.closest;
    if (target && (event.target.closest('a') || event.target.closest('input[type=file]'))) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);
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
    replace(navigator.clipboard, 'write', denied);
    replace(navigator.clipboard, 'writeText', denied);
  }
  if (navigator.mediaDevices) replace(navigator.mediaDevices, 'getUserMedia', denied);
  if (navigator.geolocation) {
    replace(navigator.geolocation, 'getCurrentPosition', (_, error) => error && error({code: 1}));
    replace(navigator.geolocation, 'watchPosition', (_, error) => { error && error({code: 1}); return 0; });
  }
  replace(window, 'showOpenFilePicker', denied);
  replace(navigator, 'share', denied);
  addEventListener('copy', (event) => event.preventDefault(), true);
  addEventListener('cut', (event) => event.preventDefault(), true);
  addEventListener('paste', (event) => event.preventDefault(), true);
  const disableFileInputs = () => {
    document.querySelectorAll('input[type=file]').forEach((input) => input.disabled = true);
  };
  new MutationObserver(disableFileInputs).observe(document, {subtree: true, childList: true});
  addEventListener('DOMContentLoaded', disableFileInputs, {once: true});
})();
''';

String _randomToken(int bytes) {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

String _randomHexToken(int bytes) {
  final random = Random.secure();
  return List<int>.generate(
    bytes,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
