import 'dart:convert';

import 'package:conduit_ddgs/conduit_ddgs.dart';

import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/web_search/models/web_search_preferences.dart';
import 'package:conduit_core/features/web_search/services/public_web_address.dart';
import 'package:conduit_core/features/web_search/services/web_page_extractor.dart';
import 'package:conduit_core/features/web_search/services/web_page_fetcher.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Tool names shared with Ollama Cloud's hosted tools, so the chat bridge
/// turns both into the same source chips and tool tiles.
const String kWebSearchToolName = 'web_search';
const String kWebFetchToolName = 'web_fetch';

/// Pseudo MCP server id for the compiled-in tools.
const String kOnDeviceWebToolServerId = 'conduit.web';

const int _maxQueryCharacters = 400;
const int _maxUrlCharacters = 4096;
const int _maxTitleCharacters = 300;

/// How much of each result the model sees. Tool results land in the model's
/// context, so small on-device models need a much tighter budget.
final class WebToolBudget {
  const WebToolBudget({
    required this.maxResults,
    required this.snippetCharacters,
    required this.pageCharacters,
  });

  static const WebToolBudget standard = WebToolBudget(
    maxResults: 5,
    snippetCharacters: 300,
    pageCharacters: 12000,
  );

  /// For Apple's on-device model and other ~4K-token context windows.
  static const WebToolBudget compact = WebToolBudget(
    maxResults: 3,
    snippetCharacters: 160,
    pageCharacters: 1500,
  );

  final int maxResults;
  final int snippetCharacters;
  final int pageCharacters;
}

/// `web_search` and `web_fetch`, run on the device for one model turn.
///
/// Like Ollama Cloud's tools, a fetch is limited to URLs the session has
/// already seen, here search results plus links the user wrote in the
/// turn's message. A fetched page can carry prompt-injected instructions;
/// the allow-list stops them from making the model send chat content to a
/// new address.
final class OnDeviceWebToolSession {
  OnDeviceWebToolSession({
    required Ddgs search,
    required WebPageFetcher fetcher,
    required this.engine,
    required this.region,
    required this.safeSearch,
    this.budget = WebToolBudget.standard,
    Iterable<String> userProvidedUrls = const [],
    Future<void>? cancel,
    DateTime Function()? clock,
  }) : _search = search,
       _fetcher = fetcher,
       _cancel = cancel,
       _clock = clock ?? DateTime.now {
    for (final url in userProvidedUrls) {
      try {
        final normalized = normalizePublicWebUrl(url);
        _fetchableUrls.add(normalized);
        _userUrls.add(normalized);
      } on FormatException {
        // Local or malformed links in the user's message stay unfetchable.
      }
    }
  }

  final Ddgs _search;
  final WebPageFetcher _fetcher;
  final Future<void>? _cancel;
  final DateTime Function() _clock;
  final Set<String> _fetchableUrls = {};

  /// Links the user wrote. Unlike search results, these may redirect to
  /// another site: the user chose them.
  final Set<String> _userUrls = {};

  final WebSearchEngineChoice engine;
  final SearchRegion region;
  final SafeSearch safeSearch;
  final WebToolBudget budget;

  static bool handles(String name) =>
      name == kWebSearchToolName || name == kWebFetchToolName;

