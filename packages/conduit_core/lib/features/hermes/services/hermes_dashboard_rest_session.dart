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

  /// Urgent requests still running: they hold no queue, so [close] waits
  /// for them before it closes their page.
  final Set<Future<void>> _urgent = {};

  /// Whether a page is open or opening.
  bool get isOpen => _ready != null;

  @override
  Future<({int status, String body})> request(
    String method,
    Uri uri, {
    String? body,
    bool urgent = false,
    bool Function()? beforeSend,
  }) {
    // Opening a page stays the queue's job, so an urgent request skips the
    // queue only once one is open or opening.
    final ready = _ready;
    if (urgent && ready != null) {
      final fetch = _fetch(
        ready,
        method,
        uri,
        body,
        queued: false,
        beforeSend: beforeSend,
      );
      final settled = fetch.then<void>((_) {}, onError: (Object _) {});
      _urgent.add(settled);
      unawaited(settled.whenComplete(() => _urgent.remove(settled)));
      return fetch;
    }
    final completer = Completer<({int status, String body})>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(
          await _fetch(
            _ensureReady(),
            method,
            uri,
            body,
            queued: true,
            beforeSend: beforeSend,
          ),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Signs the page's session out on the server
  /// ([kHermesDashboardSignOutScript]), in turn with the requests; true when
  /// Hermes signed it out.
  Future<bool> signOut() {
    final completer = Completer<bool>();
    _tail = _tail.then((_) async {
      try {
        final page = await _onDashboard(_ensureReady(), queued: true);
        final Object? value;
        try {
          value = await page
              .callAsyncJavaScript(kHermesDashboardSignOutScript, {
                'url': hermesDashboardLogoutUrl(_root).toString(),
              })
              .timeout(requestTimeout);
        } on TimeoutException {
          // As for a request: the page that may still be signing out is
          // closed rather than reused.
          await _discard(page);
          rethrow;
        }
        completer.complete(value == true);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<({int status, String body})> _fetch(
    Future<HermesDashboardPage> ready,
    String method,
    Uri uri,
    String? body, {
    required bool queued,
    bool Function()? beforeSend,
  }) async {
    final page = await _onDashboard(ready, queued: queued);
    // Asked with nothing awaited before the send, so a withdrawal is
    // either seen here or comes after the request went out.
    if (beforeSend?.call() == false) {
      throw const HermesDashboardRequestWithdrawn();
    }
    final Object? value;
    try {
      value = await page
          .callAsyncJavaScript(kHermesDashboardFetchScript, {
            'url': uri.toString(),
            'method': method,
            // Never the access headers: arguments reach the page's own
            // JavaScript. The page's header script (non-GET) or the host's
            // native GET rule adds them.
            'headers': {if (body != null) 'Content-Type': 'application/json'},
            'bodyValue': body,
          })
          .timeout(requestTimeout);
    } on TimeoutException {
      // The fetch is still running in the page. Letting the queue move on
      // would overlap it with the next request, or reorder a write, so the
      // page is closed (which ends the fetch) and the next request opens a
      // fresh one. An urgent request holds no queue, so its page stays.
      if (queued) await _discard(page);
      rethrow;
    }
    final result = parseHermesDashboardFetchResult(value);
    await _afterResponse?.call();
    return result;
  }

  /// [ready]'s page, once it is on the dashboard's exact origin. The page
  /// refuses main-frame navigations off the dashboard; this also catches one
  /// that got through, before anything runs there. Off it, the page is
  /// discarded; a [queued] caller waits for that.
  Future<HermesDashboardPage> _onDashboard(
    Future<HermesDashboardPage> ready, {
    required bool queued,
  }) async {
    final page = await ready;
    final current = await page.currentUrl();
    if (current == null || !hermesDashboardIsExactOrigin(current, _root)) {
      // An urgent request is among those the discard waits for, so it
      // settles first and the page closes after it.
      final discarded = _discard(page);
      if (queued) {
        await discarded;
      } else {
        unawaited(discarded);
      }
      throw StateError('Hermes dashboard page left the dashboard.');
    }
    return page;
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
    // The next request opens a fresh page at once; an urgent request (a
    // Stop) still answering on this one keeps it until it has its answer.
    await Future.wait([..._urgent]);
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
          try {
            // One deadline for the whole reload: starting it and waiting for
            // the document, so neither can hold the queue forever.
            await Future<void>(() async {
              await page.reload();
              while (await page.evaluateJavaScript('document.readyState') !=
                  'complete') {
                await Future<void>.delayed(readyStatePoll);
              }
            }).timeout(reloadTimeout);
          } catch (_) {
            // The page's state is unknown, so no queued request runs on it:
            // it is closed and the next request opens a fresh one.
            await _discard(page);
            rethrow;
          }
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
    // An urgent request (a Stop) still waiting for its answer keeps the
    // page until it has one.
    await Future.wait([..._urgent]);
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
