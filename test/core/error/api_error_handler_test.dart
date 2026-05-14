import 'package:checks/checks.dart';
import 'package:conduit/core/error/api_error.dart';
import 'package:conduit/core/error/api_error_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper to create a [DioException] with the given type and optional
/// response status code.
DioException makeDioException(
  DioExceptionType type, {
  int? statusCode,
  dynamic responseData,
}) {
  final options = RequestOptions(path: '/test');
  return DioException(
    type: type,
    requestOptions: options,
    response: statusCode != null
        ? Response(
            requestOptions: options,
            statusCode: statusCode,
            data: responseData,
          )
        : null,
  );
}

void main() {
  late ApiErrorHandler handler;

  setUp(() {
    handler = ApiErrorHandler();
  });

  group('transformError - DioException timeout types', () {
    test('connectionTimeout maps to ApiErrorType.timeout', () {
      final error = makeDioException(DioExceptionType.connectionTimeout);
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.timeout);
    });

    test('receiveTimeout maps to ApiErrorType.timeout', () {
      final error = makeDioException(DioExceptionType.receiveTimeout);
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.timeout);
    });

    test('sendTimeout maps to ApiErrorType.timeout', () {
      final error = makeDioException(DioExceptionType.sendTimeout);
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.timeout);
    });
  });

  group('transformError - DioException connection/cancel types', () {
    test('connectionError maps to ApiErrorType.network', () {
      final error = makeDioException(DioExceptionType.connectionError);
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.network);
    });

    test('cancel maps to ApiErrorType.cancelled', () {
      final error = makeDioException(DioExceptionType.cancel);
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.cancelled);
    });

    test('badCertificate maps to ApiErrorType.security', () {
      final error = makeDioException(DioExceptionType.badCertificate);
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.security);
    });

    test('unknown DioExceptionType maps to ApiErrorType.unknown', () {
      final error = makeDioException(DioExceptionType.unknown);
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.unknown);
    });
  });

  group('transformError - HTTP status codes', () {
    test('401 maps to ApiErrorType.authentication', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 401,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.authentication);
      check(result.statusCode).equals(401);
    });

    test('403 maps to ApiErrorType.authorization', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 403,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.authorization);
    });

    test('404 maps to ApiErrorType.notFound', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 404,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.notFound);
    });

    test('422 maps to ApiErrorType.validation', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 422,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.validation);
    });

    test('429 maps to ApiErrorType.rateLimit', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 429,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.rateLimit);
    });

    test('500 maps to ApiErrorType.server', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 500,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.server);
    });

    test('502 maps to ApiErrorType.server', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 502,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.server);
    });

    test('503 maps to ApiErrorType.server', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 503,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.server);
    });

    test('400 maps to ApiErrorType.badRequest', () {
      final error = makeDioException(
        DioExceptionType.badResponse,
        statusCode: 400,
      );
      final result = handler.transformError(error);
      check(result.type).equals(ApiErrorType.badRequest);
    });
  });

  group('transformError - non-Dio exceptions', () {
    test('plain Exception maps to ApiErrorType.unknown', () {
      final result = handler.transformError(Exception('something broke'));
      check(result.type).equals(ApiErrorType.unknown);
    });

    test('string error maps to ApiErrorType.unknown', () {
      final result = handler.transformError('oops');
      check(result.type).equals(ApiErrorType.unknown);
    });

    test('passes through existing ApiError unchanged', () {
      const original = ApiError.notFound(message: 'not here', endpoint: '/foo');
      final result = handler.transformError(original);
      check(result.type).equals(ApiErrorType.notFound);
      check(result.message).equals('not here');
    });
  });

  group('transformError - preserves endpoint and method', () {
    test('uses provided endpoint and method', () {
      final error = makeDioException(DioExceptionType.connectionTimeout);
      final result = handler.transformError(
        error,
        endpoint: '/api/chat',
        method: 'POST',
      );
      check(result.endpoint).equals('/api/chat');
      check(result.method).equals('POST');
    });
  });

  group('isRetryable', () {
    test('network error is retryable', () {
      const error = ApiError.network(message: 'no connection');
      check(handler.isRetryable(error)).isTrue();
    });

    test('timeout error is retryable', () {
      const error = ApiError.timeout(message: 'timed out');
      check(handler.isRetryable(error)).isTrue();
    });

    test('server error is retryable', () {
      const error = ApiError.server(message: 'internal error', statusCode: 500);
      check(handler.isRetryable(error)).isTrue();
    });

    test('rateLimit error is retryable', () {
      const error = ApiError.rateLimit(message: 'too many');
      check(handler.isRetryable(error)).isTrue();
    });

    test('authentication error is not retryable', () {
      const error = ApiError.authentication(message: 'bad creds');
      check(handler.isRetryable(error)).isFalse();
    });

    test('authorization error is not retryable', () {
      const error = ApiError.authorization(message: 'forbidden');
      check(handler.isRetryable(error)).isFalse();
    });

    test('validation error is not retryable', () {
      const error = ApiError.validation(message: 'invalid');
      check(handler.isRetryable(error)).isFalse();
    });

    test('notFound error is not retryable', () {
      const error = ApiError.notFound(message: 'missing');
      check(handler.isRetryable(error)).isFalse();
    });

    test('cancelled error is not retryable', () {
      const error = ApiError.cancelled(message: 'cancelled');
      check(handler.isRetryable(error)).isFalse();
    });

    test('security error is not retryable', () {
      const error = ApiError.security(message: 'bad cert');
      check(handler.isRetryable(error)).isFalse();
    });

    test('unknown error is not retryable', () {
      const error = ApiError.unknown(message: 'unknown');
      check(handler.isRetryable(error)).isFalse();
    });
  });

  group('getRetryDelay', () {
    test('returns Duration for timeout errors', () {
      const error = ApiError.timeout(message: 'timed out');
      final delay = handler.getRetryDelay(error);
      check(delay).isNotNull();
      check(delay!.inSeconds).equals(5);
    });

    test('returns Duration for network errors', () {
      const error = ApiError.network(message: 'no net');
      final delay = handler.getRetryDelay(error);
      check(delay).isNotNull();
      check(delay!.inSeconds).equals(3);
    });

    test('returns Duration for server errors', () {
      const error = ApiError.server(message: 'down', statusCode: 500);
      final delay = handler.getRetryDelay(error);
      check(delay).isNotNull();
      check(delay!.inSeconds).equals(10);
    });

    test('returns retryAfter duration for rateLimit with retryAfter', () {
      const error = ApiError.rateLimit(
        message: 'rate limited',
        retryAfter: Duration(seconds: 30),
      );
      final delay = handler.getRetryDelay(error);
      check(delay).isNotNull();
      check(delay!.inSeconds).equals(30);
    });

    test('returns default 1 minute for rateLimit without retryAfter', () {
      const error = ApiError.rateLimit(message: 'rate limited');
      final delay = handler.getRetryDelay(error);
      check(delay).isNotNull();
      check(delay!.inMinutes).equals(1);
    });

    test('returns null for non-retryable errors', () {
      const error = ApiError.authentication(message: 'bad creds');
      final delay = handler.getRetryDelay(error);
      check(delay).isNull();
    });

    test('returns null for validation errors', () {
      const error = ApiError.validation(message: 'invalid input');
      final delay = handler.getRetryDelay(error);
      check(delay).isNull();
    });
  });

  group('getUserMessage', () {
    test('returns non-empty string for network error', () {
      const error = ApiError.network(message: 'Connection failed');
      final msg = handler.getUserMessage(error);
      check(msg).isNotEmpty();
      check(msg).contains('internet connection');
    });

    test('returns non-empty string for timeout error', () {
      const error = ApiError.timeout(message: 'Timed out');
      final msg = handler.getUserMessage(error);
      check(msg).isNotEmpty();
      check(msg).contains('slow connection');
    });

    test('returns non-empty string for authentication error', () {
      const error = ApiError.authentication(message: 'Unauthorized');
      final msg = handler.getUserMessage(error);
      check(msg).isNotEmpty();
      check(msg).contains('sign in');
    });

    test('returns non-empty string for authorization error', () {
      const error = ApiError.authorization(message: 'Forbidden');
      final msg = handler.getUserMessage(error);
      check(msg).isNotEmpty();
      check(msg).contains('support');
    });

    test('returns non-empty string for validation error', () {
      const error = ApiError.validation(message: 'Invalid data');
      final msg = handler.getUserMessage(error);
      check(msg).isNotEmpty();
      check(msg).contains('correct');
    });

    test('returns non-empty string for rateLimit error', () {
      const error = ApiError.rateLimit(message: 'Too many requests');
      final msg = handler.getUserMessage(error);
      check(msg).isNotEmpty();
      check(msg).contains('wait');
    });

    test('includes time info for rateLimit with retryAfter', () {
      const error = ApiError.rateLimit(
        message: 'Too many requests',
        retryAfter: Duration(seconds: 90),
      );
      final msg = handler.getUserMessage(error);
      check(msg).contains('1m');
      check(msg).contains('30s');
    });

    test('returns non-empty string for server error', () {
      const error = ApiError.server(
        message: 'Internal server error',
        statusCode: 500,
      );
      final msg = handler.getUserMessage(error);
      check(msg).isNotEmpty();
      check(msg).contains('servers');
    });

    test('returns base message for unknown error type', () {
      const error = ApiError.unknown(message: 'Something happened');
      final msg = handler.getUserMessage(error);
      check(msg).equals('Something happened');
    });
  });
}
