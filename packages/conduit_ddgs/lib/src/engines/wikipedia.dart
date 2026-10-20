import 'dart:convert';

import '../engine.dart';
import '../search_query.dart';
import '../search_result.dart';

/// Wikipedia's search API, in the region's language.
///
/// This is the one real API in the set, so it is the last-resort fallback:
/// it rarely blocks, but only covers encyclopedic topics.
final class WikipediaEngine extends SearchEngine {
  const WikipediaEngine();

  /// Wikipedia's API etiquette asks clients to identify themselves.
  static const String userAgent =
      'Conduit/1.0 (https://github.com/cogwheel0/conduit) conduit_ddgs';

  @override
  SearchEngineId get id => SearchEngineId.wikipedia;

  @override
  SearchEngineRequest buildRequest(SearchQuery query) {
    return SearchEngineRequest.get(
      Uri.https(_host(query), '/w/api.php', {
        'action': 'query',
        'list': 'search',
        'srsearch': query.text,
        'srprop': 'snippet',
        'srlimit': '10',
        'format': 'json',
        'utf8': '1',
      }),
      headers: const {'User-Agent': userAgent, 'Accept': 'application/json'},
    );
  }

  @override
  List<WebSearchResult> parse(String body, SearchQuery query) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map) return const [];
    final search = switch (decoded['query']) {
      final Map<dynamic, dynamic> q => q['search'],
      _ => null,
    };
    if (search is! List) return const [];

    final host = _host(query);
    final results = <WebSearchResult>[];
    for (final entry in search) {
      if (entry is! Map) continue;
      final title = entry['title'];
      if (title is! String || title.trim().isEmpty) continue;
      final snippet = entry['snippet'];
      results.add(
        WebSearchResult(
          title: title.trim(),
          url: Uri.https(host, '/wiki/${title.trim().replaceAll(' ', '_')}'),
          snippet: fragmentText(snippet is String ? snippet : null),
          engine: id,
        ),
      );
    }
    return results;
  }

  static String _host(SearchQuery query) =>
      '${query.region.language}.wikipedia.org';
}
