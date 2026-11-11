import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_rest_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

final class _FakePage implements HermesDashboardPage {
  _FakePage(this.root, this.headers);

  final Uri root;
  final Map<String, String> headers;
  final Completer<void> load = Completer<void>();
  final List<Map<String, Object?>> calls = [];
  final List<String> scripts = [];
  final List<String> log = [];
  Object? Function(Map<String, Object?> arguments)? answer;
  List<String> readyStates = ['complete'];
  bool disposed = false;
  Uri? current;

  /// When set, the next call waits for it (a fetch that is slow to answer).
  Completer<void>? hold;

  @override
  Future<Uri?> currentUrl() async => current ?? root;

  @override
  Future<void> get loaded => load.future;

  @override
  Future<Object?> callAsyncJavaScript(
    String functionBody,
    Map<String, Object?> arguments,
  ) async {
    check([
      kHermesDashboardFetchScript,
      kHermesDashboardSignOutScript,
    ]).contains(functionBody);
    scripts.add(functionBody);
    calls.add(arguments);
    log.add('call ${arguments['url']}');
    await Future<void>.delayed(Duration.zero);
    await hold?.future;
    final respond = answer;
    return respond == null
        ? {'status': 200, 'body': '${arguments['url']}'}
        : respond(arguments);
  }

  @override
  Future<Object?> evaluateJavaScript(String source) async {
    check(source).equals('document.readyState');
    return readyStates.length > 1 ? readyStates.removeAt(0) : readyStates.first;
  }

  /// When set, [reload] waits for it (a reload that never finishes).
  Completer<void>? reloadHold;

  @override
  Future<void> reload() async {
    log.add('reload');
    await reloadHold?.future;
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  final root = Uri.parse('https://hermes.example');
  const access = {'CF-Access-Client-Id': 'id'};

  late List<_FakePage> pages;
  late List<String> events;

  HermesDashboardRestSession session({
    bool loadImmediately = true,
    Duration openTimeout = const Duration(seconds: 15),
    Duration requestTimeout = const Duration(seconds: 30),
    Duration reloadTimeout = const Duration(seconds: 10),
  }) => HermesDashboardRestSession(
    root: root,
    accessHeaders: access,
    openTimeout: openTimeout,
    requestTimeout: requestTimeout,
    reloadTimeout: reloadTimeout,
    readyStatePoll: Duration.zero,
    beforeOpen: () async => events.add('baseline'),
    afterResponse: () async => events.add('record'),
    openPage: (root, headers) {
      final page = _FakePage(root, headers);
      pages.add(page);
      events.add('open');
      if (loadImmediately) page.load.complete();
      return page;
    },
  );

  setUp(() {
    pages = [];
    events = [];
  });

  test('opens one page lazily and reuses it', () async {
    final bridge = session();
    check(bridge.isOpen).isFalse();
    check(pages).isEmpty();

    final first = await bridge.request(
      'GET',
      Uri.parse('https://hermes.example/api/profiles'),
    );
    final second = await bridge.request(
      'POST',
      Uri.parse('https://hermes.example/api/x'),
      body: '{"a":1}',
    );

    check(pages).length.equals(1);
    check(pages.single.root).equals(root);
    check(pages.single.headers).deepEquals(access);
    check(first.status).equals(200);
    check(first.body).equals('https://hermes.example/api/profiles');
    check(second.body).equals('https://hermes.example/api/x');
    check(events).deepEquals(['baseline', 'open', 'record', 'record']);
    // The access headers load the page natively and are never script
    // arguments, which the page's own JavaScript could read.
    check(pages.single.calls.first).deepEquals({
      'url': 'https://hermes.example/api/profiles',
      'method': 'GET',
      'headers': <String, String>{},
      'bodyValue': null,
    });
    check(pages.single.calls.last).deepEquals({
      'url': 'https://hermes.example/api/x',
      'method': 'POST',
      'headers': {'Content-Type': 'application/json'},
      'bodyValue': '{"a":1}',
    });
  });

  test('refuses to run a request once the page left the dashboard', () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/api/a'));
    final first = pages.single;
    first.current = Uri.parse('https://identity.example/login');

    await check(
      bridge.request('GET', Uri.parse('https://hermes.example/api/b')),
    ).throws<StateError>();
    // Nothing ran on the other origin; the page is closed and the next
    // request opens a fresh one on the dashboard.
    check(first.calls).length.equals(1);
    check(first.disposed).isTrue();

    final next = await bridge.request(
      'GET',
      Uri.parse('https://hermes.example/api/c'),
    );
    check(next.body).equals('https://hermes.example/api/c');
    check(pages).length.equals(2);
  });

