import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../utils/debug_logger.dart';

/// JWT token validation utilities
class TokenValidator {
  static const Duration _validationTimeout = Duration(seconds: 5);

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

  /// Validate token with server (async with timeout)
  static Future<TokenValidationResult> validateTokenWithServer(
    String token,
    Future<dynamic> Function() serverValidationCall,
  ) async {
    try {
      // First check format
      final formatResult = validateTokenFormat(token);
      if (!formatResult.isValid) {
        return formatResult;
      }

      // If format is good, try server validation with timeout
      final validationFuture = serverValidationCall();

      final result = await validationFuture.timeout(
        _validationTimeout,
        onTimeout: () => throw Exception('Token validation timeout'),
      );

      return TokenValidationResult.valid(
        'Server validation successful',
        serverData: result,
      );
    } catch (e) {
      if (e.toString().contains('timeout')) {
        return TokenValidationResult.networkError(
          'Validation timeout - using cached result',
        );
      } else if (e.toString().contains('401') || e.toString().contains('403')) {
        return TokenValidationResult.invalid('Server rejected token');
      } else {
        return TokenValidationResult.networkError(
          'Network error during validation',
        );
      }
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

  /// Extract user information from JWT token (if available)
  static Map<String, dynamic>? extractUserInfo(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 3) return null;

      final payload = _decodeJWTPayload(parts[1]);

      // Extract common user fields
      return {
        'sub': payload['sub'], // Subject (user ID)
        'username':
            payload['username'] ??
            payload['name'] ??
            payload['preferred_username'],
        'email': payload['email'],
        'roles': payload['roles'] ?? payload['groups'],
        'exp': payload['exp'],
        'iat': payload['iat'], // Issued at
      };
    } catch (e) {
      DebugLogger.warning(
        'token-user-info-failed',
        scope: 'auth/token-validator',
        data: {'errorType': e.runtimeType.toString()},
      );
      return null;
    }
  }

  /// Generate a cache key for token validation results
  static String generateCacheKey(String token) {
    final bytes = utf8.encode(token);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(
      0,
      16,
    ); // Use first 16 chars as cache key
  }
}

/// Result of token validation
class TokenValidationResult {
  const TokenValidationResult._(
    this.isValid,
    this.status,
    this.message, {
    this.expiryData,
    this.serverData,
  });

  const TokenValidationResult.valid(
    String message, {
    DateTime? expiryData,
    dynamic serverData,
  }) : this._(
         true,
         TokenValidationStatus.valid,
         message,
         expiryData: expiryData,
         serverData: serverData,
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

  const TokenValidationResult.networkError(String message)
    : this._(false, TokenValidationStatus.networkError, message);

  const TokenValidationResult.apiKeyNotSupported(String message)
    : this._(false, TokenValidationStatus.apiKeyNotSupported, message);

  final bool isValid;
  final TokenValidationStatus status;
  final String message;
  final DateTime? expiryData;
  final dynamic serverData;

  bool get isExpired => status == TokenValidationStatus.expired;
  bool get isExpiringSoon => status == TokenValidationStatus.expiringSoon;
  bool get hasNetworkError => status == TokenValidationStatus.networkError;
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
  networkError,
  apiKeyNotSupported,
}

/// Cache for token validation results
class TokenValidationCache {
  static final Map<String, _CacheEntry> _cache = {};
  static const Duration _cacheTimeout = Duration(minutes: 5);

  static void cacheResult(String token, TokenValidationResult result) {
    final key = TokenValidator.generateCacheKey(token);
    _cache[key] = _CacheEntry(result, DateTime.now());

    // Clean old entries
    _cleanCache();
  }

  static TokenValidationResult? getCachedResult(String token) {
    final key = TokenValidator.generateCacheKey(token);
    final entry = _cache[key];

    if (entry != null &&
        DateTime.now().difference(entry.timestamp) < _cacheTimeout) {
      return entry.result;
    }

    return null;
  }

  static void clearCache() {
    _cache.clear();
  }

  static void _cleanCache() {
    final now = DateTime.now();
    _cache.removeWhere(
      (key, entry) => now.difference(entry.timestamp) > _cacheTimeout,
    );
  }
}

class _CacheEntry {
  const _CacheEntry(this.result, this.timestamp);

  final TokenValidationResult result;
  final DateTime timestamp;
}
