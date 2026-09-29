import 'dart:convert';

import 'package:conduit_core/utils/debug_logger.dart';

/// JWT token validation utilities
class TokenValidator {
  /// Check if token is an API key format (sk-, api-, key-)
  /// API keys are not supported for streaming.
  static bool isApiKey(String token) {
    return token.startsWith('sk-') ||
        token.startsWith('api-') ||
        token.startsWith('key-');
  }

  /// Validate token format (JWT tokens only - API keys not supported)
  static TokenValidationResult validateTokenFormat(String token) {
    try {
      // Basic format check
      if (token.isEmpty || token.length < 10) {
        return TokenValidationResult.invalid('Token too short');
      }

      // Reject API keys - they don't support streaming
      if (isApiKey(token)) {
        return TokenValidationResult.apiKeyNotSupported(
          'API keys are not supported. Please use a JWT token.',
        );
      }

      // Check if it looks like a JWT (has at least 2 dots)
      final parts = token.split('.');
      if (parts.length < 3) {
        // Not JWT format, treat as opaque token
        return TokenValidationResult.valid('Opaque token format valid');
      }

      // Try to decode the payload to check expiry
      try {
        final payload = _decodeJWTPayload(parts[1]);
        final exp = payload['exp'] as int?;

        if (exp != null) {
          final expiryTime = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
          final now = DateTime.now();

          if (expiryTime.isBefore(now)) {
            return TokenValidationResult.expired('Token expired');
          }

          // Check if token expires soon (within 5 minutes)
          final fiveMinutesFromNow = now.add(const Duration(minutes: 5));
          if (expiryTime.isBefore(fiveMinutesFromNow)) {
            return TokenValidationResult.expiringSoon(
              'Token expires soon',
              expiryTime,
            );
          }
        }

        return TokenValidationResult.valid(
          'Token format valid',
          expiryData: exp != null
              ? DateTime.fromMillisecondsSinceEpoch(exp * 1000)
              : null,
        );
      } catch (e) {
        // If we can't decode JWT, treat as opaque token
        DebugLogger.warning(
          'jwt-decode-failed',
          scope: 'auth/token-validator',
          data: {'errorType': e.runtimeType.toString()},
        );
        return TokenValidationResult.valid('Opaque token format valid');
      }
    } catch (_) {
      return TokenValidationResult.invalid('Token validation failed');
    }
  }

  /// Decode JWT payload (without signature verification)
  static Map<String, dynamic> _decodeJWTPayload(String base64Payload) {
    // Add padding if needed
    String padded = base64Payload;
    while (padded.length % 4 != 0) {
      padded += '=';
    }

    // Decode base64
    final decoded = base64Url.decode(padded);
    final jsonString = utf8.decode(decoded);

    return jsonDecode(jsonString) as Map<String, dynamic>;
  }
}

/// Result of token validation
class TokenValidationResult {
  const TokenValidationResult._(
    this.isValid,
    this.status,
    this.message, {
    this.expiryData,
  });

  const TokenValidationResult.valid(String message, {DateTime? expiryData})
    : this._(
        true,
        TokenValidationStatus.valid,
        message,
        expiryData: expiryData,
      );

  const TokenValidationResult.invalid(String message)
    : this._(false, TokenValidationStatus.invalid, message);

  const TokenValidationResult.expired(String message)
    : this._(false, TokenValidationStatus.expired, message);

  const TokenValidationResult.expiringSoon(String message, DateTime expiryTime)
    : this._(
        true,
        TokenValidationStatus.expiringSoon,
        message,
        expiryData: expiryTime,
      );

  const TokenValidationResult.apiKeyNotSupported(String message)
    : this._(false, TokenValidationStatus.apiKeyNotSupported, message);

  final bool isValid;
  final TokenValidationStatus status;
  final String message;
  final DateTime? expiryData;

  bool get isExpired => status == TokenValidationStatus.expired;
  bool get isExpiringSoon => status == TokenValidationStatus.expiringSoon;
  bool get isApiKeyNotSupported =>
      status == TokenValidationStatus.apiKeyNotSupported;

  @override
  String toString() =>
      'TokenValidationResult(isValid: $isValid, status: $status, message: $message)';
}

enum TokenValidationStatus {
  valid,
  invalid,
  expired,
  expiringSoon,
  apiKeyNotSupported,
}
