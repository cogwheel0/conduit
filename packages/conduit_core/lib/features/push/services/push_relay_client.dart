import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:conduit_core/network/conduit_user_agent.dart';

/// The push relay this build uses, from `--dart-define=CONDUIT_PUSH_RELAY_URL`.
///
/// Empty in a build without one: APNs and FCM are then unavailable, and only
/// UnifiedPush works (on Android).
const String kConduitPushRelayUrl = String.fromEnvironment(
  'CONDUIT_PUSH_RELAY_URL',
);

/// `GET /v1/info`.
final class PushRelayInfo {
  const PushRelayInfo({
    required this.proto,
    required this.activeKid,
    required this.maxBody,
    required this.providers,
  });

  final int proto;

  /// The key id new endpoints are sealed with. A device whose endpoint
  /// carries an older one registers again.
  final int activeKid;
  final int maxBody;

  /// `apns` and/or `fcm`: the providers this relay can deliver to.
  final List<String> providers;
}

/// `POST /v1/register`.
final class PushRelayRegistration {
  const PushRelayRegistration({required this.endpoint, required this.kid});

  final String endpoint;
  final int kid;
}

enum PushRelayErrorKind {
  /// 400 `invalid_request`.
  invalidRequest,

  /// 403 `app_not_allowed`: the relay does not serve this app.
  appNotAllowed,

  /// 429 `rate_limited`.
  rateLimited,

  /// 503 `provider_unconfigured`: the relay cannot reach that provider.
  providerUnconfigured,

  /// Another HTTP error.
  server,

  /// The relay could not be reached.
  network,

  /// The relay answered something that is not its API.
  invalidResponse,
}

final class PushRelayException implements Exception {
  const PushRelayException(this.kind, {this.statusCode, this.retryAfter});

  final PushRelayErrorKind kind;
  final int? statusCode;

  /// From `Retry-After` on a 429.
  final Duration? retryAfter;

  @override
  String toString() =>
      'PushRelayException(${kind.name}${statusCode == null ? '' : ', $statusCode'})';
}

/// Talks to the stateless push relay (PROTOCOL §5).
///
/// The relay must never learn which account or server a device uses, so this
/// is a plain [Dio]: no auth interceptors, no cookies, no account headers.
/// The only header besides the body's content type is the product
/// User-Agent.
final class PushRelayClient {
  PushRelayClient({required String baseUrl, Dio? dio})
    : _dio = dio ?? Dio(),
      _base = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl {
    _dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..sendTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 15)
      ..followRedirects = false
      ..responseType = ResponseType.plain
      ..validateStatus = ((_) => true);
  }

  final Dio _dio;
  final String _base;

  /// The relay this client talks to.
  String get baseUrl => _base;

  Options get _options =>
      Options(headers: {ConduitUserAgent.headerName: ConduitUserAgent.value});

  Future<PushRelayInfo> info() async {
    final response = await _send(
      () => _dio.get<String>('$_base/v1/info', options: _options),
    );
    final body = _body(response);
    final activeKid = body['active_kid'];
    final proto = body['proto'];
    if (response.statusCode != 200 || activeKid is! int || proto is! int) {
      throw _error(response);
    }
    final maxBody = body['max_body'];
    final providers = body['providers'];
    return PushRelayInfo(
      proto: proto,
      activeKid: activeKid,
      maxBody: maxBody is int ? maxBody : 0,
      providers: providers is List
          ? providers.whereType<String>().toList(growable: false)
          : const [],
    );
  }

  Future<PushRelayRegistration> register({
    required String provider,
    required String token,
    required String app,
    required String env,
    required String sid,
  }) async {
    final response = await _send(
      () => _dio.post<String>(
        '$_base/v1/register',
        data: jsonEncode({
          'provider': provider,
          'token': token,
          'app': app,
          'env': env,
          'sid': sid,
        }),
        options: _options.copyWith(contentType: Headers.jsonContentType),
      ),
    );
    final body = _body(response);
    final endpoint = body['endpoint'];
    final kid = body['kid'];
    if (response.statusCode != 200 ||
        endpoint is! String ||
        kid is! int ||
        !endpoint.startsWith('https://')) {
      throw _error(response);
    }
    return PushRelayRegistration(endpoint: endpoint, kid: kid);
  }

  /// The key id sealed into a relay [endpoint]: the second byte of its last
  /// path segment, after the format byte `0x01`. Null for anything else,
  /// such as a UnifiedPush endpoint.
  static int? kidOfEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final segment = uri.pathSegments.last;
    if (segment.length < 4) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(segment));
      if (bytes.length < 2 || bytes[0] != 0x01) return null;
      return bytes[1];
    } on FormatException {
      return null;
    }
  }

  void close() => _dio.close();

  Future<Response<String>> _send(
    Future<Response<String>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException {
      throw const PushRelayException(PushRelayErrorKind.network);
    }
  }

  static Map<String, Object?> _body(Response<String> response) {
    final data = response.data;
    if (data == null || data.isEmpty) return const {};
    try {
      final decoded = jsonDecode(data);
      return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
    } on FormatException {
      return const {};
    }
  }

  static PushRelayException _error(Response<String> response) {
    final status = response.statusCode;
    final code = _body(response)['error'];
    final kind = switch ((status, code)) {
      (400, _) => PushRelayErrorKind.invalidRequest,
      (403, 'app_not_allowed') => PushRelayErrorKind.appNotAllowed,
      (429, _) => PushRelayErrorKind.rateLimited,
      (503, 'provider_unconfigured') => PushRelayErrorKind.providerUnconfigured,
      (200, _) => PushRelayErrorKind.invalidResponse,
      _ => PushRelayErrorKind.server,
    };
    Duration? retryAfter;
    if (status == 429) {
      final seconds = int.tryParse(
        response.headers.value('retry-after')?.trim() ?? '',
      );
      if (seconds != null && seconds >= 0) {
        retryAfter = Duration(seconds: seconds);
      }
    }
    return PushRelayException(kind, statusCode: status, retryAfter: retryAfter);
  }
}
