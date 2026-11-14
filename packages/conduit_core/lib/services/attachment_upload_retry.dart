/// When an attachment upload that failed may be tried again, and how soon:
/// the rules [AttachmentUploadQueue] follows, shared with the desktop
/// daemon's `/upload`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

/// What an upload failure says about trying again.
enum UploadFailureKind {
  /// No connection was made, so no byte reached the server: wait for the
  /// network and try again, without spending the retry budget.
  offline,

  /// The request may have reached the server before it failed. Open WebUI
  /// gives every upload a new id and has no idempotency key, so another try
  /// could store the file twice: only the user may ask for it.
  indeterminate,

  /// The server answered and refused, or something else failed: tried
  /// again a few times ([kUploadMaxRetries]), with growing delays.
  retryable,
}

/// How many attempts a retryable failure gets in all.
const int kUploadMaxRetries = 4;

const Duration _baseRetryDelay = Duration(seconds: 5);
const Duration _maxRetryDelay = Duration(minutes: 5);

/// What [error] says about trying the upload again.
UploadFailureKind classifyUploadFailure(Object error) {
  if (_isSafeTransientTransportFailure(error)) return UploadFailureKind.offline;
  if (_isIndeterminateUploadFailure(error)) {
    return UploadFailureKind.indeterminate;
  }
  return UploadFailureKind.retryable;
}

/// How long to wait before attempt [retryCount] + 1: 5 s doubling to at most
/// 5 min, plus up to a second of jitter so many waiting uploads do not all
/// go at once.
Duration uploadRetryDelay(int retryCount, {Random? random}) {
  final base = _baseRetryDelay.inMilliseconds;
  final exp = min(
    base * pow(2, retryCount - 1),
    _maxRetryDelay.inMilliseconds.toDouble(),
  ).toInt();
  final jitter = (random ?? Random()).nextInt(1000);
  return Duration(milliseconds: exp + jitter);
}

bool _isSafeTransientTransportFailure(Object error) {
  if (error is! DioException) return false;
  // These failures surface before a connection to the server is established,
  // so no request byte can have reached the upload route and the server
  // cannot hold the file. They are pure connectivity outages: keep the row
  // pending and defer (without consuming the retry budget) so the upload
  // resumes when the network returns.
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.connectionError => true,
    DioExceptionType.unknown =>
      error.error is SocketException || error.error is HandshakeException,
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.transformTimeout ||
    DioExceptionType.badCertificate ||
    DioExceptionType.badResponse ||
    DioExceptionType.cancel => false,
  };
}

bool _isIndeterminateUploadFailure(Object error) {
  // Pre-connection connectivity failures are never indeterminate: bytes were
  // not sent, so the "server may already hold the file" rationale does not
  // apply. Classify them first so they take the safe deferral path.
  if (_isSafeTransientTransportFailure(error)) return false;
  if (_isTransientIoFailure(error)) return true;
  if (error is! DioException) return false;
  return switch (error.type) {
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.transformTimeout => true,
    DioExceptionType.unknown => _isTransientIoFailure(error.error),
    DioExceptionType.connectionTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.badCertificate ||
    DioExceptionType.badResponse ||
    DioExceptionType.cancel => false,
  };
}

bool _isTransientIoFailure(Object? error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is HandshakeException ||
    error is HttpException;
