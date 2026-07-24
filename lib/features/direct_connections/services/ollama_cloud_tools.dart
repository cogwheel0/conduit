import 'dart:convert';
import 'dart:io';

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

String normalizeOllamaCloudPublicWebUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) {
    throw const FormatException('Web fetch URL is invalid.');
  }
  if (!uri.hasScheme) {
    throw const FormatException('Web fetch URL must be absolute.');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException('Web fetch URL must use HTTP or HTTPS.');
  }
  if (uri.host.isEmpty) {
    throw const FormatException('Web fetch URL must include a host.');
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Web fetch URL must not include user information.',
    );
  }
  // DNS treats a terminal dot as the same absolute hostname. Canonicalize it
  // before applying the public-host boundary so `localhost.` and IP literals
  // with a terminal dot cannot bypass the checks below.
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
  if (host == 'localhost' ||
      host.isEmpty ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      _isPrivateOrSpecialIpLiteral(host)) {
    throw const FormatException('Web fetch requires a public URL.');
  }
  return uri.removeFragment().toString();
}

bool _isPrivateOrSpecialIpLiteral(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return _isPrivateOrSpecialIpv4(bytes);
  }
  final isUnspecified = bytes.every((byte) => byte == 0);
  final isLoopback =
      bytes.take(15).every((byte) => byte == 0) && bytes.last == 1;
  final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
  final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  final isMulticast = bytes[0] == 0xff;
  final isIpv4Mapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  final isIpv4Compatible = bytes.take(12).every((byte) => byte == 0);
  return isUnspecified ||
      isLoopback ||
      isUniqueLocal ||
      isLinkLocal ||
      isMulticast ||
      ((isIpv4Mapped || isIpv4Compatible) &&
          _isPrivateOrSpecialIpv4(bytes.sublist(12)));
}

bool _isPrivateOrSpecialIpv4(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 198 && (second == 18 || second == 19)) ||
      first >= 224;
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
