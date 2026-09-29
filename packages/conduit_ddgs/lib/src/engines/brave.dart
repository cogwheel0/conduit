import '../engine.dart';
import '../search_query.dart';
import '../search_result.dart';

/// Brave Search's server-rendered results page.
///
/// Region and safe search are cookies rather than query parameters.
final class BraveEngine extends SearchEngine {
  const BraveEngine();

  @override
  SearchEngineId get id => SearchEngineId.brave;

  @override
  SearchEngineRequest buildRequest(SearchQuery query) {
    final safeSearch = switch (query.safeSearch) {
      SafeSearch.strict => 'strict',
      SafeSearch.moderate => 'moderate',
      SafeSearch.off => 'off',
    };
    final country = query.region.isoCountry ?? 'all';
    return SearchEngineRequest.get(
      Uri.https('search.brave.com', '/search', {
        'q': query.text,
        'source': 'web',
        if (query.timeLimit case final limit?) 'tf': _timeLimit(limit),
      }),
      headers: {
        'Cookie': 'country=$country; safesearch=$safeSearch; useLocation=0',
      },
    );
  }

  @override
  bool isBlocked(int statusCode, String body) =>
      super.isBlocked(statusCode, body) ||
      lowerCaseTitle(body).contains('captcha');

  @override
  List<WebSearchResult> parse(String body, SearchQuery query) {
    final results = <WebSearchResult>[];
    final items = parseHtml(body)
        .querySelectorAll('div.snippet[data-type="web"]');
    for (final item in items) {
      final link =
          item.querySelector('.result-content > a[href]') ??
          item.querySelector('a[href]');
      final url = parseResultUrl(link?.attributes['href']);
      if (url == null ||
          url.host == 'brave.com' ||
          url.host.endsWith('.brave.com')) {
        continue;
      }
      final titleElement = item.querySelector('.search-snippet-title');
      final title = cleanText(
        titleElement?.attributes['title'] ?? titleElement?.text,
      );
      if (title.isEmpty) continue;
      final snippet =
          item.querySelector('.generic-snippet .content') ??
          item.querySelector('.snippet-description');
      results.add(
        WebSearchResult(
          title: title,
          url: url,
          snippet: cleanText(snippet?.text),
          engine: id,
        ),
      );
    }
    return results;
  }

  static String _timeLimit(SearchTimeLimit limit) => switch (limit) {
    SearchTimeLimit.day => 'pd',
    SearchTimeLimit.week => 'pw',
    SearchTimeLimit.month => 'pm',
    SearchTimeLimit.year => 'py',
  };
}
