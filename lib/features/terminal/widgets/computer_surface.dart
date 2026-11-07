import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Commands are scoped to one mounted viewer; no credentials or pixels persist.
class ComputerSurfaceController {
  InAppWebViewController? _web;

  Future<void> _call(String name, Object? value) async {
    final web = _web;
    if (web == null) return;
    await web.evaluateJavascript(
      source: 'window.computer?.$name(${jsonEncode(value)})',
    );
  }

  Future<void> control(bool enabled) => _call('control', enabled);
  Future<void> command(Map<String, Object?> command) =>
      _call('command', command);
  Future<void> zoom(bool enabled) => _call('zoom', enabled);
  Future<void> visibility(bool visible) => _call('visibility', visible);
  Future<void> reconnect() => _call('reconnect', null);
  Future<void> audio(bool enabled) => _call('audio', enabled);
  Future<void> display(String quality, bool desktopSite) =>
      _call('display', {'quality': quality, 'desktopSite': desktopSite});
}

class ComputerSurfaceView extends StatefulWidget {
  const ComputerSurfaceView({
    super.key,
    required this.connection,
    required this.controller,
    required this.onState,
  });

  final ComputerConnection connection;
  final ComputerSurfaceController controller;
  final ValueChanged<Map<String, dynamic>> onState;

  @override
  State<ComputerSurfaceView> createState() => _ComputerSurfaceViewState();
}

class _ComputerSurfaceViewState extends State<ComputerSurfaceView> {
  late final _origin = widget.connection.streamUri.scheme == 'wss'
      ? 'https://computer.conduit.invalid'
      : 'http://computer.conduit.invalid';
  late final Future<String> _document = _load();
  bool _started = false;
  Size? _lastSize;
  InAppWebViewController? _web;

  Map<String, Object> _viewport(Size size) => {
    'width': size.width.round().clamp(320, 1280),
    'height': size.height.round().clamp(240, 1080),
    'mobile': size.width < 600,
  };

  Future<String> _load() async {
    final script = await rootBundle.loadString('assets/computer/viewer.js');
    final uri = widget.connection.streamUri;
    final allowed = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
    return '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=3">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob: data:; media-src blob:; connect-src $allowed data:; base-uri 'none'; form-action 'none'">
<style>
html,body{margin:0;width:100%;height:100%;background:#111318;overflow:auto;overscroll-behavior:none}
#surface{width:100%;height:100%;display:flex;align-items:center;justify-content:center;overflow:auto}
#surface.zoomed{align-items:flex-start;justify-content:flex-start}
#frame{display:block;max-width:100%;max-height:100%;object-fit:contain;flex-shrink:0}
#frame.zoomed{max-width:none;max-height:none;width:200%;align-self:flex-start}
</style></head><body><div id="surface"><canvas id="frame" width="1" height="1"></canvas></div>
<script>(async () => {${script.replaceAll('</script', '<\\/script')} })();</script></body></html>''';
  }

  @override
  void dispose() {
    final web = _web;
    if (identical(widget.controller._web, web)) widget.controller._web = null;
    web?.removeJavaScriptHandler(handlerName: 'computer');
    if (web != null) {
      unawaited(
        web
            .evaluateJavascript(source: 'window.computer?.dispose()')
            .catchError((_) => null),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_lastSize != size) {
        _lastSize = size;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _started) {
            unawaited(widget.controller._call('viewport', _viewport(size)));
          }
        });
      }
      return FutureBuilder<String>(
        future: _document,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const SizedBox.expand();
          return InAppWebView(
            initialData: InAppWebViewInitialData(
              data: snapshot.requireData,
              baseUrl: WebUri('$_origin/index.html'),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
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
              useShouldOverrideUrlLoading: true,
              supportMultipleWindows: false,
              javaScriptCanOpenWindowsAutomatically: false,
              disableContextMenu: true,
              allowsLinkPreview: false,
              isInspectable: false,
              transparentBackground: true,
              allowsInlineMediaPlayback: true,
              mediaPlaybackRequiresUserGesture: false,
              javaScriptHandlersForMainFrameOnly: true,
              javaScriptHandlersOriginAllowList: {_origin},
            ),
            onWebViewCreated: (web) {
              _web = web;
              widget.controller._web = web;
              web.addJavaScriptHandler(
                handlerName: 'computer',
                callback: (JavaScriptHandlerFunctionData data) {
                  if (!mounted ||
                      !data.isMainFrame ||
                      data.origin.toString() != _origin ||
                      data.args.length != 1 ||
                      data.args.first is! Map) {
                    return;
                  }
                  widget.onState(
                    Map<String, dynamic>.from(data.args.first as Map),
                  );
                },
              );
            },
            onLoadStop: (web, _) async {
              if (_started || !mounted) return;
              _started = true;
              final size = context.size;
              final config = widget.connection.toViewerConfig();
              if (size != null) {
                config['viewport'] = _viewport(size);
              }
              await web.evaluateJavascript(
                source:
                    '(() => { const start = () => window.computer.start(${jsonEncode(config)}); if (window.computer) start(); else window.addEventListener("computerReady", start, {once:true}); })()',
              );
            },
            shouldOverrideUrlLoading: (_, action) async =>
                !_started &&
                    action.request.url?.toString() == '$_origin/index.html'
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL,
            onCreateWindow: (_, _) async => false,
            onPermissionRequest: (_, _) async =>
                PermissionResponse(action: PermissionResponseAction.DENY),
          );
        },
      );
    },
  );
}
