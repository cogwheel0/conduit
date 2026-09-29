import 'dart:async';
import 'dart:io';

import 'package:conduit_ddgs/conduit_ddgs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

typedef Route = FutureOr<http.Response> Function(http.Request request);

/// A client that answers per engine host and records which hosts were hit.
final class FakeEngines {
  FakeEngines(this.routes);

  final Map<String, Route> routes;
  final List<String> hosts = [];

  late final http.Client client = MockClient((request) async {
    hosts.add(request.url.host);
    final route = routes[request.url.host];
    if (route == null) return http.Response('', 404);
    return route(request);
  });
}

const _ddg = 'html.duckduckgo.com';
const _brave = 'search.brave.com';
const _bing = 'www.bing.com';

http.Response _html(String body, [int status = 200]) => http.Response(
  body,
  status,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

void main() {
  final query = SearchQuery('dart programming language');

  test('Auto falls back past a blocked engine and cools it down', () async {
    var now = DateTime(2026, 9, 29, 12);
    final fake = FakeEngines({
      _ddg: (_) => _html(fixture('duckduckgo_captcha.html'), 202),
      _brave: (_) => _html(fixture('brave_results.html')),
    });
    final ddgs = Ddgs(client: fake.client, clock: () => now);

    final first = await ddgs.search(query, maxResults: 3);
    expect(first.engine, SearchEngineId.brave);
    expect(first.results, hasLength(3));
    expect(first.failures.single.engine, SearchEngineId.duckduckgo);
    expect(first.failures.single.kind, SearchEngineFailureKind.blocked);

    // Within the cooldown DuckDuckGo is not contacted at all.
    await ddgs.search(query);
    expect(fake.hosts.where((h) => h == _ddg), hasLength(1));

    now = now.add(const Duration(minutes: 11));
    await ddgs.search(query);
    expect(fake.hosts.where((h) => h == _ddg), hasLength(2));
  });

  test(
    'a repeated URL keeps its first position and its best description',
    () async {
      final fake = FakeEngines({
        _ddg: (_) => _html(fixture('duckduckgo_results.html')),
      });
      final response = await Ddgs(client: fake.client).search(query);

      final dartDev = response.results
          .where((r) => r.url.host == 'dart.dev' && r.url.path.length <= 1)
          .toList();
      expect(dartDev, hasLength(1));
      expect(response.results.first, same(dartDev.single));
      expect(dartDev.single.title, 'Dart programming language');
    },
  );

  test('an explicitly chosen engine never falls back to another', () async {
    final fake = FakeEngines({
      _bing: (_) => _html('', 429),
      _brave: (_) => _html(fixture('brave_results.html')),
    });
    final ddgs = Ddgs(client: fake.client);

    await expectLater(
      ddgs.search(query, engine: SearchEngineId.bing),
      throwsA(
        isA<WebSearchUnavailableException>().having(
          (e) => e.wasBlocked,
          'wasBlocked',
          isTrue,
        ),
      ),
    );
    expect(fake.hosts, [_bing]);
  });

  test('cancelling stops the search without trying other engines', () async {
    final requested = Completer<void>();
    final fake = FakeEngines({
      _ddg: (_) {
        requested.complete();
        return Completer<http.Response>().future;
      },
      _brave: (_) => _html(fixture('brave_results.html')),
    });
    final cancel = Completer<void>();
    final ddgs = Ddgs(client: fake.client);

    final search = ddgs.search(query, cancel: cancel.future);
    await requested.future;
    cancel.complete();

    await expectLater(search, throwsA(isA<WebSearchCancelledException>()));
    expect(fake.hosts, [_ddg]);
  });

  test('a timed-out engine is skipped and not cooled down', () async {
    final fake = FakeEngines({
      _ddg: (_) => Completer<http.Response>().future,
      _brave: (_) => _html(fixture('brave_results.html')),
    });
    final ddgs = Ddgs(
      client: fake.client,
      requestTimeout: const Duration(milliseconds: 50),
    );

    final response = await ddgs.search(query);
    expect(response.engine, SearchEngineId.brave);
    expect(response.failures.single.kind, SearchEngineFailureKind.timeout);
    expect(ddgs.cooldownUntil(SearchEngineId.duckduckgo), isNull);
  });

  test('engines that answer with no results are not "unavailable"', () async {
    final fake = FakeEngines({
      for (final host in [
        _ddg,
        _brave,
        _bing,
        'www.mojeek.com',
        'en.wikipedia.org',
      ])
        host: (_) => _html('<html><body></body></html>'),
    });
    final response = await Ddgs(client: fake.client).search(query);
    expect(response.results, isEmpty);
    expect(response.engine, isNull);
  });
}
