import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';

import 'search_query.dart';
import 'search_result.dart';

/// The HTTP request an engine wants sent for a query.
@immutable
final class SearchEngineRequest {
  SearchEngineRequest.get(this.url, {Map<String, String> headers = const {}})
    : method = 'GET',
      headers = Map.unmodifiable(headers),
      form = null;

  SearchEngineRequest.post(
    this.url, {
    required Map<String, String> form,
    Map<String, String> headers = const {},
  }) : method = 'POST',
       headers = Map.unmodifiable(headers),
       form = Map.unmodifiable(form);

  final String method;
  final Uri url;

  /// Merged over the transport's defaults (user agent, `Accept`,
  /// `Accept-Language`), so an engine can override any of them.
  final Map<String, String> headers;

  /// `application/x-www-form-urlencoded` body for POST requests.
  final Map<String, String>? form;
}

/// One scraped search backend.
///
/// Engines are pure: they build a request and parse a response body. The
/// transport, timeouts, cancellation and fallback live in `Ddgs`, which is
/// what makes each engine testable against a saved fixture.
abstract base class SearchEngine {
  const SearchEngine();

  SearchEngineId get id;

  SearchEngineRequest buildRequest(SearchQuery query);

  /// Whether a response is a captcha, bot challenge or rate limit rather
  /// than a results page. Checked before [parse], for every status code.
  bool isBlocked(int statusCode, String body) =>
      statusCode == 429 || statusCode == 403;

  /// Extracts organic results from a successful response body.
  List<WebSearchResult> parse(String body, SearchQuery query);
}

/// Parses an HTML document. Helpers below are shared by the engines and are
/// not exported from the package.
Document parseHtml(String body) => html_parser.parse(body);

/// Collapses runs of whitespace (including newlines inside markup) to single
/// spaces.
String cleanText(String? text) {
  if (text == null) return '';
  return text.replaceAll(_whitespace, ' ').trim();
}

final RegExp _whitespace = RegExp(r'\s+');

/// Text content of an HTML fragment, e.g. a snippet with `<b>` highlights.
String fragmentText(String? html) {
  if (html == null || html.isEmpty) return '';
  return cleanText(html_parser.parseFragment(html).text);
}

/// Parses [raw] into an absolute `http`/`https` URL, or `null` if it isn't
/// one. Protocol-relative links (`//host/path`) are treated as `https`.
Uri? parseResultUrl(String? raw) {
  var candidate = raw?.trim();
  if (candidate == null || candidate.isEmpty) return null;
  if (candidate.startsWith('//')) candidate = 'https:$candidate';
  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}

/// The `<title>` of a page, lower-cased, for block detection.
String lowerCaseTitle(String body) {
  final match = _title.firstMatch(body);
  return match == null ? '' : match.group(1)!.toLowerCase();
}

final RegExp _title = RegExp(
  r'<title[^>]*>([^<]*)</title>',
  caseSensitive: false,
);
