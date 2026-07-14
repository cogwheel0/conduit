import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:conduit/core/network/conduit_user_agent.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

const _serverUrl = 'https://host.example/openwebui';

void main() {
  group('ApiAuthInterceptor', () {
    test('signin request remains public without auth header', () async {
      final interceptor = ApiAuthInterceptor(serverUrl: _serverUrl);
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(path: '/api/v1/auths/signin');

      interceptor.onRequest(options, handler);
      final forwarded = await handler.forwardedRequest;

      expect(forwarded, isNotNull);
      expect(forwarded!.headers.containsKey('Authorization'), isFalse);
    });

    test(
      'optional config request attaches auth header when token exists',
      () async {
        final interceptor = ApiAuthInterceptor(
          serverUrl: _serverUrl,
          authToken: 'token',
        );
        final handler = _TestRequestInterceptorHandler();
        final options = RequestOptions(path: '/api/config');

        interceptor.onRequest(options, handler);
        final forwarded = await handler.forwardedRequest;

        expect(forwarded, isNotNull);
        expect(forwarded!.headers['Authorization'], 'Bearer token');
      },
    );

    test('cross-origin absolute request strips server credentials', () async {
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'server-token',
        customHeaders: const {'X-Proxy-Credential': 'server-proxy-secret'},
      );
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(
        path: 'https://cdn.example/avatar.png',
        headers: {
          'authorization': 'Bearer inherited-token',
          'x-proxy-credential': 'inherited-proxy-secret',
          'X-Request-Header': 'preserved',
        },
      );

      interceptor.onRequest(options, handler);
      final forwarded = await handler.forwardedRequest;

      expect(forwarded, isNotNull);
      final headerNames = forwarded!.headers.keys
          .map((header) => header.toLowerCase())
          .toSet();
      expect(headerNames, isNot(contains('authorization')));
      expect(headerNames, isNot(contains('x-proxy-credential')));
      expect(
        forwarded.headers[ConduitUserAgent.headerName],
        ConduitUserAgent.runtimeDefaultValue,
      );
      expect(
        forwarded.headers[ConduitUserAgent.headerName],
        isNot(ConduitUserAgent.value),
      );
      expect(forwarded.headers['X-Request-Header'], 'preserved');
    });

    test('cross-origin base URL strips server credentials', () async {
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'server-token',
        customHeaders: const {'X-Proxy-Credential': 'server-proxy-secret'},
      );
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(
        baseUrl: 'https://cdn.example',
        path: '/avatar.png',
        headers: {
          'Authorization': 'Bearer inherited-token',
          'X-Proxy-Credential': 'inherited-proxy-secret',
        },
      );

      interceptor.onRequest(options, handler);
      final forwarded = await handler.forwardedRequest;

      expect(forwarded, isNotNull);
      final headerNames = forwarded!.headers.keys
          .map((header) => header.toLowerCase())
          .toSet();
      expect(headerNames, isNot(contains('authorization')));
      expect(headerNames, isNot(contains('x-proxy-credential')));
    });

    test('same-origin absolute request receives server credentials', () async {
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'server-token',
        customHeaders: const {'X-Proxy-Credential': 'proxy-secret'},
      );
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(path: 'https://host.example/api/models');

      interceptor.onRequest(options, handler);
      final forwarded = await handler.forwardedRequest;

      expect(forwarded, isNotNull);
      expect(forwarded!.headers['Authorization'], 'Bearer server-token');
      expect(forwarded.headers['X-Proxy-Credential'], 'proxy-secret');
      expect(
        forwarded.headers[ConduitUserAgent.headerName],
        ConduitUserAgent.value,
      );
    });

    test(
      'configured User-Agent cannot override the Conduit identity',
      () async {
        final interceptor = ApiAuthInterceptor(
          serverUrl: _serverUrl,
          customHeaders: const {'uSeR-aGeNt': 'spoofed-agent'},
        );
        final handler = _TestRequestInterceptorHandler();
        final options = RequestOptions(path: '/health');

        interceptor.onRequest(options, handler);
        final forwarded = await handler.forwardedRequest;

        expect(forwarded, isNotNull);
        expect(
          forwarded!.headers[ConduitUserAgent.headerName],
          ConduitUserAgent.value,
        );
        expect(forwarded.headers.keys.where(ConduitUserAgent.isHeaderName), [
          ConduitUserAgent.headerName,
        ]);
      },
    );

    test('current auth snapshot forwards its captured token', () async {
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'account-a',
      );
      final snapshot = interceptor.captureSnapshot();
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(
        path: '/api/v1/files/file-id',
        extra: {ApiAuthInterceptor.authSnapshotExtraKey: snapshot},
      );

      interceptor.onRequest(options, handler);
      final forwarded = await handler.forwardedRequest;

      expect(forwarded?.headers['Authorization'], 'Bearer account-a');
    });

    test('stale auth snapshot rejects locally after token rotation', () async {
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'account-a',
      );
      final snapshot = interceptor.captureSnapshot();
      interceptor.updateAuthToken('account-b');
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(
        path: '/api/v1/files/file-id',
        extra: {ApiAuthInterceptor.authSnapshotExtraKey: snapshot},
      );

      interceptor.onRequest(options, handler);
      final rejected = await handler.rejectedError;

      expect(rejected?.type, DioExceptionType.cancel);
      expect(options.headers.containsKey('Authorization'), isFalse);
    });

    test(
      'logout and reauthentication invalidate a snapshot even if the token repeats',
      () async {
        final interceptor = ApiAuthInterceptor(
          serverUrl: _serverUrl,
          authToken: 'shared-token',
        );
        final snapshot = interceptor.captureSnapshot();
        interceptor.updateAuthToken(null);
        interceptor.updateAuthToken('shared-token');
        final handler = _TestRequestInterceptorHandler();
        final options = RequestOptions(
          path: '/api/chat/completed',
          extra: {ApiAuthInterceptor.authSnapshotExtraKey: snapshot},
        );

        interceptor.onRequest(options, handler);
        final rejected = await handler.rejectedError;

        expect(rejected?.type, DioExceptionType.cancel);
        expect(options.headers.containsKey('Authorization'), isFalse);
      },
    );

    test('admin configs models request requires auth', () async {
      final interceptor = ApiAuthInterceptor(serverUrl: _serverUrl);
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(path: '/api/v1/configs/models');

      interceptor.onRequest(options, handler);
      final error = await handler.rejectedError;

      expect(error, isNotNull);
      expect(error!.response?.statusCode, 401);
    });

    test('ollama ps request requires auth', () async {
      final interceptor = ApiAuthInterceptor(serverUrl: _serverUrl);
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(path: '/ollama/api/ps');

      interceptor.onRequest(options, handler);
      final error = await handler.rejectedError;

      expect(error, isNotNull);
      expect(error!.response?.statusCode, 401);
    });

    test('401 on auth validation endpoint notifies auth failure', () async {
      var authFailureCount = 0;
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'token',
        onAuthTokenInvalid: () {
          authFailureCount++;
        },
      );
      final handler = _TestErrorInterceptorHandler();

      interceptor.onError(_dioError(401, '/api/v1/auths/'), handler);
      await handler.done;

      expect(authFailureCount, 1);
    });

    test(
      '401 from cross-origin auth-shaped path does not notify auth failure',
      () async {
        var authFailureCount = 0;
        final interceptor = ApiAuthInterceptor(
          serverUrl: _serverUrl,
          authToken: 'token',
          onAuthTokenInvalid: () {
            authFailureCount++;
          },
        );
        final handler = _TestErrorInterceptorHandler();

        interceptor.onError(
          _dioError(401, 'https://cdn.example/api/v1/auths/'),
          handler,
        );
        await handler.done;

        expect(authFailureCount, 0);
      },
    );

    test(
      'auth validation under a server base-path still notifies auth failure',
      () async {
        var authFailureCount = 0;
        final interceptor = ApiAuthInterceptor(
          serverUrl: _serverUrl,
          authToken: 'token',
          onAuthTokenInvalid: () {
            authFailureCount++;
          },
        );
        final request = RequestOptions(
          baseUrl: 'https://host.example/openwebui',
          path: '/api/v1/auths/',
        );
        final handler = _TestErrorInterceptorHandler();

        expect(request.uri.path, '/openwebui/api/v1/auths/');
        interceptor.onError(
          DioException(
            requestOptions: request,
            response: Response<dynamic>(
              requestOptions: request,
              statusCode: 401,
            ),
            type: DioExceptionType.badResponse,
          ),
          handler,
        );
        await handler.done;

        expect(authFailureCount, 1);
      },
    );

    test(
      'suppressed auth validation error does not notify auth failure',
      () async {
        var authFailureCount = 0;
        final interceptor = ApiAuthInterceptor(
          serverUrl: _serverUrl,
          authToken: 'token',
          onAuthTokenInvalid: () {
            authFailureCount++;
          },
        );
        final handler = _TestErrorInterceptorHandler();

        interceptor.onError(
          _dioError(
            401,
            '/api/v1/auths/',
            extra: const {'suppressAuthFailureNotification': true},
          ),
          handler,
        );
        await handler.done;

        expect(authFailureCount, 0);
      },
    );

    test('403 on audio config endpoint does not notify auth failure', () async {
      var authFailureCount = 0;
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'token',
        onAuthTokenInvalid: () {
          authFailureCount++;
        },
      );
      final handler = _TestErrorInterceptorHandler();

      interceptor.onError(_dioError(403, '/api/v1/audio/config'), handler);
      await handler.done;

      expect(authFailureCount, 0);
    });

    test('403 on notes endpoint does not notify auth failure', () async {
      var authFailureCount = 0;
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'token',
        onAuthTokenInvalid: () {
          authFailureCount++;
        },
      );
      final handler = _TestErrorInterceptorHandler();

      interceptor.onError(_dioError(403, '/api/v1/notes'), handler);
      await handler.done;

      expect(authFailureCount, 0);
    });

    test('auth diagnostics never include path or query values', () async {
      const pathSecret = 'opaque-path-secret';
      const querySecret = 'query-secret';
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      final interceptor = ApiAuthInterceptor(
        serverUrl: _serverUrl,
        authToken: 'token',
      );
      final handler = _TestErrorInterceptorHandler();

      try {
        interceptor.onError(
          _dioError(403, '/api/v1/notes/$pathSecret?token=$querySecret'),
          handler,
        );
        await handler.done;
      } finally {
        debugPrint = previousDebugPrint;
      }

      final combined = logs.join('\n');
      expect(combined, contains('403 on non-essential endpoint'));
      expect(combined, isNot(contains(pathSecret)));
      expect(combined, isNot(contains(querySecret)));
    });
  });
}

DioException _dioError(
  int statusCode,
  String path, {
  Map<String, dynamic>? extra,
}) {
  final request = RequestOptions(path: path, extra: extra);
  return DioException(
    requestOptions: request,
    response: Response<dynamic>(
      requestOptions: request,
      statusCode: statusCode,
    ),
    type: DioExceptionType.badResponse,
  );
}

class _TestErrorInterceptorHandler extends ErrorInterceptorHandler {
  Future<void> get done async {
    try {
      await future;
    } catch (_) {
      // `handler.next(error)` completes with an error by design.
    }
  }
}

class _TestRequestInterceptorHandler extends RequestInterceptorHandler {
  Future<RequestOptions?> get forwardedRequest async {
    try {
      final state = await future;
      final data = state.data;
      return data is RequestOptions ? data : null;
    } catch (_) {
      return null;
    }
  }

  Future<DioException?> get rejectedError async {
    try {
      await future;
      return null;
    } catch (error) {
      final dynamic state = error;
      final data = state.data;
      if (data is DioException) {
        return data;
      }
      return null;
    }
  }
}
