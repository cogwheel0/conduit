import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_rest_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';

import 'hermes_dashboard_cookie_store.dart';

/// The dashboard REST bridge over a headless `flutter_inappwebview` page.
/// When the page opens, how requests queue and what counts as an answer is
/// conduit_core's [HermesDashboardRestSession].
final class HermesDashboardRestBridge implements HermesDashboardBridge {
  factory HermesDashboardRestBridge({
    required HermesConfig config,
    required Uri root,
  }) {
    final origin = root.toString();
    final generation = HermesDashboardCookieStore.begin(origin);
    final baseline = HermesDashboardCookieStore.snapshot(origin);
    return HermesDashboardRestBridge._(
      HermesDashboardRestSession(
        root: root,
        accessHeaders: config.accessHeaders,
        openPage: _HeadlessDashboardPage.new,
        beforeOpen: () => baseline,
        afterResponse: () async => HermesDashboardCookieStore.register(
          origin,
          generation: generation,
          baseline: await baseline,
        ),
      ),
    );
  }

  HermesDashboardRestBridge._(this._session);

  final HermesDashboardRestSession _session;

  @override
  Future<({int status, String body})> request(
    String method,
    Uri uri, {
    String? body,
  }) => _session.request(method, uri, body: body);

  @override
  Future<void> reload() => _session.reload();

  @override
  Future<void> close() => _session.close();
}

final class _HeadlessDashboardPage implements HermesDashboardPage {
  _HeadlessDashboardPage(Uri root, Map<String, String> headers) {
    _webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(root.toString()),
        headers: headers,
      ),
      onWebViewCreated: (controller) => _controller = controller,
      onLoadStop: (controller, url) {
        final loaded = Uri.tryParse(url?.toString() ?? '');
        if (loaded != null &&
            hermesDashboardIsExactOrigin(loaded, root) &&
            !_loaded.isCompleted) {
          _loaded.complete();
        }
      },
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame == true && !_loaded.isCompleted) {
          _loaded.completeError(StateError('Hermes dashboard could not load.'));
        }
      },
    );
    _webView.run().catchError((Object error, StackTrace stackTrace) {
      if (!_loaded.isCompleted) _loaded.completeError(error, stackTrace);
    });
  }

  late final HeadlessInAppWebView _webView;
  InAppWebViewController? _controller;
  final Completer<void> _loaded = Completer<void>();

  @override
  Future<void> get loaded => _loaded.future;

  InAppWebViewController get _live =>
      _controller ?? (throw StateError('Hermes dashboard is not loaded.'));

  @override
  Future<Object?> callAsyncJavaScript(
    String functionBody,
    Map<String, Object?> arguments,
  ) async {
    final result = await _live.callAsyncJavaScript(
      functionBody: functionBody,
      arguments: arguments,
    );
    if (result?.error != null) {
      throw StateError('Hermes dashboard request failed.');
    }
    return result?.value;
  }

  @override
  Future<Object?> evaluateJavaScript(String source) =>
      _live.evaluateJavascript(source: source);

  @override
  Future<void> reload() => _live.reload();

  @override
  Future<void> dispose() => _webView.dispose();
}
