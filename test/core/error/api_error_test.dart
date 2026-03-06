import 'package:checks/checks.dart';
import 'package:conduit/core/error/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Factory constructors', () {
    test('network sets type and isRetryable', () {
      const error = ApiError.network(message: 'No internet');
      check(error.type).equals(ApiErrorType.network);
      check(error.isRetryable).isTrue();
    });

    test('timeout sets isRetryable and timeoutDuration', () {
      const error = ApiError.timeout(
        message: 'Timed out',
        timeoutDuration: Duration(seconds: 30),
      );
      check(error.type).equals(ApiErrorType.timeout);
      check(error.isRetryable).isTrue();
      check(error.timeoutDuration).isNotNull().equals(
        const Duration(seconds: 30),
      );
    });

    test('authentication is not retryable', () {
      const error = ApiError.authentication(message: 'Invalid token');
      check(error.type).equals(ApiErrorType.authentication);
      check(error.isRetryable).isFalse();
    });

    test('validation has statusCode 422 and supports fieldErrors', () {
      const error = ApiError.validation(
        message: 'Invalid',
        fieldErrors: {
          'email': ['required'],
        },
      );
      check(error.type).equals(ApiErrorType.validation);
      check(error.statusCode).equals(422);
      check(error.hasFieldErrors).isTrue();
      check(error.firstFieldError).isNotNull().equals('email: required');
    });

    test('rateLimit has retryAfter and isRetryable', () {
      const error = ApiError.rateLimit(
        message: 'Too many requests',
        retryAfter: Duration(seconds: 60),
      );
      check(error.type).equals(ApiErrorType.rateLimit);
      check(error.isRetryable).isTrue();
      check(error.retryAfter).isNotNull().equals(
        const Duration(seconds: 60),
      );
    });

    test('server is retryable', () {
      const error = ApiError.server(message: 'Internal error');
      check(error.type).equals(ApiErrorType.server);
      check(error.isRetryable).isTrue();
    });

    test('notFound has statusCode 404 and is not retryable', () {
      const error = ApiError.notFound(message: 'Not found');
      check(error.type).equals(ApiErrorType.notFound);
      check(error.statusCode).equals(404);
      check(error.isRetryable).isFalse();
    });

    test('cancelled sets type', () {
      const error = ApiError.cancelled(message: 'Cancelled');
      check(error.type).equals(ApiErrorType.cancelled);
      check(error.isRetryable).isFalse();
    });

    test('badRequest sets statusCode 400', () {
      const error = ApiError.badRequest(message: 'Bad request');
      check(error.type).equals(ApiErrorType.badRequest);
      check(error.statusCode).equals(400);
      check(error.isRetryable).isFalse();
    });

    test('security sets type', () {
      const error = ApiError.security(message: 'Certificate error');
      check(error.type).equals(ApiErrorType.security);
      check(error.isRetryable).isFalse();
    });

    test('unknown sets type and preserves originalError', () {
      const error = ApiError.unknown(
        message: 'Something went wrong',
        originalError: 'raw error',
      );
      check(error.type).equals(ApiErrorType.unknown);
      check(error.isRetryable).isFalse();
    });
  });

  group('Field errors', () {
    test('allFieldErrorMessages flattens all entries', () {
      const error = ApiError.validation(
        message: 'Invalid',
        fieldErrors: {
          'email': ['required', 'invalid format'],
          'name': ['too short'],
        },
      );
      check(error.allFieldErrorMessages).deepEquals([
        'email: required',
        'email: invalid format',
        'name: too short',
      ]);
    });

    test('firstFieldError returns null when empty', () {
      const error = ApiError.validation(message: 'Invalid');
      check(error.firstFieldError).isNull();
    });
  });

  group('Equality', () {
    test('same fields are equal', () {
      const a = ApiError.network(
        message: 'fail',
        endpoint: '/api',
      );
      const b = ApiError.network(
        message: 'fail',
        endpoint: '/api',
      );
      check(a).equals(b);
      check(a.hashCode).equals(b.hashCode);
    });

    test('different message makes not equal', () {
      const a = ApiError.network(message: 'fail');
      const b = ApiError.network(message: 'other');
      check(a).not((it) => it.equals(b));
    });
  });

  group('toMap', () {
    test('includes all fields', () {
      const error = ApiError.rateLimit(
        message: 'Rate limited',
        endpoint: '/api',
        method: 'GET',
        retryAfter: Duration(seconds: 10),
      );
      final map = error.toMap();
      check(map['type']).equals('rateLimit');
      check(map['message']).equals('Rate limited');
      check(map['endpoint']).equals('/api');
      check(map['method']).equals('GET');
      check(map['retryAfter']).equals(10);
      check(map['isRetryable']).equals(true);
      check(map['hasFieldErrors']).equals(false);
    });
  });

  group('ParsedErrorResponse', () {
    test('hasFieldErrors returns true when field errors exist', () {
      const response = ParsedErrorResponse(
        fieldErrors: {
          'email': ['required'],
        },
      );
      check(response.hasFieldErrors).isTrue();
    });

    test('hasGeneralErrors returns true when errors exist', () {
      const response = ParsedErrorResponse(
        errors: ['Something failed'],
      );
      check(response.hasGeneralErrors).isTrue();
    });

    test('defaults have no errors', () {
      const response = ParsedErrorResponse();
      check(response.hasFieldErrors).isFalse();
      check(response.hasGeneralErrors).isFalse();
    });
  });
}
