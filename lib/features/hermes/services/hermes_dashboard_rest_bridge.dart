import 'dart:async';
import 'dart:collection';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_rest_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';

import 'hermes_dashboard_cookie_store.dart';
import 'hermes_dashboard_webview_policy.dart';

/// The dashboard REST bridge over a headless `flutter_inappwebview` page.
/// When the page opens, how requests queue and what counts as an answer is
/// conduit_core's [HermesDashboardRestSession].
final class HermesDashboardRestBridge implements HermesDashboardBridge {
  factory HermesDashboardRestBridge({
    required Uri root,
    required Map<String, String> accessHeaders,
  }) {
    final origin = root.toString();
    final generation = HermesDashboardCookieStore.begin(origin);
    final baseline = HermesDashboardCookieStore.snapshot(origin);
    return HermesDashboardRestBridge._(
      HermesDashboardRestSession(
        root: root,
        accessHeaders: accessHeaders,
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

/// The hidden page adds the access headers to its dashboard requests as the
/// sign-in page does ([HermesDashboardWebViewPolicy]: GETs natively, other
/// methods through the fetch/XHR script); requests never pass them as
/// script arguments.
final class _HeadlessDashboardPage implements HermesDashboardPage {
  _HeadlessDashboardPage(Uri root, Map<String, String> headers)
    : _policy = HermesDashboardWebViewPolicy(
        root: root,
        accessHeaders: headers,
      ) {
    _webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(root.toString()),
        headers: headers,
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldInterceptRequest: headers.isNotEmpty,
        useShouldOverrideUrlLoading: true,
      ),
      // The main frame never leaves the dashboard's exact origin.
      shouldOverrideUrlLoading: (_, action) async =>
          hermesDashboardRestPageAllowsNavigation(
            target: action.request.url?.uriValue,
            isMainFrame: action.isForMainFrame != false,
            root: root,
          )
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL,
      initialUserScripts: UnmodifiableListView(_policy.userScripts),
      shouldInterceptRequest: (_, request) =>
          _policy.interceptSubresource(request),
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

  final HermesDashboardWebViewPolicy _policy;
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
  Future<Uri?> currentUrl() async => (await _live.getUrl())?.uriValue;

  @override
  Future<void> reload() => _live.reload();

  @override
  Future<void> dispose() async {
    await _webView.dispose();
    _policy.close();
  }
}
