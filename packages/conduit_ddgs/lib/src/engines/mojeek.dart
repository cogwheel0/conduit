import '../engine.dart';
import '../search_query.dart';
import '../search_result.dart';

/// Mojeek, an independent index with a plain HTML results page.
final class MojeekEngine extends SearchEngine {
  const MojeekEngine();

  @override
  SearchEngineId get id => SearchEngineId.mojeek;

  @override
  SearchEngineRequest buildRequest(SearchQuery query) {
    final region = query.region;
    final country = region.isoCountry;
    return SearchEngineRequest.get(
      Uri.https('www.mojeek.com', '/search', {
        'q': query.text,
        if (query.safeSearch == SafeSearch.strict) 'safe': '1',
        if (!region.isWorldwide) 'lb': region.language,
        'arc': ?country,
      }),
    );
  }

  @override
  bool isBlocked(int statusCode, String body) =>
      super.isBlocked(statusCode, body) ||
      lowerCaseTitle(body).contains('captcha') ||
      body.contains('class="captcha-wrap"');

  @override
  List<WebSearchResult> parse(String body, SearchQuery query) {
    final results = <WebSearchResult>[];
    final items = parseHtml(body).querySelectorAll('ul.results-standard > li');
    for (final item in items) {
      final link =
          item.querySelector('h2 a[href]') ?? item.querySelector('a.title');
      final url = parseResultUrl(link?.attributes['href']);
      final title = cleanText(link?.text);
      if (url == null || title.isEmpty) continue;
      results.add(
        WebSearchResult(
          title: title,
          url: url,
          snippet: cleanText(item.querySelector('p.s')?.text),
          engine: id,
        ),
      );
    }
    return results;
  }
}
