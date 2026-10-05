import 'package:checks/checks.dart';
import 'package:conduit_core/error/api_error.dart';
import 'package:conduit_core/error/api_error_interceptor.dart';
import 'package:conduit_core/error/error_recovery_policy.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

DioException _dio(
  DioExceptionType type, {
  int? statusCode,
  Object? error,
  String? message,
}) {
  final options = RequestOptions(path: '/test');
  return DioException(
    type: type,
    requestOptions: options,
    message: message,
    error: error,
    response: statusCode == null
        ? null
        : Response(requestOptions: options, statusCode: statusCode),
  );
}

ApiError _api(ApiErrorType type, {Duration? retryAfter, String? technical}) {
  switch (type) {
    case ApiErrorType.network:
      return ApiError.network(technical: technical);
    case ApiErrorType.timeout:
      return const ApiError.timeout();
    case ApiErrorType.authentication:
      return const ApiError.authentication();
    case ApiErrorType.authorization:
      return const ApiError.authorization();
    case ApiErrorType.validation:
      return const ApiError.validation();
    case ApiErrorType.badRequest:
      return const ApiError.badRequest();
    case ApiErrorType.notFound:
      return const ApiError.notFound();
    case ApiErrorType.server:
      return const ApiError.server();
    case ApiErrorType.rateLimit:
      return ApiError.rateLimit(retryAfter: retryAfter);
    case ApiErrorType.cancelled:
      return const ApiError.cancelled();
    case ApiErrorType.security:
      return const ApiError.security();
    case ApiErrorType.unknown:
      return ApiError.unknown(technical: technical);
  }
}

