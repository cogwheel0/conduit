import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'engine.dart';
import 'engines/bing.dart';
import 'engines/brave.dart';
import 'engines/duckduckgo.dart';
import 'engines/mojeek.dart';
import 'engines/wikipedia.dart';
import 'exceptions.dart';
import 'search_query.dart';
import 'search_result.dart';

/// A desktop Chrome user agent. The scrapers target desktop markup; a mobile
/// agent gets different (and differently broken) HTML from every engine.
const String kDdgsDefaultUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';

/// The outcome of [Ddgs.search].
@immutable
final class WebSearchResponse {
  WebSearchResponse({
    required Iterable<WebSearchResult> results,
    required this.engine,
    Iterable<SearchEngineException> failures = const [],
  }) : results = List.unmodifiable(results),
       failures = List.unmodifiable(failures);

  final List<WebSearchResult> results;

  /// The engine that answered, or `null` when every engine that responded
  /// had no results.
  final SearchEngineId? engine;

  /// Engines that were tried first and failed.
  final List<SearchEngineException> failures;
}

/// Metasearch over the scraped engines.
///
/// [search] tries engines one at a time and stops at the first that returns
/// results, so a query touches as few services as possible. An engine that
/// answers with a captcha or rate limit is skipped for [blockedCooldown]
/// instead of being retried on every query.
///
/// The caller owns [client] and closes it.
final class Ddgs {
  Ddgs({
    required http.Client client,
    this.requestTimeout = const Duration(seconds: 8),
    this.blockedCooldown = const Duration(minutes: 10),
    this.maxResponseBytes = 4 * 1024 * 1024,
    this.userAgent = kDdgsDefaultUserAgent,
    DateTime Function()? clock,
    Map<SearchEngineId, SearchEngine>? engines,
  }) : _client = client,
       _clock = clock ?? DateTime.now,
       _engines = engines ?? defaultEngines;

  /// The order `Auto` tries engines in. Wikipedia is last because it only
  /// covers encyclopedic topics.
  static const List<SearchEngineId> autoOrder = [
    SearchEngineId.duckduckgo,
    SearchEngineId.brave,
    SearchEngineId.bing,
    SearchEngineId.mojeek,
    SearchEngineId.wikipedia,
  ];

  static const Map<SearchEngineId, SearchEngine> defaultEngines = {
    SearchEngineId.duckduckgo: DuckDuckGoEngine(),
    SearchEngineId.brave: BraveEngine(),
    SearchEngineId.bing: BingEngine(),
    SearchEngineId.mojeek: MojeekEngine(),
    SearchEngineId.wikipedia: WikipediaEngine(),
  };

  final http.Client _client;
  final DateTime Function() _clock;
  final Map<SearchEngineId, SearchEngine> _engines;
  final Map<SearchEngineId, DateTime> _blockedUntil = {};

  final Duration requestTimeout;
  final Duration blockedCooldown;
  final int maxResponseBytes;
  final String userAgent;

  /// When [engine] may be tried again after a block, or `null` if it isn't
  /// cooling down.
  DateTime? cooldownUntil(SearchEngineId engine) {
    final until = _blockedUntil[engine];
    if (until == null) return null;
    if (!_clock().isBefore(until)) {
      _blockedUntil.remove(engine);
      return null;
    }
    return until;
  }

  /// Searches [query].
  ///
  /// With [engine] set, only that engine is used: a user who picks an engine
  /// has chosen who sees their queries, so there is no silent fallback.
  /// Otherwise engines are tried in [autoOrder].
  ///
  /// Throws [WebSearchUnavailableException] when no engine could answer and
  /// [WebSearchCancelledException] when [cancel] completes first.
  Future<WebSearchResponse> search(
    SearchQuery query, {
    SearchEngineId? engine,
    int maxResults = 10,
    Future<void>? cancel,
  }) async {
    if (maxResults < 1) {
      throw ArgumentError.value(maxResults, 'maxResults', 'Must be positive');
    }
    var cancelled = false;
    unawaited(cancel?.then((_) => cancelled = true));
    // Let an already-completed cancel land before the first request goes out.
    await Future<void>.value();

    final failures = <SearchEngineException>[];
    var anyAnswered = false;
    for (final id in engine == null ? autoOrder : [engine]) {
      if (cancelled) throw const WebSearchCancelledException();
      final impl = _engines[id];
      if (impl == null) continue;
      if (cooldownUntil(id) != null) {
        failures.add(
          SearchEngineException(id, SearchEngineFailureKind.blocked),
        );
        continue;
      }
      try {
        final results = await _run(impl, query, cancel);
        anyAnswered = true;
        if (results.isEmpty) continue;
        return WebSearchResponse(
          results: _dedupe(results).take(maxResults),
          engine: id,
          failures: failures,
        );
      } on SearchEngineException catch (failure) {
        if (cancelled) throw const WebSearchCancelledException();
        if (failure.kind == SearchEngineFailureKind.blocked) {
          _blockedUntil[id] = _clock().add(blockedCooldown);
        }
        failures.add(failure);
      }
    }
    if (cancelled) throw const WebSearchCancelledException();
    if (anyAnswered) {
      return WebSearchResponse(
        results: const [],
        engine: null,
        failures: failures,
      );
    }
    throw WebSearchUnavailableException(failures);
  }

