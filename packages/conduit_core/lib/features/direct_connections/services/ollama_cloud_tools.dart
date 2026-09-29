import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/features/direct_connections/services/direct_adapter_helpers.dart';
import 'package:conduit_core/features/web_search/services/public_web_address.dart';

const int kOllamaCloudMaxSearchResults = 10;
const int kOllamaCloudMaxQueryCharacters = 2048;
const int kOllamaCloudMaxUrlCharacters = 4096;
const int kOllamaCloudMaxToolResultCharacters = 128 * 1024;

const List<Map<String, dynamic>> kOllamaCloudWebToolDefinitions = [
  {
    'type': 'function',
    'function': {
      'name': 'web_search',
      'description': 'Search the web for current information. Use web_fetch to read a result in detail.',
      'parameters': {
        'type': 'object',
        'required': ['query'],
        'additionalProperties': false,
        'properties': {
          'query': {'type': 'string', 'description': 'The search query.'},
          'max_results': {
            'type': 'integer',
            'minimum': 1,
            'maximum': kOllamaCloudMaxSearchResults,
            'description': 'The maximum number of results to return.',
          },
        },
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'web_fetch',
      'description': 'Fetch the readable content and links from one web page.',
      'parameters': {
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
    },
  },
];

final class OllamaCloudToolResult {
  const OllamaCloudToolResult({required this.value, this.isError = false});

  final Object? value;
  final bool isError;

  String get toolMessageContent => jsonEncode(value);
}

/// Per-completion trust boundary for Ollama Cloud's autonomous web tools.
///
/// A fetch may use only an exact public URL returned by a search in this
/// session. This prevents model-generated or prompt-injected content from
/// adding chat data to a new destination between agent rounds.
final class OllamaCloudToolSession {
  final Set<String> _searchResultUrls = <String>{};

  Future<OllamaCloudToolResult> execute({
    required Dio dio,
    required String name,
    required Map<String, dynamic> arguments,
    required CancelToken cancelToken,
  }) async {
    try {
      return switch (name) {
        'web_search' => OllamaCloudToolResult(
          value: await _webSearch(
            dio,
            arguments,
            allowedFetchUrls: _searchResultUrls,
            cancelToken: cancelToken,
          ),
        ),
        'web_fetch' => OllamaCloudToolResult(
          value: await _webFetch(
            dio,
            arguments,
            allowedFetchUrls: _searchResultUrls,
            cancelToken: cancelToken,
          ),
        ),
        _ => OllamaCloudToolResult(
          value: {'error': 'Tool "$name" is not available.'},
          isError: true,
        ),
      };
    } on FormatException catch (error) {
      return OllamaCloudToolResult(
        value: {'error': error.message},
        isError: true,
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) rethrow;
      DebugLogger.warning(
        'tool-call-failed',
        scope: 'direct-connections/ollama-cloud',
      );
      return OllamaCloudToolResult(
        value: {'error': 'Ollama Cloud could not complete this tool call.'},
        isError: true,
      );
    }
  }
}

Future<Map<String, dynamic>> _webSearch(
  Dio dio,
  Map<String, dynamic> arguments, {
  required Set<String> allowedFetchUrls,
  required CancelToken cancelToken,
}) async {
  _rejectUnexpectedArguments(arguments, const {'query', 'max_results'});
  final query = _requiredString(
    arguments,
    'query',
    maxCharacters: kOllamaCloudMaxQueryCharacters,
  );
  final rawMaxResults = arguments['max_results'];
  final maxResults = switch (rawMaxResults) {
    null => 5,
    int value when value >= 1 && value <= kOllamaCloudMaxSearchResults => value,
    _ => throw const FormatException(
      'Web search max_results must be an integer from 1 to 10.',
    ),
  };
  final response = await dio.post<ResponseBody>(
    'api/web_search',
    data: {'query': query, 'max_results': maxResults},
    cancelToken: cancelToken,
    options: Options(responseType: ResponseType.stream),
  );
  final body = await _responseJson(response, 'web search');
  final rawResults = body['results'];
  if (rawResults is! List) {
    throw const FormatException('Ollama web search returned no results list.');
  }
  final results = <Map<String, dynamic>>[];
  var remaining = kOllamaCloudMaxToolResultCharacters;
  for (final raw in rawResults.take(maxResults)) {
    if (raw is! Map) continue;
    final title = _boundedText(raw['title'], remaining.clamp(0, 2048));
    remaining -= title.length;
    final rawUrl = _boundedText(raw['url'], kOllamaCloudMaxUrlCharacters);
    late final String url;
    try {
      url = normalizeOllamaCloudPublicWebUrl(rawUrl);
    } on FormatException {
      continue;
    }
    if (url.length > remaining) break;
    remaining -= url.length;
    final content = _boundedText(raw['content'], remaining.clamp(0, 32768));
    remaining -= content.length;
    allowedFetchUrls.add(url);
    results.add({'title': title, 'url': url, 'content': content});
    if (remaining <= 0) break;
  }
  return {'results': results};
}

Future<Map<String, dynamic>> _webFetch(
  Dio dio,
  Map<String, dynamic> arguments, {
  required Set<String> allowedFetchUrls,
  required CancelToken cancelToken,
}) async {
  _rejectUnexpectedArguments(arguments, const {'url'});
  final value = _requiredString(
    arguments,
    'url',
    maxCharacters: kOllamaCloudMaxUrlCharacters,
  );
  final url = normalizeOllamaCloudPublicWebUrl(value);
  if (!allowedFetchUrls.contains(url)) {
    throw const FormatException(
      'Web fetch requires an exact URL returned by the current web search.',
    );
  }
  final response = await dio.post<ResponseBody>(
    'api/web_fetch',
    data: {'url': url},
    cancelToken: cancelToken,
    options: Options(responseType: ResponseType.stream),
  );
  final body = await _responseJson(response, 'web fetch');
  var remaining = kOllamaCloudMaxToolResultCharacters;
  final title = _boundedText(body['title'], remaining.clamp(0, 4096));
  remaining -= title.length;
  final content = _boundedText(body['content'], remaining);
  remaining -= content.length;
  final links = <String>[];
  final rawLinks = body['links'];
  if (rawLinks is Iterable) {
    for (final link in rawLinks.take(100)) {
      if (remaining <= 0) break;
      final normalized = _boundedText(
        link,
        remaining.clamp(0, kOllamaCloudMaxUrlCharacters),
      );
      if (normalized.isNotEmpty) links.add(normalized);
      remaining -= normalized.length;
    }
  }
  return {'title': title, 'content': content, 'links': links};
}

/// Canonicalizes a model-supplied URL for Ollama Cloud's web tools.
String normalizeOllamaCloudPublicWebUrl(String value) =>
    normalizePublicWebUrl(value);

Future<Map<String, dynamic>> _responseJson(
  Response<ResponseBody> response,
  String operation,
) async {
  final body = response.data;
  if (body == null) {
    throw FormatException('Ollama $operation returned an empty response.');
  }
  return decodeDirectJsonBody(body);
}

void _rejectUnexpectedArguments(
  Map<String, dynamic> arguments,
  Set<String> allowed,
) {
  if (arguments.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException(
      'The tool call contains unsupported arguments.',
    );
  }
}

String _requiredString(
  Map<String, dynamic> arguments,
  String key, {
  required int maxCharacters,
}) {
  final value = arguments[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Tool argument "$key" is required.');
  }
  final normalized = value.trim();
  if (normalized.length > maxCharacters) {
    throw FormatException('Tool argument "$key" is too long.');
  }
  return normalized;
}

String _boundedText(Object? value, int maxCharacters) {
  if (maxCharacters <= 0) return '';
  final text = value?.toString() ?? '';
  return text.length <= maxCharacters ? text : text.substring(0, maxCharacters);
}
