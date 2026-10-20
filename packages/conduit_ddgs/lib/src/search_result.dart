import 'package:meta/meta.dart';

/// The engines this package can scrape.
enum SearchEngineId {
  duckduckgo('DuckDuckGo'),
  brave('Brave'),
  bing('Bing'),
  mojeek('Mojeek'),
  wikipedia('Wikipedia');

  const SearchEngineId(this.displayName);

  /// The engine's brand name. Not localized.
  final String displayName;

  static SearchEngineId? tryParse(String? name) {
    for (final id in values) {
      if (id.name == name) return id;
    }
    return null;
  }
}

/// One organic web result.
@immutable
final class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    required this.engine,
  });

  final String title;

  /// Always an absolute `http` or `https` URL, unwrapped from any engine
  /// redirector.
  final Uri url;
  final String snippet;
  final SearchEngineId engine;

  @override
  String toString() => 'WebSearchResult($engine, $url)';
}
