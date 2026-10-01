/// The state machine of the dashboard REST bridge: one hidden page, opened
/// on the first request, that issues requests one at a time with the
/// dashboard's cookies.
///
/// The app supplies the page ([HermesDashboardPage]) from its WebView;
/// this class decides when it opens, how a failed open resets, the order of
/// requests, what counts as a valid answer, and when the page closes.
library;

import 'dart:async';

import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';

/// A hidden WebView page on the dashboard root.
abstract interface class HermesDashboardPage {
  /// Completes when the page finished loading on the dashboard's exact
  /// origin, or fails when its main frame could not load.
  Future<void> get loaded;

  /// Runs [functionBody] as the body of an async function with [arguments]
  /// as its parameters, and answers its result. Throws when the script
  /// throws.
  Future<Object?> callAsyncJavaScript(
    String functionBody,
    Map<String, Object?> arguments,
  );

  /// Evaluates [source] and answers its value.
  Future<Object?> evaluateJavaScript(String source);

  /// Starts reloading the page.
  Future<void> reload();

  Future<void> dispose();
}

/// Opens a hidden page on [root], loaded with [headers].
typedef HermesDashboardPageFactory = HermesDashboardPage Function(
  Uri root,
  Map<String, String> headers,
);

final class HermesDashboardRestSession implements HermesDashboardBridge {
  HermesDashboardRestSession({
    required Uri root,
    required Map<String, String> accessHeaders,
    required HermesDashboardPageFactory openPage,
    Future<void> Function()? beforeOpen,
    Future<void> Function()? afterResponse,
    this.openTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 30),
    this.reloadTimeout = const Duration(seconds: 15),
    this.readyStatePoll = const Duration(milliseconds: 50),
  }) : _root = root,
       _accessHeaders = Map.unmodifiable(accessHeaders),
       _openPage = openPage,
       _beforeOpen = beforeOpen,
       _afterResponse = afterResponse;

  final Uri _root;
  final Map<String, String> _accessHeaders;
  final HermesDashboardPageFactory _openPage;

  /// Runs before the page opens (the cookie baseline snapshot).
  final Future<void> Function()? _beforeOpen;

  /// Runs after each valid answer, before it is returned (cookie recording).
  final Future<void> Function()? _afterResponse;

  final Duration openTimeout;
  final Duration requestTimeout;
  final Duration reloadTimeout;
  final Duration readyStatePoll;

  HermesDashboardPage? _page;
  Future<HermesDashboardPage>? _ready;
  Future<void> _tail = Future<void>.value();

  /// Whether a page is open or opening.
  bool get isOpen => _ready != null;

  @override
  Future<({int status, String body})> request(
    String method,
    Uri uri, {
    String? body,
  }) {
    final completer = Completer<({int status, String body})>();
    _tail = _tail.then((_) async {
      try {
        final page = await _ensureReady();
        final value = await page
            .callAsyncJavaScript(kHermesDashboardFetchScript, {
              'url': uri.toString(),
              'method': method,
              'headers': {
                ..._accessHeaders,
                if (body != null) 'Content-Type': 'application/json',
              },
              'bodyValue': body,
            })
            .timeout(requestTimeout);
        final result = parseHermesDashboardFetchResult(value);
        await _afterResponse?.call();
        completer.complete(result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<HermesDashboardPage> _ensureReady() async {
    final current = _ready;
    if (current != null) return current;
    await _beforeOpen?.call();
    final page = _openPage(_root, _accessHeaders);
    _page = page;
    final ready = page.loaded.then((_) => page).timeout(openTimeout);
    _ready = ready;
    try {
      return await ready;
    } catch (_) {
      // A page that never loaded is closed, and the next request opens a
      // fresh one.
      if (identical(_page, page)) {
        _page = null;
        _ready = null;
      }
      await page.dispose();
      rethrow;
    }
  }

  @override
  Future<void> reload() async {
    final page = _page;
    if (page == null) return;
    await page.reload();
    await Future<void>(() async {
      while (await page.evaluateJavaScript('document.readyState') !=
          'complete') {
        await Future<void>.delayed(readyStatePoll);
      }
    }).timeout(reloadTimeout);
  }

  @override
  Future<void> close() async {
    await _tail;
    final page = _page;
    _page = null;
    _ready = null;
    await page?.dispose();
  }
}

/// The `{status, body}` answer of [kHermesDashboardFetchScript]. Throws a
/// [StateError] for anything else.
({int status, String body}) parseHermesDashboardFetchResult(Object? value) {
  if (value is! Map) {
    throw StateError('Hermes dashboard request failed.');
  }
  final status = value['status'];
  if (status is! num) {
    throw StateError('Hermes dashboard returned an invalid status.');
  }
  return (status: status.toInt(), body: value['body']?.toString() ?? '');
}
