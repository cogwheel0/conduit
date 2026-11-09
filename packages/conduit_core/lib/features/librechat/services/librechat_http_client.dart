import 'package:dio/dio.dart';

import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_user_agent.dart';
import 'package:conduit_core/network/same_origin_redirect_interceptor.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';

/// Request extras the LibreChat interceptor reads.
abstract final class LibreChatRequestExtra {
  /// Set to false for a request that must not carry the session (sign-in,
  /// the public config).
  static const String authenticate = 'librechat.authenticate';

  /// Cookies to send instead of the session's, for the auth routes that run
  /// before there is a session handle (`LibreChatCookies`).
  static const String cookies = 'librechat.cookies';

  /// The access token a request went out with, so a refusal renews only past
  /// that token.
  static const String token = 'librechat.token';

  /// Marks the one retry after a renewal.
  static const String retried = 'librechat.retried';
}

/// The Dio every request to one LibreChat server goes through.
///
/// What it guarantees, whoever builds the request:
///
/// - Every request carries [LibreChatUserAgent]. LibreChat bans the user and
///   their IP for a chat or file request that does not look like a browser's.
/// - No request carries an `Origin` header. LibreChat's same-origin check on
///   sign-in lets through requests without one, and a native client has no
///   origin to give.
/// - The session's token and cookies go only to [LibreChatServer.owns]
///   addresses. Redirects are not followed by the HTTP client; same-origin
///   ones are replayed through this Dio again.
/// - A request refused with 401 renews the session once and runs again.
final class LibreChatHttpClient {
  LibreChatHttpClient({
    required this.server,
    this.session,
    HttpClientAdapter? adapter,
    String? userAgent,
    DateTime Function()? clock,
  }) : userAgent = userAgent ?? LibreChatUserAgent.value,
       _clock = clock ?? DateTime.now {
    dio = Dio(
      BaseOptions(
        baseUrl: server.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 90),
        followRedirects: false,
        maxRedirects: 0,
      ),
    );
    if (adapter != null) {
      dio.httpClientAdapter = adapter;
    } else {
      ServerTlsHttpClientFactory.configureDio(
        dio,
        server.toTlsServerConfig(),
        userAgent: this.userAgent,
      );
    }
    dio.interceptors
      ..add(_LibreChatInterceptor(this))
      ..add(SameOriginRedirectInterceptor(dio, prepareReplay: (_) {}));
  }

  final LibreChatServer server;

  /// The signed-in session, or null for a client that only signs in.
  final LibreChatSessionHandle? session;

  final String userAgent;
  final DateTime Function() _clock;

  late final Dio dio;

  void close() => dio.close(force: true);

  static const Set<String> _protectedHeaders = {
    'user-agent',
    'authorization',
    'cookie',
    'origin',
    'host',
  };

  void _prepare(RequestOptions options, LibreChatCookies? cookies) {
    // A fresh map rather than removals in place: inserting into Dio's
    // case-insensitive header map after removing from it fails on this SDK
    // (the removed slot's sentinel reaches the custom equality).
    final headers = <String, dynamic>{
      for (final entry in server.customHeaders.entries)
        if (!_protectedHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    for (final entry in options.headers.entries) {
      final lower = entry.key.toLowerCase();
      if (lower == 'user-agent' || lower == 'origin' || lower == 'cookie') {
        continue;
      }
      headers[entry.key] = entry.value;
    }
    headers['User-Agent'] = userAgent;
    final cookieHeader = cookies?.headerFor(options.uri.path, now: _clock());
    if (cookieHeader != null) headers['Cookie'] = cookieHeader;
    options.headers = headers;
  }
}

final class _LibreChatInterceptor extends Interceptor {
  _LibreChatInterceptor(this._client);

  final LibreChatHttpClient _client;

  bool _authenticates(RequestOptions options) =>
      options.extra[LibreChatRequestExtra.authenticate] != false;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_client.server.owns(options.uri)) {
      return handler.reject(
        DioException(
          requestOptions: options,
          error: const LibreChatApiException(
            message: 'Refused to send a LibreChat request to another server.',
          ),
        ),
      );
    }
    final handle = _client.session;
    if (handle == null || !_authenticates(options)) {
      _client._prepare(
        options,
        options.extra[LibreChatRequestExtra.cookies] as LibreChatCookies?,
      );
      return handler.next(options);
    }
    try {
      final session = await handle.fresh();
      _client._prepare(options, session.cookies);
      options.headers['Authorization'] = 'Bearer ${session.accessToken}';
      options.extra[LibreChatRequestExtra.token] = session.accessToken;
      handler.next(options);
    } on LibreChatApiException catch (error) {
      handler.reject(
        DioException(requestOptions: options, error: error),
      );
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    await _absorb(response);
    if (response.requestOptions.responseType != ResponseType.stream &&
        LibreChatIllegalRequestException.matches(response.data)) {
      return handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          error: const LibreChatIllegalRequestException(),
        ),
      );
    }
    handler.next(response);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    if (response != null) await _absorb(response);
    final options = err.requestOptions;
    final handle = _client.session;
    final token = options.extra[LibreChatRequestExtra.token] as String?;
    if (response?.statusCode != 401 ||
        handle == null ||
        token == null ||
        options.extra[LibreChatRequestExtra.retried] == true ||
        options.data is Stream) {
      return handler.next(err);
    }
    try {
      await handle.renewAfterRefusal(token);
    } on LibreChatApiException catch (error) {
      return handler.next(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
          error: error,
        ),
      );
    } catch (_) {
      return handler.next(err);
    }
    final data = options.data;
    final retry = options.copyWith(
      // A multipart body is consumed by the first attempt.
      data: data is FormData ? data.clone() : data,
      extra: Map<String, dynamic>.of(options.extra)
        ..[LibreChatRequestExtra.retried] = true,
    );
    try {
      handler.resolve(await _client.dio.fetch<dynamic>(retry));
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  Future<void> _absorb(Response<dynamic> response) async {
    final handle = _client.session;
    final setCookie = response.headers['set-cookie'];
    if (handle == null ||
        setCookie == null ||
        setCookie.isEmpty ||
        !_authenticates(response.requestOptions)) {
      return;
    }
    await handle.absorbCookies(setCookie);
  }
}

/// The [LibreChatApiException] behind a failed LibreChat request.
LibreChatApiException libreChatErrorOf(
  DioException error, {
  String? fallback,
}) {
  final cause = error.error;
  if (cause is LibreChatApiException) return cause;
  final response = error.response;
  if (response == null) {
    return LibreChatApiException(
      message: fallback ?? 'Could not reach the LibreChat server.',
    );
  }
  return LibreChatApiException.fromResponse(
    response,
    fallback: fallback ?? 'The LibreChat server refused the request.',
  );
}
