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

  /// The main frame's current URL, or null before the first load.
  Future<Uri?> currentUrl();

  /// Starts reloading the page.
  Future<void> reload();

  Future<void> dispose();
}

/// Opens a hidden page on [root], loaded with [headers]. The page must add
/// [headers] to its own dashboard requests natively or through
/// [hermesDashboardRequestHeaderScript]; requests never pass them as script
/// arguments.
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
        // The page refuses main-frame navigations off the dashboard; this
        // also catches one that got through, before a request runs there.
        final current = await page.currentUrl();
        if (current == null || !hermesDashboardIsExactOrigin(current, _root)) {
          await _discard(page);
          throw StateError('Hermes dashboard page left the dashboard.');
        }
        final Object? value;
        try {
          value = await page
              .callAsyncJavaScript(kHermesDashboardFetchScript, {
                'url': uri.toString(),
                'method': method,
                // Never the access headers: arguments reach the page's own
                // JavaScript. The page's header script (non-GET) or the
                // host's native GET rule adds them.
                'headers': {
                  if (body != null) 'Content-Type': 'application/json',
                },
                'bodyValue': body,
              })
              .timeout(requestTimeout);
        } on TimeoutException {
          // The fetch is still running in the page. Letting the queue move
          // on would overlap it with the next request, or reorder a write,
          // so the page is closed (which ends the fetch) and the next
          // request opens a fresh one.
          await _discard(page);
          rethrow;
        }
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
      await _discard(page);
      rethrow;
    }
  }

  Future<void> _discard(HermesDashboardPage page) async {
    if (identical(_page, page)) {
      _page = null;
      _ready = null;
    }
    await page.dispose();
  }

  /// Reloads the page once the requests already queued have finished, and
  /// keeps those queued after it behind it, so a reload never interrupts a
  /// fetch or the polling of another reload.
  @override
  Future<void> reload() {
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        final page = _page;
        if (page != null) {
          await page.reload();
          await Future<void>(() async {
            while (await page.evaluateJavaScript('document.readyState') !=
                'complete') {
              await Future<void>.delayed(readyStatePoll);
            }
          }).timeout(reloadTimeout);
        }
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
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
