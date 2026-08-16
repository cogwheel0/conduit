import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/hermes_config.dart';
import 'hermes_dashboard_cookie_store.dart';

final class HermesDashboardRestBridge {
  HermesDashboardRestBridge({required this.config, required Uri root})
    : _root = root,
      _cookieGeneration = HermesDashboardCookieStore.begin(root.toString()),
      _cookieBaseline = HermesDashboardCookieStore.snapshot(root.toString());

  final HermesConfig config;
  final Uri _root;
  final int _cookieGeneration;
  final Future<Set<String>> _cookieBaseline;
  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Future<void> _tail = Future<void>.value();

  Future<({int status, String body})> request(
    String method,
    Uri uri, {
    String? body,
  }) {
    final completer = Completer<({int status, String body})>();
    _tail = _tail.then((_) async {
      try {
        final controller = await _ensureReady();
        final result = await controller.callAsyncJavaScript(
          functionBody: '''
            const response = await fetch(url, {
              method,
              headers,
              credentials: 'include',
              redirect: 'error',
              body: bodyValue
            });
            const size = Number(response.headers.get('content-length') || 0);
            if (size > 4194304) throw new Error('response-too-large');
            const text = await response.text();
            if (text.length > 2097152) throw new Error('response-too-large');
            return {status: response.status, body: text};
          ''',
          arguments: {
            'url': uri.toString(),
            'method': method,
            'headers': {
              ...config.accessHeaders,
              if (body != null) 'Content-Type': 'application/json',
            },
            'bodyValue': body,
          },
        );
        if (result?.error != null || result?.value is! Map) {
          throw StateError('Hermes dashboard request failed.');
        }
        final value = result!.value as Map;
        final status = value['status'];
        if (status is! num) {
          throw StateError('Hermes dashboard returned an invalid status.');
        }
        await HermesDashboardCookieStore.register(
          _root.toString(),
          generation: _cookieGeneration,
          baseline: await _cookieBaseline,
        );
        completer.complete((
          status: status.toInt(),
          body: value['body']?.toString() ?? '',
        ));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<InAppWebViewController> _ensureReady() async {
    final current = _controller;
    if (current != null) return current;
    await _cookieBaseline;
    final ready = Completer<InAppWebViewController>();
    late final HeadlessInAppWebView webView;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(_root.toString()),
        headers: config.accessHeaders,
      ),
      onWebViewCreated: (controller) => _controller = controller,
      onLoadStop: (controller, url) {
        final loaded = Uri.tryParse(url?.toString() ?? '');
        if (loaded != null && _isExactOrigin(loaded) && !ready.isCompleted) {
          ready.complete(controller);
        }
      },
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame == true && !ready.isCompleted) {
          ready.completeError(StateError('Hermes dashboard could not load.'));
        }
      },
    );
    _webView = webView;
    await webView.run();
    return ready.future.timeout(const Duration(seconds: 15));
  }

  bool _isExactOrigin(Uri uri) =>
      uri.scheme.toLowerCase() == _root.scheme.toLowerCase() &&
      uri.host.toLowerCase() == _root.host.toLowerCase() &&
      uri.port == _root.port;

  Future<void> reload() async {
    await _controller?.reload();
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> close() async {
    await _tail;
    await _webView?.dispose();
    _webView = null;
    _controller = null;
  }
}