  test('signs out from the dashboard page it opened', () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/api/a'));
    final page = pages.single;
    page.answer = (arguments) => true;

    check(await bridge.signOut()).isTrue();
    check(page.scripts).deepEquals([
      kHermesDashboardFetchScript,
      kHermesDashboardSignOutScript,
    ]);
    // Only the logout URL: the page's header script adds the access
    // headers, and nothing about the cookies goes to the page.
    check(page.calls.last).deepEquals({
      'url': 'https://hermes.example/auth/logout',
    });
    // No cookies are recorded for a sign-out.
    check(events).deepEquals(['baseline', 'open', 'record']);
  });

  test('a sign-out Hermes refused, or off the dashboard, is not one',
      () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/api/a'));
    final page = pages.single;
    page.answer = (arguments) => false;
    check(await bridge.signOut()).isFalse();

    page.current = Uri.parse('https://identity.example/login');
    await check(bridge.signOut()).throws<StateError>();
    check(page.scripts.where((s) => s == kHermesDashboardSignOutScript))
        .length
        .equals(1);
    check(page.disposed).isTrue();
  });

  // The discard waited for the urgent requests, this one among them: it
  // never settled, and close waited on it for good.
  test('an urgent request that finds the page gone settles', () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/api/a'));
    final first = pages.single;
    first.current = Uri.parse('https://identity.example/login');

    await check(
      bridge
          .request(
            'POST',
            Uri.parse('https://hermes.example/api/stop'),
            urgent: true,
          )
          .timeout(const Duration(seconds: 2)),
    ).throws<StateError>();
    await bridge.close().timeout(const Duration(seconds: 2));
    check(first.calls).length.equals(1);
    check(first.disposed).isTrue();
  });

  test('runs requests one at a time, in order', () async {
    final bridge = session();
    final results = await Future.wait([
      for (final path in ['/a', '/b', '/c'])
        bridge.request('GET', Uri.parse('https://hermes.example$path')),
    ]);
    check(results.map((result) => result.body))
        .deepEquals(['/a', '/b', '/c'].map((p) => 'https://hermes.example$p'));
    check(pages.single.log).deepEquals([
      'call https://hermes.example/a',
      'call https://hermes.example/b',
      'call https://hermes.example/c',
    ]);
  });

  test('an urgent request does not wait behind a long one', () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/warm'));
    final page = pages.single;
    final held = page.hold = Completer<void>();
    final trigger = bridge.request(
      'POST',
      Uri.parse('https://hermes.example/trigger'),
    );
    await pumpEventQueue();
    // Only the trigger is slow to answer.
    page.hold = null;
    var triggerDone = false;
    unawaited(trigger.then((_) => triggerDone = true));

    final cancel = await bridge.request(
      'POST',
      Uri.parse('https://hermes.example/cancel'),
      urgent: true,
    );
    check(cancel.body).equals('https://hermes.example/cancel');
    check(triggerDone).isFalse();

    held.complete();
    check((await trigger).body).equals('https://hermes.example/trigger');
    check(pages).length.equals(1);
    check(page.disposed).isFalse();
  });

  test('a queued request withdrawn before its turn is never sent', () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/warm'));
    final page = pages.single;
    final held = page.hold = Completer<void>();
    final first = bridge.request(
      'POST',
      Uri.parse('https://hermes.example/run-a'),
    );
    await pumpEventQueue();
    page.hold = null;
    var withdrawn = false;
    final second = bridge.request(
      'POST',
      Uri.parse('https://hermes.example/run-b'),
      beforeSend: () => !withdrawn,
    );

    // A Stop overtakes it while the first holds the queue.
    withdrawn = true;
    held.complete();
    await first;

    await check(second).throws<HermesDashboardRequestWithdrawn>();
    check(page.log).not(
      (it) => it.contains('call https://hermes.example/run-b'),
    );
  });

  // In fake time: on a loaded runner, real delays could pass Stop's own
  // deadline or land before the trigger's.
  test('a timed-out trigger leaves Stop its page until it answers', () {
    fakeAsync((async) {
      final bridge = session(requestTimeout: const Duration(seconds: 1));
      unawaited(bridge.request('GET', Uri.parse('https://hermes.example/w')));
      async.elapse(Duration.zero);
      final page = pages.single;
      final held = page.hold = Completer<void>();
      // Run now holds the queue; Stop goes out beside it, just before Run
      // now's deadline.
      Object? triggerError;
      bridge
          .request('POST', Uri.parse('https://hermes.example/trigger'))
          .then(
            (_) {},
            onError: (Object error) {
              triggerError = error;
            },
          );
      async.elapse(const Duration(milliseconds: 900));
      int? stopStatus;
      bridge
          .request(
            'POST',
            Uri.parse('https://hermes.example/cancel'),
            urgent: true,
          )
          .then((answer) => stopStatus = answer.status);
      async.elapse(Duration.zero);

      // Past the trigger's deadline: its page is left, not yet closed, and
      // the trigger fails once Stop has its answer.
      async.elapse(const Duration(milliseconds: 200));
      check(page.disposed).isFalse();
      check(stopStatus).isNull();

      held.complete();
      async.elapse(Duration.zero);
      check(stopStatus).equals(200);
      check(triggerError).isA<TimeoutException>();
      check(page.disposed).isTrue();
    });
  });

  test('close waits for an urgent request still answering', () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/warm'));
    final page = pages.single;
    final held = page.hold = Completer<void>();
    final stop = bridge.request(
      'POST',
      Uri.parse('https://hermes.example/cancel'),
      urgent: true,
    );
    await pumpEventQueue();

    var closed = false;
    final closing = bridge.close().then((_) => closed = true);
    await pumpEventQueue();
    check(closed).isFalse();
    check(page.disposed).isFalse();

    held.complete();
    check((await stop).status).equals(200);
    await closing;
    check(page.disposed).isTrue();
  });

  test('an urgent request on a closed bridge opens it in order', () async {
    final bridge = session();
    final first = bridge.request('GET', Uri.parse('https://hermes.example/a'));
    final urgent = bridge.request(
      'POST',
      Uri.parse('https://hermes.example/b'),
      urgent: true,
    );
    await Future.wait([first, urgent]);
    check(pages).length.equals(1);
    check(pages.single.log).deepEquals([
      'call https://hermes.example/a',
      'call https://hermes.example/b',
    ]);
  });

  test('an urgent request that times out keeps the page', () async {
    final bridge = session(requestTimeout: const Duration(milliseconds: 20));
    await bridge.request('GET', Uri.parse('https://hermes.example/warm'));
    final page = pages.single;
    final held = page.hold = Completer<void>();
    await check(
      bridge.request(
        'POST',
        Uri.parse('https://hermes.example/cancel'),
        urgent: true,
      ),
    ).throws<TimeoutException>();
    check(page.disposed).isFalse();
    page.hold = null;
    held.complete();
    check(
      (await bridge.request('GET', Uri.parse('https://hermes.example/n'))).body,
    ).equals('https://hermes.example/n');
    check(pages).length.equals(1);
  });

  test(
    'a page that fails to load is closed and the next request retries',
    () async {
      final bridge = session(loadImmediately: false);
      final failed = bridge.request(
        'GET',
        Uri.parse('https://hermes.example/a'),
      );
      await Future<void>.delayed(Duration.zero);
      pages.single.load.completeError(StateError('main frame failed'));
      await check(failed).throws<StateError>();
      check(pages.single.disposed).isTrue();
      check(bridge.isOpen).isFalse();

      final retry = bridge.request(
        'GET',
        Uri.parse('https://hermes.example/b'),
      );
      await Future<void>.delayed(Duration.zero);
      check(pages).length.equals(2);
      pages.last.load.complete();
      check((await retry).status).equals(200);
      check(events)
          .deepEquals(['baseline', 'open', 'baseline', 'open', 'record']);
    },
  );

  test('a page that never loads times out and is closed', () async {
    final bridge = session(
      loadImmediately: false,
      openTimeout: const Duration(milliseconds: 10),
    );
    await check(bridge.request('GET', Uri.parse('https://hermes.example/a')))
        .throws<TimeoutException>();
    check(pages.single.disposed).isTrue();
    check(bridge.isOpen).isFalse();
  });

  test(
    'a request that times out closes the page, and the next one reopens',
    () async {
      final bridge = session(requestTimeout: const Duration(milliseconds: 20));
      await bridge.request('GET', Uri.parse('https://hermes.example/warm'));
      final first = pages.single;
      first.hold = Completer<void>();

      final slow = bridge.request(
        'POST',
        Uri.parse('https://hermes.example/w'),
      );
      final next = bridge.request('GET', Uri.parse('https://hermes.example/n'));

      await check(slow).throws<TimeoutException>();
      // The page that still has the write in flight is gone, not reused.
      check(first.disposed).isTrue();
      check((await next).body).equals('https://hermes.example/n');
      check(pages).length.equals(2);
      check(pages.last.log).deepEquals(['call https://hermes.example/n']);
      first.hold!.complete();
    },
  );

  test(
    'reload waits for queued requests and holds later ones behind it',
    () async {
      final bridge = session();
      await bridge.request('GET', Uri.parse('https://hermes.example/warm'));
      final page = pages.single;
      page.log.clear();
      page.hold = Completer<void>();

      final inFlight = bridge.request(
        'GET',
        Uri.parse('https://hermes.example/a'),
      );
      final reloaded = bridge.reload();
      final after = bridge.request(
        'GET',
        Uri.parse('https://hermes.example/b'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The reload has not interrupted the fetch that was running.
      check(page.log).deepEquals(['call https://hermes.example/a']);
      page.hold!.complete();
      await inFlight;
      await reloaded;
      await after;

      check(page.log).deepEquals([
        'call https://hermes.example/a',
        'reload',
        'call https://hermes.example/b',
      ]);
    },
  );

  test('a reload that never finishes times out and closes the page', () async {
    final bridge = session(reloadTimeout: const Duration(milliseconds: 20));
    await bridge.request('GET', Uri.parse('https://hermes.example/warm'));
    final first = pages.single;
    first.reloadHold = Completer<void>();

    final reloaded = bridge.reload();
    final after = bridge.request('GET', Uri.parse('https://hermes.example/n'));

    await check(reloaded).throws<TimeoutException>();
    // The queue moved on, onto a fresh page rather than the one in doubt.
    check(first.disposed).isTrue();
    check((await after).body).equals('https://hermes.example/n');
    check(pages).length.equals(2);
    first.reloadHold!.complete();
  });

  test('refuses answers that are not a status and body', () async {
    final bridge = session();
    await bridge.request('GET', Uri.parse('https://hermes.example/open'));
    for (final bad in <Object?>[
      null,
      'text',
      {'status': '200'},
      {'body': 'x'},
    ]) {
      pages.single.answer = (_) => bad;
      await check(
        because: '$bad',
        bridge.request('GET', Uri.parse('https://hermes.example/')),
      ).throws<StateError>();
    }
    // Only the valid answer was recorded.
    check(events.where((event) => event == 'record')).length.equals(1);
    // A failed request does not poison the queue.
    pages.single.answer = null;
    check(
      (await bridge.request(
        'GET',
        Uri.parse('https://hermes.example/ok'),
      )).status,
    ).equals(200);
  });

  test('parses status and body leniently', () {
    check(parseHermesDashboardFetchResult({'status': 201.0, 'body': 7}))
        .equals((status: 201, body: '7'));
    check(parseHermesDashboardFetchResult({'status': 204}))
        .equals((status: 204, body: ''));
  });

  test('reload waits for the document and is a no-op before opening', () async {
    final bridge = session();
    await bridge.reload();
    check(pages).isEmpty();

    await bridge.request('GET', Uri.parse('https://hermes.example/a'));
    pages.single.readyStates = ['loading', 'interactive', 'complete'];
    await bridge.reload();
    check(pages.single.log.last).equals('reload');
    check(pages.single.readyStates).deepEquals(['complete']);
  });

  test('close waits for queued requests, then disposes the page', () async {
    final bridge = session();
    final pending = bridge.request(
      'GET',
      Uri.parse('https://hermes.example/a'),
    );
    final closed = bridge.close();
    check((await pending).status).equals(200);
    await closed;
    check(pages.single.disposed).isTrue();
    check(bridge.isOpen).isFalse();

    // A request after close opens a new page.
    await bridge.request('GET', Uri.parse('https://hermes.example/b'));
    check(pages).length.equals(2);
  });
}
