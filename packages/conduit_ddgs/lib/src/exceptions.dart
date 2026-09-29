import 'search_result.dart';

/// Why a single engine produced no usable response.
enum SearchEngineFailureKind {
  /// A captcha, bot challenge or rate limit. The engine is cooled down.
  blocked,

  /// A non-success HTTP status that isn't a block.
  http,

  /// DNS, TLS or socket failure.
  network,

  /// No response within the request timeout.
  timeout,
}

/// One engine failed. `Ddgs.search` records these and moves on; they only
/// surface through [WebSearchUnavailableException] or
/// `WebSearchResponse.failures`.
final class SearchEngineException implements Exception {
  const SearchEngineException(this.engine, this.kind, {this.statusCode});

  final SearchEngineId engine;
  final SearchEngineFailureKind kind;
  final int? statusCode;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'SearchEngineException: ${engine.displayName} ${kind.name}$status';
  }
}

/// Every engine that was tried failed, or every engine was cooling down.
final class WebSearchUnavailableException implements Exception {
  WebSearchUnavailableException(Iterable<SearchEngineException> failures)
    : failures = List.unmodifiable(failures);

  final List<SearchEngineException> failures;

  /// True when at least one engine refused with a captcha or rate limit.
  bool get wasBlocked =>
      failures.any((f) => f.kind == SearchEngineFailureKind.blocked);

  @override
  String toString() => 'WebSearchUnavailableException: ${failures.join(', ')}';
}

/// The caller's cancel signal fired before the search finished.
final class WebSearchCancelledException implements Exception {
  const WebSearchCancelledException();

  @override
  String toString() => 'WebSearchCancelledException';
}
