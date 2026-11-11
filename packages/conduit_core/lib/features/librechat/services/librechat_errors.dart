import 'dart:convert';

import 'package:dio/dio.dart';

/// A LibreChat request the server refused or could not serve.
class LibreChatApiException implements Exception {
  const LibreChatApiException({
    required this.message,
    this.statusCode,
    this.code,
  });

  /// What the server said, else a short description of what failed.
  final String message;
  final int? statusCode;

  /// The machine-readable code some refusals carry, e.g. `PARENT_NOT_READY`.
  final String? code;

  /// Reads what a failed [response] said: LibreChat answers with
  /// `{message}`, `{error}` or plain text depending on the route.
  static LibreChatApiException fromResponse(
    Response<dynamic>? response, {
    String fallback = 'The LibreChat server refused the request.',
  }) {
    final status = response?.statusCode;
    final body = _decode(response?.data);
    String? message;
    String? code;
    if (body is Map) {
      final rawMessage = body['message'] ?? body['error'];
      if (rawMessage is String && rawMessage.trim().isNotEmpty) {
        message = rawMessage.trim();
      } else if (rawMessage is Map && rawMessage['message'] is String) {
        message = rawMessage['message'] as String;
      }
      final rawCode = body['code'] ?? body['type'];
      if (rawCode is String && rawCode.isNotEmpty) code = rawCode;
    } else if (body is String && body.trim().isNotEmpty && body.length < 300) {
      message = body.trim();
    }
    message ??= fallback;
    if (status == 403 && message == bannedMessage) {
      return LibreChatBannedException(message: message);
    }
    return LibreChatApiException(
      message: message,
      statusCode: status,
      code: code,
    );
  }

  /// `checkBan`'s answer to a banned user or address.
  static const String bannedMessage =
      'Your account has been temporarily banned due to violations of our '
      'service.';

  static Object? _decode(Object? data) {
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return jsonDecode(trimmed);
        } on FormatException {
          return data;
        }
      }
    }
    return data;
  }

  @override
  String toString() {
    final codeText = code == null ? '' : ' $code';
    return 'LibreChatApiException(${statusCode ?? '-'}$codeText): $message';
  }
}

/// The session ended: its refresh cookie is missing, expired or revoked, so
/// only signing in again helps.
final class LibreChatSessionExpiredException extends LibreChatApiException {
  const LibreChatSessionExpiredException({
    super.message = 'The LibreChat session has ended. Sign in again.',
    super.statusCode,
  });
}

/// The server banned this user or address for repeated violations.
final class LibreChatBannedException extends LibreChatApiException {
  const LibreChatBannedException({
    super.message = LibreChatApiException.bannedMessage,
  }) : super(statusCode: 403);
}

/// The server took the request's User-Agent for a non-browser client and
/// refused it, scoring a violation towards a ban. It means a request left
/// without [LibreChatUserAgent]'s header, which is a bug in Conduit.
final class LibreChatIllegalRequestException extends LibreChatApiException {
  const LibreChatIllegalRequestException()
    : super(message: 'The LibreChat server refused this app as a client.');

  /// Whether [data], a 200 body, is `uaParser`'s refusal: an SSE error frame
  /// saying "Illegal request".
  ///
  /// The refusal is one short frame, so a longer body, or one that does not
  /// start with that frame, is a real response and is never scanned whole.
  static bool matches(Object? data) {
    const maxLength = 256;
    final String text;
    if (data is String) {
      if (data.length > maxLength) return false;
      text = data;
    } else if (data is List<int>) {
      if (data.length > maxLength) return false;
      text = utf8.decode(data, allowMalformed: true);
    } else {
      return false;
    }
    final trimmed = text.trimLeft();
    return trimmed.startsWith('event: error') &&
        trimmed.contains('Illegal request');
  }
}
