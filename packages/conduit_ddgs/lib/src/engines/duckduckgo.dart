import '../engine.dart';
import '../search_query.dart';
import '../search_result.dart';

/// DuckDuckGo's JavaScript-free HTML endpoint.
///
/// DuckDuckGo answers bots with HTTP 202 and an image challenge
/// (`anomaly-modal`) rather than an error status, so block detection looks
/// at the body as well as the status.
final class DuckDuckGoEngine extends SearchEngine {
  const DuckDuckGoEngine();

  static final Uri _endpoint = Uri.parse('https://html.duckduckgo.com/html/');

  @override
  SearchEngineId get id => SearchEngineId.duckduckgo;

  @override
  SearchEngineRequest buildRequest(SearchQuery query) {
    return SearchEngineRequest.post(
      _endpoint,
      form: {
        'q': query.text,
        'b': '',
        'kl': query.region.code,
        'kp': switch (query.safeSearch) {
          SafeSearch.strict => '1',
          SafeSearch.moderate => '-1',
          SafeSearch.off => '-2',
        },
        if (query.timeLimit case final limit?) 'df': _timeLimit(limit),
      },
      headers: const {'Referer': 'https://html.duckduckgo.com/'},
    );
  }

  @override
  bool isBlocked(int statusCode, String body) =>
      super.isBlocked(statusCode, body) ||
      statusCode == 202 ||
      body.contains('anomaly-modal') ||
      body.contains('id="challenge-form"');

  @override
  List<WebSearchResult> parse(String body, SearchQuery query) {
    final results = <WebSearchResult>[];
    for (final item in parseHtml(body).querySelectorAll('div.result')) {
      if (item.classes.contains('result--ad')) continue;
      final link = item.querySelector('a.result__a');
      final url = _unwrap(link?.attributes['href']);
      final title = cleanText(link?.text);
      if (url == null || title.isEmpty) continue;
      results.add(
        WebSearchResult(
          title: title,
          url: url,
          snippet: cleanText(item.querySelector('.result__snippet')?.text),
          engine: id,
        ),
      );
    }
    return results;
  }

  /// Result links are either direct or wrapped as
  /// `//duckduckgo.com/l/?uddg=<encoded target>`; ads go through `y.js`.
  static Uri? _unwrap(String? href) {
    final uri = parseResultUrl(href);
    if (uri == null) return null;
    if (!_isDuckDuckGoHost(uri.host)) return uri;
    if (uri.path == '/l/') return parseResultUrl(uri.queryParameters['uddg']);
    return null;
  }

  static bool _isDuckDuckGoHost(String host) =>
      host == 'duckduckgo.com' || host.endsWith('.duckduckgo.com');

  static String _timeLimit(SearchTimeLimit limit) => switch (limit) {
    SearchTimeLimit.day => 'd',
    SearchTimeLimit.week => 'w',
    SearchTimeLimit.month => 'm',
    SearchTimeLimit.year => 'y',
  };
}