  List<DirectToolDefinition> get definitions {
    final today = _clock().toIso8601String().substring(0, 10);
    return [
      _definition(
        name: kWebSearchToolName,
        displayName: 'Web search',
        description:
            'Search the web for current information. Returns titles, URLs '
            'and short snippets. Today is $today. Call $kWebFetchToolName '
            'to read a result in full.',
        inputSchema: {
          'type': 'object',
          'required': ['query'],
          'additionalProperties': false,
          'properties': {
            'query': {'type': 'string', 'description': 'The search query.'},
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'maximum': budget.maxResults,
              'description': 'How many results to return.',
            },
          },
        },
      ),
      _definition(
        name: kWebFetchToolName,
        displayName: 'Read web page',
        description:
            'Read one web page as text. The URL must come from '
            '$kWebSearchToolName results or from the user\'s message.',
        inputSchema: {
          'type': 'object',
          'required': ['url'],
          'additionalProperties': false,
          'properties': {
            'url': {
              'type': 'string',
              'description': 'An absolute HTTP or HTTPS URL.',
            },
          },
        },
      ),
    ];
  }

  /// Runs one tool call. Failures come back as error results the model can
  /// read; only cancellation throws.
  Future<DirectToolResult> execute(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final value = switch (name) {
        kWebSearchToolName => await _webSearch(arguments),
        kWebFetchToolName => await _webFetch(arguments),
        _ => throw FormatException('Tool "$name" is not available.'),
      };
      return DirectToolResult(text: jsonEncode(value), value: value);
    } on WebSearchCancelledException {
      rethrow;
    } on FormatException catch (error) {
      return _error(error.message);
    } on WebFetchException catch (error) {
      return _error(error.message);
    } on WebSearchUnavailableException catch (error) {
      DebugLogger.warning(
        'search-unavailable',
        scope: 'web-search',
        data: {'blocked': error.wasBlocked},
      );
      return _error(
        error.wasBlocked
            ? 'Web search is temporarily unavailable: the search engine is '
                  'asking for a captcha. Answer without searching, and say so.'
            : 'Web search could not reach a search engine. Answer without '
                  'searching, and say so.',
      );
    }
  }

  Future<Map<String, dynamic>> _webSearch(
    Map<String, dynamic> arguments,
  ) async {
    _rejectUnexpectedArguments(arguments, const {'query', 'max_results'});
    final query = _requiredString(arguments, 'query', _maxQueryCharacters);
    final maxResults = switch (arguments['max_results']) {
      null => budget.maxResults,
      final int value when value >= 1 => value.clamp(1, budget.maxResults),
      _ => throw FormatException(
        'max_results must be an integer from 1 to ${budget.maxResults}.',
      ),
    };

    final response = await _search.search(
      SearchQuery(query, region: region, safeSearch: safeSearch),
      engine: engine.engine,
      maxResults: maxResults,
      cancel: _cancel,
    );
    // "No results" after other engines refused is not an answer: the model
    // would tell the user nothing exists.
    if (response.results.isEmpty && response.failures.isNotEmpty) {
      throw WebSearchUnavailableException(response.failures);
    }
    final results = <Map<String, dynamic>>[];
    for (final result in response.results) {
      final String url;
      try {
        url = normalizePublicWebUrl(result.url.toString());
      } on FormatException {
        continue;
      }
      _fetchableUrls.add(url);
      results.add({
        'title': _truncate(result.title, _maxTitleCharacters),
        'url': url,
        'content': _truncate(result.snippet, budget.snippetCharacters),
      });
    }
    return {'results': results};
  }

  Future<Map<String, dynamic>> _webFetch(Map<String, dynamic> arguments) async {
    _rejectUnexpectedArguments(arguments, const {'url'});
    final url = normalizePublicWebUrl(
      _requiredString(arguments, 'url', _maxUrlCharacters),
    );
    if (!_fetchableUrls.contains(url)) {
      throw const FormatException(
        'web_fetch only accepts an exact URL from web_search results or from '
        'the user\'s message.',
      );
    }
    final page = await _fetcher.fetch(
      Uri.parse(url),
      acceptLanguage: region.acceptLanguage,
      cancel: _cancel,
      // A search result may only redirect within its own site, so a result
      // can't hand the fetch to an unrelated host.
      allowRedirect: _userUrls.contains(url) ? null : isSameSiteRedirect,
    );
    final extracted = extractReadableText(page);
    final truncated =
        page.truncated || extracted.text.length > budget.pageCharacters;
    return {
      'title': _truncate(extracted.title, _maxTitleCharacters),
      'url': page.url.toString(),
      'content': _truncate(extracted.text, budget.pageCharacters),
      if (truncated) 'truncated': true,
    };
  }

  DirectToolDefinition _definition({
    required String name,
    required String displayName,
    required String description,
    required Map<String, dynamic> inputSchema,
  }) => DirectToolDefinition(
    name: name,
    serverId: kOnDeviceWebToolServerId,
    serverName: 'Web search',
    remoteName: name,
    displayName: displayName,
    description: description,
    approvalFingerprint: '$kOnDeviceWebToolServerId/$name/v1',
    inputSchema: inputSchema,
  );

  static DirectToolResult _error(String message) {
    final value = {'error': message};
    return DirectToolResult(
      text: jsonEncode(value),
      value: value,
      isError: true,
    );
  }
}

/// Whether a redirect stays on the same site: the same host, its `www`
/// twin, or a subdomain in either direction (`http→https` and path changes
/// are fine).
bool isSameSiteRedirect(Uri from, Uri to) {
  String bare(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  final a = bare(from);
  final b = bare(to);
  return a == b || a.endsWith('.$b') || b.endsWith('.$a');
}

/// `http(s)` links in [text], e.g. the user's message, for the fetch
/// allow-list. Trailing punctuation is dropped, except a closing bracket
/// that the URL itself opened (`…/wiki/Dart_(programming_language)`).
List<String> extractWebUrls(String text) {
  return [
    for (final match in _urlPattern.allMatches(text))
      _trimTrailingPunctuation(match.group(0)!),
  ];
}

final RegExp _urlPattern = RegExp(
  r'''https?://[^\s<>"'`]+''',
  caseSensitive: false,
);

String _trimTrailingPunctuation(String url) {
  var end = url.length;
  while (end > 0) {
    final char = url[end - 1];
    if ('.,;:!?\'"'.contains(char)) {
      end--;
      continue;
    }
    final open = switch (char) {
      ')' => '(',
      ']' => '[',
      '}' => '{',
      '>' => '<',
      _ => null,
    };
    if (open == null) break;
    final candidate = url.substring(0, end);
    final opens = open.allMatches(candidate).length;
    final closes = char.allMatches(candidate).length;
    if (closes <= opens) break;
    end--;
  }
  return url.substring(0, end);
}

void _rejectUnexpectedArguments(
  Map<String, dynamic> arguments,
  Set<String> allowed,
) {
  final unexpected = arguments.keys.where((key) => !allowed.contains(key));
  if (unexpected.isNotEmpty) {
    throw FormatException('Unsupported arguments: ${unexpected.join(', ')}.');
  }
}

String _requiredString(
  Map<String, dynamic> arguments,
  String key,
  int maxCharacters,
) {
  final value = arguments[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" is required.');
  }
  final trimmed = value.trim();
  if (trimmed.length > maxCharacters) {
    throw FormatException('"$key" is too long.');
  }
  return trimmed;
}

String _truncate(String text, int maxCharacters) {
  if (text.length <= maxCharacters) return text;
  return '${text.substring(0, maxCharacters - 1).trimRight()}…';
}
