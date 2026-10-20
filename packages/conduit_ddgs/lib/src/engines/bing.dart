import 'dart:convert';

import '../engine.dart';
import '../search_query.dart';
import '../search_result.dart';

/// Bing's HTML results page.
///
/// Result links go through `bing.com/ck/a?...&u=a1<base64url target>`; the
/// target is decoded rather than followed.
final class BingEngine extends SearchEngine {
  const BingEngine();

  @override
  SearchEngineId get id => SearchEngineId.bing;

  @override
  SearchEngineRequest buildRequest(SearchQuery query) {
    final region = query.region;
    final country = region.isoCountry;
    final adult = switch (query.safeSearch) {
      SafeSearch.strict => ('strict', 'STRICT'),
      SafeSearch.moderate => ('moderate', 'DEMOTE'),
      SafeSearch.off => ('off', 'OFF'),
    };
    return SearchEngineRequest.get(
      Uri.https('www.bing.com', '/search', {
        'q': query.text,
        'adlt': adult.$1,
        if (!region.isWorldwide) 'setlang': region.language,
        if (country != null) ...{
          'mkt': '${region.language}-${country.toUpperCase()}',
          'cc': country,
        },
        if (query.timeLimit case final limit?) 'filters': _timeFilter(limit),
      }),
      headers: {'Cookie': 'SRCHHPGUSR=ADLT=${adult.$2}'},
    );
  }

  @override
  bool isBlocked(int statusCode, String body) {
    if (super.isBlocked(statusCode, body)) return true;
    // Normal result pages mention "challenge" in inline scripts, so only a
    // page without a results list counts.
    return !body.contains('id="b_results"') &&
        body.toLowerCase().contains('captcha');
  }

  @override
  List<WebSearchResult> parse(String body, SearchQuery query) {
    final results = <WebSearchResult>[];
    for (final item in parseHtml(body).querySelectorAll('li.b_algo')) {
      final link = item.querySelector('h2 a');
      final url = unwrapBingUrl(link?.attributes['href']);
      final title = cleanText(link?.text);
      if (url == null || title.isEmpty) continue;
      final caption =
          item.querySelector('.b_caption p') ??
          item.querySelector('.b_caption');
      caption?.querySelectorAll('.b_algoReadMore').forEach((e) => e.remove());
      results.add(
        WebSearchResult(
          title: title,
          url: url,
          snippet: cleanText(caption?.text),
          engine: id,
        ),
      );
    }
    return results;
  }

  static String _timeFilter(SearchTimeLimit limit) {
    switch (limit) {
      case SearchTimeLimit.day:
        return 'ex1:"ez1"';
      case SearchTimeLimit.week:
        return 'ex1:"ez2"';
      case SearchTimeLimit.month:
        return 'ex1:"ez3"';
      case SearchTimeLimit.year:
        final today =
            DateTime.now().toUtc().millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay;
        return 'ex1:"ez5_${today - 365}_$today"';
    }
  }
}

/// Resolves a Bing result link to its target. Direct links pass through,
/// click-tracking links are decoded, and ad links return `null`.
Uri? unwrapBingUrl(String? href) {
  final uri = parseResultUrl(href);
  if (uri == null) return null;
  final host = uri.host;
  if (host != 'bing.com' && !host.endsWith('.bing.com')) return uri;
  if (uri.path != '/ck/a') return null;
  final wrapped = uri.queryParameters['u'];
  if (wrapped == null || wrapped.length <= 2) return null;
  // `a1` is Bing's version prefix; the rest is unpadded base64url.
  final encoded = wrapped.substring(2);
  final padded = encoded.padRight(
    encoded.length + (4 - encoded.length % 4) % 4,
    '=',
  );
  try {
    return parseResultUrl(utf8.decode(base64Url.decode(padded)));
  } on FormatException {
    return null;
  }
}