void main() {
  final policy = ErrorRecoveryPolicy();

  group('apiErrorOf', () {
    test('returns an ApiError as is', () {
      final error = _api(ApiErrorType.server);
      check(policy.apiErrorOf(error)).identicalTo(error);
    });

    test('returns the ApiError the interceptor attached to a DioException', () {
      final inner = _api(ApiErrorType.timeout);
      final dio = _dio(DioExceptionType.unknown, error: inner);
      check(ApiErrorInterceptor.extractApiError(dio)).isNotNull();
      check(policy.apiErrorOf(dio)).identicalTo(inner);
    });

    test('is null for a bare DioException and other objects', () {
      check(policy.apiErrorOf(_dio(DioExceptionType.cancel))).isNull();
      check(policy.apiErrorOf(StateError('x'))).isNull();
    });
  });

  group('isRetryable and retryDelay', () {
    test('an ApiError follows the ApiErrorHandler', () {
      check(policy.isRetryable(_api(ApiErrorType.server))).isTrue();
      check(policy.isRetryable(_api(ApiErrorType.notFound))).isFalse();
      check(policy.retryDelay(_api(ApiErrorType.network)))
          .equals(const Duration(seconds: 3));
      check(policy.retryDelay(_api(ApiErrorType.notFound))).isNull();
      check(
        policy.retryDelay(
          _api(ApiErrorType.rateLimit, retryAfter: const Duration(seconds: 42)),
        ),
      ).equals(const Duration(seconds: 42));
    });

    test('an ApiError inside a DioException wins over the Dio type', () {
      final dio = _dio(
        DioExceptionType.connectionTimeout,
        error: _api(ApiErrorType.authentication),
      );
      check(policy.isRetryable(dio)).isFalse();
      check(policy.retryDelay(dio)).isNull();
    });

    test('bare DioException types', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        check(policy.isRetryable(_dio(type))).isTrue();
      }
      check(policy.isRetryable(_dio(DioExceptionType.cancel))).isFalse();
      check(policy.isRetryable(_dio(DioExceptionType.badCertificate)))
          .isFalse();
      check(
        policy.isRetryable(_dio(DioExceptionType.badResponse, statusCode: 503)),
      ).isTrue();
      check(
        policy.isRetryable(_dio(DioExceptionType.badResponse, statusCode: 404)),
      ).isFalse();
      check(policy.isRetryable(_dio(DioExceptionType.badResponse))).isFalse();
    });

    test('bare DioException delays', () {
      check(policy.retryDelay(_dio(DioExceptionType.connectionTimeout)))
          .equals(const Duration(seconds: 5));
      check(policy.retryDelay(_dio(DioExceptionType.receiveTimeout)))
          .equals(const Duration(seconds: 5));
      check(policy.retryDelay(_dio(DioExceptionType.connectionError)))
          .equals(const Duration(seconds: 3));
      check(
        policy.retryDelay(_dio(DioExceptionType.badResponse, statusCode: 500)),
      ).equals(const Duration(seconds: 10));
      check(
        policy.retryDelay(_dio(DioExceptionType.badResponse, statusCode: 400)),
      ).isNull();
      check(policy.retryDelay(_dio(DioExceptionType.cancel))).isNull();
    });

    test('anything else is not retryable', () {
      check(policy.isRetryable(Exception('x'))).isFalse();
      check(policy.retryDelay('x')).isNull();
    });
  });

  group('messages', () {
    test('Dio fallback text by type and status', () {
      check(policy.dioFallbackMessage(_dio(DioExceptionType.sendTimeout)))
          .equals('Connection timeout - please check your internet connection');
      check(policy.dioFallbackMessage(_dio(DioExceptionType.connectionError)))
          .equals(
            'Network connection error - please check your internet connection',
          );
      String bad(int? status) => policy.dioFallbackMessage(
        _dio(DioExceptionType.badResponse, statusCode: status),
      );
      check(bad(401)).equals('Authentication failed - please sign in again');
      check(bad(403))
          .equals('Access denied - you don\'t have permission for this action');
      check(bad(404)).equals('The requested resource was not found');
      check(bad(502)).equals('Server error occurred - please try again later');
      check(bad(418)).equals('An error occurred with your request');
      check(bad(null)).equals('An error occurred with your request');
      check(policy.dioFallbackMessage(_dio(DioExceptionType.cancel)))
          .equals('Request was cancelled');
      check(
        policy.dioFallbackMessage(_dio(DioExceptionType.badCertificate)),
      ).equals('Security certificate error - unable to verify server identity');
      check(policy.dioFallbackMessage(_dio(DioExceptionType.unknown)))
          .equals('An unexpected error occurred - please try again');
    });

    test('generic text never repeats the exception text', () {
      check(policy.genericMessage(Exception('boom')))
          .equals('An unexpected error occurred');
      check(policy.genericMessage('boom'))
          .equals('An unexpected error occurred');
      check(policy.technicalDetails(Exception('boom')))
          .equals('Exception: boom');
    });
  });

  group('technicalDetails', () {
    test('an ApiError prefers its technical text', () {
      check(
        policy.technicalDetails(_api(ApiErrorType.unknown, technical: 'tech')),
      ).equals('tech');
      check(policy.technicalDetails(_api(ApiErrorType.server)))
          .equals(_api(ApiErrorType.server).toString());
    });

    test('a DioException without an ApiError shows type and message', () {
      check(
        policy.technicalDetails(
          _dio(DioExceptionType.connectionError, message: 'refused'),
        ),
      ).equals('DioExceptionType.connectionError: refused');
    });

    test('other objects show toString', () {
      check(policy.technicalDetails(42)).equals('42');
    });
  });

  group('title and snackbarDuration', () {
    test('titles by ApiErrorType', () {
      final titles = {
        ApiErrorType.network: 'Connection Problem',
        ApiErrorType.timeout: 'Request Timeout',
        ApiErrorType.authentication: 'Authentication Required',
        ApiErrorType.authorization: 'Access Denied',
        ApiErrorType.validation: 'Invalid Input',
        ApiErrorType.badRequest: 'Bad Request',
        ApiErrorType.notFound: 'Not Found',
        ApiErrorType.server: 'Server Error',
        ApiErrorType.rateLimit: 'Rate Limited',
        ApiErrorType.cancelled: 'Request Cancelled',
        ApiErrorType.security: 'Security Error',
        ApiErrorType.unknown: 'Unknown Error',
      };
      for (final MapEntry(:key, :value) in titles.entries) {
        check(policy.title(_api(key))).equals(value);
      }
      check(policy.title('x')).equals('Error');
    });

    test('validation and rate-limit errors stay up longer', () {
      check(policy.snackbarDuration(_api(ApiErrorType.validation)))
          .equals(const Duration(seconds: 6));
      check(policy.snackbarDuration(_api(ApiErrorType.badRequest)))
          .equals(const Duration(seconds: 6));
      check(policy.snackbarDuration(_api(ApiErrorType.rateLimit)))
          .equals(const Duration(seconds: 8));
      check(policy.snackbarDuration(_api(ApiErrorType.server)))
          .equals(const Duration(seconds: 4));
      check(policy.snackbarDuration('x')).equals(const Duration(seconds: 4));
    });
  });
}
