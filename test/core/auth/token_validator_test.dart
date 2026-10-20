import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/token_validator.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

/// Creates a fake JWT with the given payload for testing.
String fakeJwt(Map<String, dynamic> payload) {
  final header = base64Url
      .encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'))
      .replaceAll('=', '');
  final body = base64Url
      .encode(utf8.encode(json.encode(payload)))
      .replaceAll('=', '');
  return '$header.$body.fakesignature';
}

/// Returns a Unix timestamp (seconds) for a time relative to now.
int unixSeconds(Duration offset) {
  final dt = DateTime.now().add(offset);
  return dt.millisecondsSinceEpoch ~/ 1000;
}

void main() {
  group('TokenValidator.isApiKey', () {
    test('returns true for sk- prefix', () {
      check(TokenValidator.isApiKey('sk-abc123')).isTrue();
    });

    test('returns true for api- prefix', () {
      check(TokenValidator.isApiKey('api-xyz789')).isTrue();
    });

    test('returns true for key- prefix', () {
      check(TokenValidator.isApiKey('key-hello')).isTrue();
    });

    test('returns false for normal JWT', () {
      final jwt = fakeJwt({'sub': '1'});
      check(TokenValidator.isApiKey(jwt)).isFalse();
    });

    test('returns false for arbitrary string', () {
      check(TokenValidator.isApiKey('some-random-token')).isFalse();
    });

    test('returns false for empty string', () {
      check(TokenValidator.isApiKey('')).isFalse();
    });
  });

  group('TokenValidator.validateTokenFormat', () {
    test('malformed token diagnostics never include token material', () {
      const secret = 'malformed-token-secret-sentinel';
      const token = 'header.$secret%.signature';
      final previousDebugPrint = debugPrint;
      final logs = StringBuffer();
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.writeln(message);
      };

      try {
        final result = TokenValidator.validateTokenFormat(token);
        check(result.isValid).isTrue();
      } finally {
        debugPrint = previousDebugPrint;
      }

      check(logs.toString()).contains('jwt-decode-failed');
      check(logs.toString()).not((value) => value.contains(secret));
    });

    test('returns invalid for empty token', () {
      final result = TokenValidator.validateTokenFormat('');
      check(result.isValid).isFalse();
      check(result.status).equals(TokenValidationStatus.invalid);
    });

    test('returns invalid for token shorter than 10 characters', () {
      final result = TokenValidator.validateTokenFormat('short');
      check(result.isValid).isFalse();
      check(result.status).equals(TokenValidationStatus.invalid);
    });

    test('returns apiKeyNotSupported for sk- prefix', () {
      final result = TokenValidator.validateTokenFormat(
        'sk-longenoughtoken123',
      );
      check(result.isValid).isFalse();
      check(result.status).equals(TokenValidationStatus.apiKeyNotSupported);
      check(result.isApiKeyNotSupported).isTrue();
    });

    test('returns apiKeyNotSupported for api- prefix', () {
      final result = TokenValidator.validateTokenFormat('api-longenoughtoken');
      check(result.isValid).isFalse();
      check(result.isApiKeyNotSupported).isTrue();
    });

    test('returns apiKeyNotSupported for key- prefix', () {
      final result = TokenValidator.validateTokenFormat('key-longenoughtoken');
      check(result.isValid).isFalse();
      check(result.isApiKeyNotSupported).isTrue();
    });

    test('returns valid for opaque token without dots', () {
      final result = TokenValidator.validateTokenFormat(
        'some-opaque-token-no-dots-long-enough',
      );
      check(result.isValid).isTrue();
      check(result.status).equals(TokenValidationStatus.valid);
    });

    test('returns valid for JWT with future expiry', () {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(hours: 1)),
      });
      final result = TokenValidator.validateTokenFormat(jwt);
      check(result.isValid).isTrue();
      check(result.status).equals(TokenValidationStatus.valid);
      check(result.expiryData).isNotNull();
    });

    test('returns expired for JWT with past expiry', () {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(hours: -1)),
      });
      final result = TokenValidator.validateTokenFormat(jwt);
      check(result.isValid).isFalse();
      check(result.isExpired).isTrue();
      check(result.status).equals(TokenValidationStatus.expired);
    });

    test('returns expiringSoon for JWT expiring within 5 minutes', () {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(minutes: 2)),
      });
      final result = TokenValidator.validateTokenFormat(jwt);
      check(result.isValid).isTrue();
      check(result.isExpiringSoon).isTrue();
      check(result.status).equals(TokenValidationStatus.expiringSoon);
      check(result.expiryData).isNotNull();
    });

    test('returns valid for JWT without exp claim', () {
      final jwt = fakeJwt({'sub': 'user1'});
      final result = TokenValidator.validateTokenFormat(jwt);
      check(result.isValid).isTrue();
      check(result.expiryData).isNull();
    });

    test('returns valid for JWT with exp far in the future', () {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(days: 365)),
      });
      final result = TokenValidator.validateTokenFormat(jwt);
      check(result.isValid).isTrue();
      check(result.isExpiringSoon).isFalse();
    });
  });
}