  Future<List<WebSearchResult>> _run(
    SearchEngine engine,
    SearchQuery query,
    Future<void>? cancel,
  ) async {
    final spec = engine.buildRequest(query);
    final abort = Completer<void>();
    void fire() {
      if (!abort.isCompleted) abort.complete();
    }

    var timedOut = false;
    final timer = Timer(requestTimeout, () {
      timedOut = true;
      fire();
    });
    unawaited(cancel?.then((_) => fire()));

    final request = http.AbortableRequest(
      spec.method,
      spec.url,
      abortTrigger: abort.future,
    );
    request.headers.addAll({
      'User-Agent': userAgent,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': query.region.acceptLanguage,
      ...spec.headers,
    });
    if (spec.form case final form?) request.bodyFields = form;

    // Clients that honour `abortTrigger` stop the transfer; racing the abort
    // signal as well keeps the timeout and cancellation working with clients
    // that don't.
    final exchange = () async {
      final response = await _client.send(request);
      return (response.statusCode, await _readBody(response));
    }();
    final aborted = abort.future.then<(int, String)>(
      (_) => throw http.RequestAbortedException(spec.url),
    );
    exchange.ignore();
    aborted.ignore();

    try {
      final (statusCode, body) = await Future.any([exchange, aborted]);
      if (engine.isBlocked(statusCode, body)) {
        throw SearchEngineException(
          engine.id,
          SearchEngineFailureKind.blocked,
          statusCode: statusCode,
        );
      }
      if (statusCode != 200) {
        throw SearchEngineException(
          engine.id,
          SearchEngineFailureKind.http,
          statusCode: statusCode,
        );
      }
      return engine.parse(body, query);
    } on SearchEngineException {
      rethrow;
    } on http.RequestAbortedException {
      throw SearchEngineException(
        engine.id,
        timedOut
            ? SearchEngineFailureKind.timeout
            : SearchEngineFailureKind.network,
      );
    } on http.ClientException {
      throw SearchEngineException(engine.id, SearchEngineFailureKind.network);
    } on Exception {
      // TLS handshake failures and the like are not always wrapped in a
      // ClientException.
      throw SearchEngineException(engine.id, SearchEngineFailureKind.network);
    } finally {
      timer.cancel();
      fire();
    }
  }

  /// Reads at most [maxResponseBytes]; results live near the top of a page,
  /// so a truncated body still parses.
  Future<String> _readBody(http.StreamedResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      final room = maxResponseBytes - bytes.length;
      if (chunk.length >= room) {
        bytes.addAll(chunk.take(room));
        break;
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Drops repeated URLs, keeping the first position but the most
  /// informative copy: DuckDuckGo, for one, leads with an "Official site"
  /// card for a URL that the next organic result describes properly.
  static List<WebSearchResult> _dedupe(List<WebSearchResult> results) {
    final indexByKey = <String, int>{};
    final unique = <WebSearchResult>[];
    for (final result in results) {
      final url = result.url;
      final path = url.path.endsWith('/')
          ? url.path.substring(0, url.path.length - 1)
          : url.path;
      // http and https copies of a page are the same result; a different
      // port is a different site.
      final key = '${url.host.toLowerCase()}:${url.port}$path?${url.query}';
      final index = indexByKey[key];
      if (index == null) {
        indexByKey[key] = unique.length;
        unique.add(result);
      } else if (result.snippet.length > unique[index].snippet.length) {
        unique[index] = result;
      }
    }
    return unique;
  }
}
