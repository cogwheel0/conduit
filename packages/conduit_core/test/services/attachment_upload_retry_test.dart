import 'dart:io';
import 'dart:math';

import 'package:conduit_core/services/attachment_upload_retry.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

DioException _dio(DioExceptionType type, {Object? error}) => DioException(
  requestOptions: RequestOptions(path: '/api/v1/files/'),
  type: type,
  error: error,
);

void main() {
  test('no connection waits for the network; a request that may have '
      'arrived is the user\'s to retry; a refusal is tried again', () {
    expect(
      classifyUploadFailure(_dio(DioExceptionType.connectionError)),
      UploadFailureKind.offline,
    );
    expect(
      classifyUploadFailure(
        _dio(DioExceptionType.unknown, error: const SocketException('down')),
      ),
      UploadFailureKind.offline,
    );
    expect(
      classifyUploadFailure(_dio(DioExceptionType.sendTimeout)),
      UploadFailureKind.indeterminate,
    );
    expect(
      classifyUploadFailure(const SocketException('reset')),
      UploadFailureKind.indeterminate,
    );
    expect(
      classifyUploadFailure(_dio(DioExceptionType.badResponse)),
      UploadFailureKind.retryable,
    );
    expect(classifyUploadFailure(StateError('x')), UploadFailureKind.retryable);
  });

  test('the wait doubles from five seconds up to five minutes', () {
    final none = _NoJitter();
    expect(uploadRetryDelay(1, random: none), const Duration(seconds: 5));
    expect(uploadRetryDelay(2, random: none), const Duration(seconds: 10));
    expect(uploadRetryDelay(3, random: none), const Duration(seconds: 20));
    expect(uploadRetryDelay(20, random: none), const Duration(minutes: 5));
    expect(kUploadMaxRetries, 4);
  });
}

class _NoJitter implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
