import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/direct_completion.dart';

Stream<List<int>> directResponseBytes(ResponseBody body) =>
    body.stream.cast<List<int>>();

const Duration kDirectStreamIdleTimeout = Duration(minutes: 5);
const int kMaxDirectStreamCharacters = 8 * 1024 * 1024;

Stream<List<int>> directStreamingResponseBytes(
  ResponseBody body, {
  Duration idleTimeout = kDirectStreamIdleTimeout,
}) {
  if (idleTimeout <= Duration.zero) {
    throw ArgumentError.value(idleTimeout, 'idleTimeout');
  }
  return directResponseBytes(body).timeout(idleTimeout);
}

/// Bounds the aggregate text and reasoning emitted by one provider run. Frame
/// limits alone are insufficient because a peer can send an endless sequence
/// of individually valid frames.
final class DirectStreamBudget {
  DirectStreamBudget({this.maxCharacters = kMaxDirectStreamCharacters}) {
    if (maxCharacters <= 0) {
      throw ArgumentError.value(maxCharacters, 'maxCharacters');
    }
  }

  final int maxCharacters;
  int _characters = 0;

  void add(String value) {
    _characters += value.length;
    if (_characters > maxCharacters) {
      throw const DirectProviderException(
        'The provider response exceeded Conduit\'s size limit.',
      );
    }
  }
}

const int kMaxDirectJsonResponseBytes = 10 * 1024 * 1024;

Future<Object?> decodeDirectJsonValue(
  ResponseBody body, {
  int maxBytes = kMaxDirectJsonResponseBytes,
}) async {
  if (maxBytes <= 0) throw RangeError.value(maxBytes, 'maxBytes');
  final bytes = <int>[];
  await for (final chunk in directResponseBytes(body)) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('Provider response is too large.');
    }
    bytes.addAll(chunk);
  }
  return jsonDecode(utf8.decode(bytes));
}

Future<Map<String, dynamic>> decodeDirectJsonBody(
  ResponseBody body, {
  int maxBytes = kMaxDirectJsonResponseBytes,
}) async {
  final decoded = await decodeDirectJsonValue(body, maxBytes: maxBytes);
  if (decoded is! Map) {
    throw const FormatException('Provider response must be a JSON object.');
  }
  return decoded.cast<String, dynamic>();
}

DirectProviderException normalizeDirectProviderError(Object error) {
  if (error is DirectProviderException) return error;
  if (error is TimeoutException) {
    return DirectProviderException(
      'The provider stream timed out while waiting for data.',
      cause: error,
    );
  }
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null) {
      return DirectProviderException(
        'The provider returned HTTP $status.',
        statusCode: status,
        cause: error,
      );
    }
    return DirectProviderException(switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'The provider request timed out.',
      DioExceptionType.cancel => 'The provider request was cancelled.',
      _ => 'Could not connect to the provider.',
    }, cause: error);
  }
  if (error is FormatException) {
    return DirectProviderException(
      'The provider returned an invalid response.',
      cause: error,
    );
  }
  return DirectProviderException('The provider request failed.', cause: error);
}

String directErrorMessage(Object? raw) {
  var current = raw;
  final visited = <Object>{};
  for (var depth = 0; depth < 8; depth++) {
    if (current is String && current.trim().isNotEmpty) {
      return current.trim();
    }
    if (current is! Map || !visited.add(current)) break;
    final nested = current['message'] ?? current['detail'] ?? current['error'];
    if (nested == null || identical(nested, current)) break;
    current = nested;
  }
  return 'The provider reported an error.';
}
