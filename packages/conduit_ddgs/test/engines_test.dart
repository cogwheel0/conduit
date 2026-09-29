import 'dart:io';

import 'package:conduit_ddgs/conduit_ddgs.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

final _query = SearchQuery(
  'dart programming language',
  region: SearchRegion('us-en'),
);

void main() {
  group('parsing', () {
    // Each engine must turn its own markup into absolute target URLs; the
    // upstream package returned display text and redirector links instead.
    final cases =
        <
          ({
            SearchEngine engine,
            String fixture,
            int minResults,
            String firstUrl,
            String firstTitle,
            String firstSnippetPrefix,
            String engineHost,
          })
        >[
          (
            engine: const BingEngine(),
            fixture: 'bing_results.html',
            minResults: 10,
            firstUrl: 'https://dart.dev/',
            firstTitle: 'Dart programming language',
            firstSnippetPrefix: 'Dart 3.13 is here!',
            engineHost: 'bing.com',
          ),
          (
            engine: const BraveEngine(),
            fixture: 'brave_results.html',
            minResults: 10,
            firstUrl: 'https://dart.dev/',
            firstTitle: 'Dart programming language',
            firstSnippetPrefix: 'Dart is an approachable, portable',
            engineHost: 'brave.com',
          ),
          (
            engine: const DuckDuckGoEngine(),
            fixture: 'duckduckgo_results.html',
            minResults: 10,
            // DuckDuckGo leads with an "Official site" card; `Ddgs` merges it
            // with the organic result for the same URL.
            firstUrl: 'https://dart.dev',
            firstTitle: 'Official site',
            firstSnippetPrefix: 'Dart (programming language)',
            engineHost: 'duckduckgo.com',
          ),
          (
            engine: const MojeekEngine(),
            fixture: 'mojeek_results.html',
            minResults: 2,
            firstUrl: 'https://dart.dev/',
            firstTitle: 'Dart programming language | Dart',
            firstSnippetPrefix: 'Dart is an approachable, portable',
            engineHost: 'mojeek.com',
          ),
          (
            engine: const WikipediaEngine(),
            fixture: 'wikipedia_results.json',
            minResults: 5,
            firstUrl:
                'https://en.wikipedia.org/wiki/Dart_(programming_language)',
            firstTitle: 'Dart (programming language)',
            firstSnippetPrefix: 'Dart is a programming language designed',
            engineHost: 'wikipedia.org/w/',
          ),
        ];

    for (final c in cases) {
      test('${c.engine.id.displayName} extracts target links', () {
        final body = fixture(c.fixture);
        expect(c.engine.isBlocked(200, body), isFalse);

        final results = c.engine.parse(body, _query);
        expect(results.length, greaterThanOrEqualTo(c.minResults));
        final first = results.first;
        expect(first.url.toString(), c.firstUrl);
        expect(first.title, c.firstTitle);
        expect(first.snippet, startsWith(c.firstSnippetPrefix));
        for (final result in results) {
          expect(result.engine, c.engine.id);
          expect(result.url.scheme, anyOf('http', 'https'));
          expect(result.url.toString(), isNot(contains(c.engineHost)));
          expect(result.title, isNot(contains('\n')));
        }
      });
    }

    test('DuckDuckGo skips ads and unwraps redirected links', () {
      final results = const DuckDuckGoEngine().parse(
        fixture('duckduckgo_wrapped_links.html'),
        _query,
      );
      expect(results.map((r) => r.url.toString()), [
        'https://dart.dev/',
        'https://en.wikipedia.org/wiki/Dart_(programming_language)',
        'https://github.com/dart-lang/sdk?tab=readme-ov-file',
      ]);
    });

    test('Bing drops its "Read more" link text from snippets', () {
      final results = const BingEngine().parse(
        fixture('bing_results.html'),
        _query,
      );
      expect(
        results.map((r) => r.snippet),
        everyElement(isNot(endsWith('Read more'))),
      );
    });

    test('Wikipedia links use the region language', () {
      final results = const WikipediaEngine().parse(
        fixture('wikipedia_results.json'),
        SearchQuery('dart', region: SearchRegion('de-de')),
      );
      expect(results.first.url.host, 'de.wikipedia.org');
    });
  });

  group('block detection', () {
    test('DuckDuckGo anomaly page counts as blocked', () {
      final body = fixture('duckduckgo_captcha.html');
      expect(const DuckDuckGoEngine().isBlocked(202, body), isTrue);
      // The challenge is recognized by its markup, not only the status.
      expect(const DuckDuckGoEngine().isBlocked(200, body), isTrue);
    });

    test('Mojeek captcha page counts as blocked', () {
      expect(
        const MojeekEngine().isBlocked(200, fixture('mojeek_captcha.html')),
        isTrue,
      );
    });

    test('rate-limit statuses count as blocked for every engine', () {
      for (final engine in Ddgs.defaultEngines.values) {
        expect(engine.isBlocked(429, ''), isTrue, reason: '${engine.id}');
      }
    });
  });

  group('request parameters', () {
    // What each engine is sent is the contract with the external service.
    test('region and safe search map onto each engine', () {
      final query = SearchQuery(
        'q',
        region: SearchRegion('uk-en'),
        safeSearch: SafeSearch.strict,
        timeLimit: SearchTimeLimit.week,
      );

      final ddg = const DuckDuckGoEngine().buildRequest(query);
      expect(ddg.method, 'POST');
      expect(ddg.form, containsPair('kl', 'uk-en'));
      expect(ddg.form, containsPair('kp', '1'));
      expect(ddg.form, containsPair('df', 'w'));

      final bing = const BingEngine().buildRequest(query).url;
      expect(bing.queryParameters, containsPair('mkt', 'en-GB'));
      expect(bing.queryParameters, containsPair('adlt', 'strict'));

      final brave = const BraveEngine().buildRequest(query);
      expect(brave.headers['Cookie'], contains('country=gb'));
      expect(brave.headers['Cookie'], contains('safesearch=strict'));
      expect(brave.url.queryParameters, containsPair('tf', 'pw'));

      final mojeek = const MojeekEngine().buildRequest(query).url;
      expect(mojeek.queryParameters, containsPair('safe', '1'));
      expect(mojeek.queryParameters, containsPair('arc', 'gb'));
    });

    test('worldwide sends no market to Bing or Brave', () {
      final query = SearchQuery('q');
      final bing = const BingEngine().buildRequest(query).url;
      expect(bing.queryParameters.keys, isNot(contains('mkt')));
      final brave = const BraveEngine().buildRequest(query);
      expect(brave.headers['Cookie'], contains('country=all'));
    });

    test('Traditional Chinese maps to the zh Wikipedia', () {
      final request = const WikipediaEngine().buildRequest(
        SearchQuery('q', region: SearchRegion('tw-tzh')),
      );
      expect(request.url.host, 'zh.wikipedia.org');
    });
  });
}
