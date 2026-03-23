import 'package:conduit/core/auth/api_auth_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiAuthInterceptor', () {
    test('signin request remains public without auth header', () async {
      final interceptor = ApiAuthInterceptor();
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
        final interceptor = ApiAuthInterceptor(authToken: 'token');
        final handler = _TestRequestInterceptorHandler();
        final options = RequestOptions(path: '/api/config');

        interceptor.onRequest(options, handler);
        final forwarded = await handler.forwardedRequest;

        expect(forwarded, isNotNull);
        expect(forwarded!.headers['Authorization'], 'Bearer token');
      },
    );

    test('admin configs models request requires auth', () async {
      final interceptor = ApiAuthInterceptor();
      final handler = _TestRequestInterceptorHandler();
      final options = RequestOptions(path: '/api/v1/configs/models');

      interceptor.onRequest(options, handler);
      final error = await handler.rejectedError;

      expect(error, isNotNull);
      expect(error!.response?.statusCode, 401);
    });

    test('ollama ps request requires auth', () async {
      final interceptor = ApiAuthInterceptor();
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

    test('403 on audio config endpoint does not notify auth failure', () async {
      var authFailureCount = 0;
      final interceptor = ApiAuthInterceptor(
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
  });
}

DioException _dioError(int statusCode, String path) {
  final request = RequestOptions(path: path);
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
