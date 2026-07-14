import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/core/error/api_error.dart';
import 'package:conduit/core/error/api_error_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

const _signinPath = '/api/v1/auths/signin';
const _passwordSecret = 'password-secret-sentinel';
const _bearerSecret = 'bearer-secret-sentinel';
const _customHeaderSecret = 'custom-header-secret-sentinel';
const _responseSecret = 'response-secret-sentinel';
const _responseHeaderSecret = 'response-header-secret-sentinel';
const _fieldErrorSecret = 'field-error-secret-sentinel';
const _dioMessageSecret = 'dio-message-secret-sentinel';
const _querySecret = 'query-secret-sentinel';

void main() {
  test(
    'failed sign-in logs only value-free request and response metadata',
    () async {
      final dio = Dio();
      dio.httpClientAdapter = _ThrowingSigninAdapter(
        type: DioExceptionType.badResponse,
        statusCode: 422,
        message: _dioMessageSecret,
        responseData: const {
          'message': _responseSecret,
          'field_errors': {
            'password': [_fieldErrorSecret],
          },
        },
        responseHeaders: const {
          'x-reflected-error': [_responseHeaderSecret],
        },
      );
      dio.interceptors.add(ApiErrorInterceptor());

      final logs = await _captureDebugPrint(() async {
        await expectLater(
          dio.post<void>(
            '$_signinPath?reflected=$_querySecret',
            data: const {
              'email': 'user@example.com',
              'password': _passwordSecret,
            },
            options: Options(
              headers: const {
                'authorization': 'Bearer $_bearerSecret',
                'x-custom-auth': _customHeaderSecret,
              },
            ),
          ),
          throwsA(
            isA<DioException>().having(
              (error) => ApiErrorInterceptor.extractApiError(error)?.type,
              'api error type',
              ApiErrorType.validation,
            ),
          ),
        );
      });

      check(logs).contains('ERR[api/error-interceptor] api-error');
      check(logs).contains('method=POST');
      check(logs).contains('type=validation');
      check(logs).contains('status=422');
      check(logs).contains('originalType=badResponse');
      check(logs).contains('fieldErrorCount=1');

      for (final secret in const [
        _passwordSecret,
        _bearerSecret,
        _customHeaderSecret,
        _responseSecret,
        _responseHeaderSecret,
        _fieldErrorSecret,
        _dioMessageSecret,
        _querySecret,
      ]) {
        check(logs).not((value) => value.contains(secret));
      }
    },
  );

  test('unknown sign-in failure does not log its technical message', () async {
    final dio = Dio();
    dio.httpClientAdapter = _ThrowingSigninAdapter(
      type: DioExceptionType.unknown,
      statusCode: 503,
      message: _dioMessageSecret,
      responseData: const {'error': _responseSecret},
      responseHeaders: const {
        'x-reflected-error': [_responseHeaderSecret],
      },
    );
    dio.interceptors.add(ApiErrorInterceptor());

    final logs = await _captureDebugPrint(() async {
      await expectLater(
        dio.post<void>(
          '$_signinPath?reflected=$_querySecret',
          data: const {'password': _passwordSecret},
          options: Options(
            headers: const {
              'authorization': 'Bearer $_bearerSecret',
              'x-custom-auth': _customHeaderSecret,
            },
          ),
        ),
        throwsA(
          isA<DioException>().having(
            (error) => ApiErrorInterceptor.extractApiError(error)?.technical,
            'technical message is retained on the transformed error',
            _dioMessageSecret,
          ),
        ),
      );
    });

    check(logs).contains('method=POST');
    check(logs).contains('type=unknown');
    check(logs).contains('status=503');
    check(logs).contains('originalType=unknown');

    for (final secret in const [
      _passwordSecret,
      _bearerSecret,
      _customHeaderSecret,
      _responseSecret,
      _responseHeaderSecret,
      _dioMessageSecret,
      _querySecret,
    ]) {
      check(logs).not((value) => value.contains(secret));
    }
  });

  test('logErrors false emits no API diagnostics', () async {
    final dio = Dio();
    dio.httpClientAdapter = _ThrowingSigninAdapter(
      type: DioExceptionType.badResponse,
      statusCode: 422,
      message: _dioMessageSecret,
      responseData: const {'message': _responseSecret},
      responseHeaders: const {},
    );
    dio.interceptors.add(
      ApiErrorInterceptor(logErrors: false, throwApiErrors: true),
    );

    final logs = await _captureDebugPrint(() async {
      await expectLater(
        dio.post<void>(
          '$_signinPath/$_querySecret?reflected=$_querySecret',
          data: const {'password': _passwordSecret},
        ),
        throwsA(isA<DioException>()),
      );
    });

    check(logs).isEmpty();
  });

  test('logErrors false suppresses malformed validation diagnostics', () async {
    final dio = Dio();
    dio.httpClientAdapter = _ThrowingSigninAdapter(
      type: DioExceptionType.badResponse,
      statusCode: 422,
      message: _dioMessageSecret,
      responseData: const {
        'errors': [
          {'field': 123, 'message': _responseSecret},
        ],
      },
      responseHeaders: const {},
    );
    dio.interceptors.add(
      ApiErrorInterceptor(logErrors: false, throwApiErrors: true),
    );

    final logs = await _captureDebugPrint(() async {
      await expectLater(
        dio.post<void>(
          '$_signinPath/$_querySecret?reflected=$_querySecret',
          data: const {'password': _passwordSecret},
        ),
        throwsA(isA<DioException>()),
      );
    });

    check(logs).isEmpty();
  });
}

Future<String> _captureDebugPrint(Future<void> Function() body) async {
  final previousDebugPrint = debugPrint;
  final output = <String>[];
  debugPrint = (message, {wrapWidth}) {
    if (message != null) output.add(message);
  };

  try {
    await body();
  } finally {
    debugPrint = previousDebugPrint;
  }

  return output.join('\n');
}

final class _ThrowingSigninAdapter implements HttpClientAdapter {
  const _ThrowingSigninAdapter({
    required this.type,
    required this.statusCode,
    required this.message,
    required this.responseData,
    required this.responseHeaders,
  });

  final DioExceptionType type;
  final int statusCode;
  final String message;
  final Object responseData;
  final Map<String, List<String>> responseHeaders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      response: Response<Object>(
        requestOptions: options,
        statusCode: statusCode,
        data: responseData,
        headers: Headers.fromMap(responseHeaders),
      ),
      type: type,
      message: message,
    );
  }

  @override
  void close({bool force = false}) {}
}
