/// Reads the OpenAPI document of a personal tool server and checks a personal
/// terminal, using the connection's own credentials.
///
/// These requests go to hosts the user configured, not to the Open WebUI
/// server, so they use a plain client: the Open WebUI session token must never
/// ride along, and the stored key must not be stripped as a foreign
/// credential. Every call is a read.
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:yaml/yaml.dart' as yaml;

import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/utils/json_normalization.dart';

enum PersonalConnectionProbeFailure {
  /// The entry has no usable URL or path.
  invalidTarget,

  /// The entry uses an auth mode this client cannot send.
  unsupportedAuth,

  /// The host answered 401 or 403.
  unauthorized,

  /// The host did not answer, or answered with an error or a redirect.
  unreachable,

  /// The host answered, but not with an OpenAPI document.
  invalidSpec,
}

class PersonalConnectionProbeException implements Exception {
  const PersonalConnectionProbeException(this.failure, {this.statusCode});

  final PersonalConnectionProbeFailure failure;
  final int? statusCode;

  @override
  String toString() =>
      'PersonalConnectionProbeException(${failure.name}'
      '${statusCode == null ? '' : ', $statusCode'})';
}

/// What a successful tool-server check found.
class PersonalToolServerProbe {
  const PersonalToolServerProbe({
    required this.spec,
    required this.operationCount,
  });

  final Map<String, dynamic> spec;
  final int operationCount;
}

const Duration _timeout = Duration(seconds: 15);
const Set<String> _httpMethods = <String>{
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

Dio _plainClient() => Dio(
  BaseOptions(
    connectTimeout: _timeout,
    receiveTimeout: _timeout,
    sendTimeout: _timeout,
    validateStatus: (status) => status != null && status >= 200 && status < 300,
  ),
);

/// The Authorization header value for [entry], or null when it sends none.
///
/// `session` auth is refused: it would hand the Open WebUI session token to a
/// host the user configured, which this client never does.
String? personalConnectionAuthorization(Map<String, dynamic> entry) {
  final authType = (entry['auth_type']?.toString().trim().isNotEmpty ?? false)
      ? entry['auth_type'].toString().trim()
      : 'bearer';
  switch (authType) {
    case 'none':
      return null;
    case 'bearer':
      final key = entry['key']?.toString().trim() ?? '';
      return key.isEmpty ? null : 'Bearer $key';
    default:
      throw const PersonalConnectionProbeException(
        PersonalConnectionProbeFailure.unsupportedAuth,
      );
  }
}

PersonalConnectionProbeException _mapDioError(DioException error) {
  final status = error.response?.statusCode;
  if (status == 401 || status == 403) {
    return PersonalConnectionProbeException(
      PersonalConnectionProbeFailure.unauthorized,
      statusCode: status,
    );
  }
  return PersonalConnectionProbeException(
    PersonalConnectionProbeFailure.unreachable,
    statusCode: status,
  );
}

Map<String, dynamic> _decodeSpec(Object? data, {required bool yamlHint}) {
  Object? decoded = data;
  if (data is String) {
    decoded = yamlHint ? yaml.loadYaml(data) : jsonDecode(data);
  }
  final map = decoded is Map ? normalizeJsonLikeMap(decoded) : null;
  if (map == null || map['paths'] is! Map) {
    throw const PersonalConnectionProbeException(
      PersonalConnectionProbeFailure.invalidSpec,
    );
  }
  return map;
}

int _countOperations(Map<String, dynamic> spec) {
  var count = 0;
  for (final item in (spec['paths'] as Map).values) {
    if (item is Map) {
      count += item.keys.where((key) => _httpMethods.contains(key)).length;
    }
  }
  return count;
}

/// Loads the OpenAPI document a personal tool server publishes.
///
/// [defaultPath] stands in for an entry that stores no `path`. `bearer` sends
/// the stored key and `none` sends nothing; any other mode throws
/// [PersonalConnectionProbeFailure.unsupportedAuth]. A credentialed request
/// does not follow redirects, so the key never leaves the configured host.
Future<PersonalToolServerProbe> probePersonalToolServer(
  Map<String, dynamic> entry, {
  String defaultPath = '',
  Dio? dio,
}) async {
  final specType = entry['spec_type']?.toString().trim() ?? '';
  if (specType == 'json') {
    final raw = entry['spec']?.toString() ?? '';
    try {
      final spec = _decodeSpec(raw, yamlHint: false);
      return PersonalToolServerProbe(
        spec: spec,
        operationCount: _countOperations(spec),
      );
    } on FormatException {
      throw const PersonalConnectionProbeException(
        PersonalConnectionProbeFailure.invalidSpec,
      );
    }
  }

  final url = personalConnectionUrl(entry);
  var path = entry['path']?.toString().trim() ?? '';
  if (path.isEmpty) path = defaultPath;
  if (url.isEmpty || path.isEmpty) {
    throw const PersonalConnectionProbeException(
      PersonalConnectionProbeFailure.invalidTarget,
    );
  }
  final target = path.contains('://')
      ? path
      : '$url${path.startsWith('/') ? '' : '/'}$path';
  if (Uri.tryParse(target)?.hasScheme != true) {
    throw const PersonalConnectionProbeException(
      PersonalConnectionProbeFailure.invalidTarget,
    );
  }
  final authorization = personalConnectionAuthorization(entry);

  final client = dio ?? _plainClient();
  final Response<dynamic> response;
  try {
    response = await client.get<dynamic>(
      target,
      options: Options(
        headers: <String, dynamic>{
          'Accept': 'application/json, application/yaml, text/yaml, */*',
          'Authorization': ?authorization,
        },
        followRedirects: authorization == null,
      ),
    );
  } on DioException catch (error) {
    throw _mapDioError(error);
  }

  final contentType = response.headers.value(Headers.contentTypeHeader) ?? '';
  final lower = target.toLowerCase();
  final yamlHint =
      lower.endsWith('.yaml') ||
      lower.endsWith('.yml') ||
      contentType.contains('yaml');
  try {
    final spec = _decodeSpec(response.data, yamlHint: yamlHint);
    return PersonalToolServerProbe(
      spec: spec,
      operationCount: _countOperations(spec),
    );
  } on FormatException {
    // YamlException is a FormatException too.
    throw const PersonalConnectionProbeException(
      PersonalConnectionProbeFailure.invalidSpec,
    );
  }
}

/// Checks that a personal terminal answers `GET /api/config`, the call the
/// reference client uses to verify a terminal connection.
Future<void> probePersonalTerminal(
  Map<String, dynamic> entry, {
  Dio? dio,
}) async {
  final url = personalConnectionUrl(entry);
  if (url.isEmpty || Uri.tryParse(url)?.hasScheme != true) {
    throw const PersonalConnectionProbeException(
      PersonalConnectionProbeFailure.invalidTarget,
    );
  }
  final key = entry['key']?.toString().trim() ?? '';
  final client = dio ?? _plainClient();
  try {
    await client.get<dynamic>(
      '$url/api/config',
      options: Options(
        headers: <String, dynamic>{
          'Accept': 'application/json',
          if (key.isNotEmpty) 'Authorization': 'Bearer $key',
        },
        followRedirects: key.isEmpty,
      ),
    );
  } on DioException catch (error) {
    throw _mapDioError(error);
  }
}
