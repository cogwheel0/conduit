import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/utils/debug_logger.dart';
import 'direct_adapter_helpers.dart';

const int kOllamaCloudMaxAgentRounds = 8;
const int kOllamaCloudMaxToolCalls = 16;
const int kOllamaCloudMaxSearchResults = 10;
const int kOllamaCloudMaxQueryCharacters = 2048;
const int kOllamaCloudMaxUrlCharacters = 4096;
const int kOllamaCloudMaxToolResultCharacters = 128 * 1024;

const List<Map<String, dynamic>> kOllamaCloudWebToolDefinitions = [
  {
    'type': 'function',
    'function': {
      'name': 'web_search',
      'description':
          'Search the web for current information. Use web_fetch to read a result in detail.',
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

Future<OllamaCloudToolResult> executeOllamaCloudTool({
  required Dio dio,
  required String name,
  required Map<String, dynamic> arguments,
  required CancelToken cancelToken,
}) async {
  try {
    return switch (name) {
      'web_search' => OllamaCloudToolResult(
        value: await _webSearch(dio, arguments, cancelToken: cancelToken),
      ),
      'web_fetch' => OllamaCloudToolResult(
        value: await _webFetch(dio, arguments, cancelToken: cancelToken),
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
  } catch (_) {
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

Future<Map<String, dynamic>> _webSearch(
  Dio dio,
  Map<String, dynamic> arguments, {
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
    final title = _boundedText(raw['title'], 2048);
    final url = _boundedText(raw['url'], kOllamaCloudMaxUrlCharacters);
    final content = _boundedText(raw['content'], remaining.clamp(0, 32768));
    remaining -= title.length + url.length + content.length;
    results.add({'title': title, 'url': url, 'content': content});
    if (remaining <= 0) break;
  }
  return {'results': results};
}

Future<Map<String, dynamic>> _webFetch(
  Dio dio,
  Map<String, dynamic> arguments, {
  required CancelToken cancelToken,
}) async {
  _rejectUnexpectedArguments(arguments, const {'url'});
  final value = _requiredString(
    arguments,
    'url',
    maxCharacters: kOllamaCloudMaxUrlCharacters,
  );
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Web fetch requires an absolute HTTP or HTTPS URL.',
    );
  }
  final response = await dio.post<ResponseBody>(
    'api/web_fetch',
    data: {'url': uri.toString()},
    cancelToken: cancelToken,
    options: Options(responseType: ResponseType.stream),
  );
  final body = await _responseJson(response, 'web fetch');
  final title = _boundedText(body['title'], 4096);
  final content = _boundedText(
    body['content'],
    kOllamaCloudMaxToolResultCharacters,
  );
  final links = <String>[];
  final rawLinks = body['links'];
  if (rawLinks is Iterable) {
    for (final link in rawLinks.take(100)) {
      final normalized = _boundedText(link, kOllamaCloudMaxUrlCharacters);
      if (normalized.isNotEmpty) links.add(normalized);
    }
  }
  return {'title': title, 'content': content, 'links': links};
}

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
