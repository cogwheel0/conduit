import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:qonduit/core/auth/token_validator.dart';
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
      final result =
          TokenValidator.validateTokenFormat('sk-longenoughtoken123');
      check(result.isValid).isFalse();
      check(result.status)
          .equals(TokenValidationStatus.apiKeyNotSupported);
      check(result.isApiKeyNotSupported).isTrue();
    });

    test('returns apiKeyNotSupported for api- prefix', () {
      final result =
          TokenValidator.validateTokenFormat('api-longenoughtoken');
      check(result.isValid).isFalse();
      check(result.isApiKeyNotSupported).isTrue();
    });

    test('returns apiKeyNotSupported for key- prefix', () {
      final result =
          TokenValidator.validateTokenFormat('key-longenoughtoken');
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
      check(result.status)
          .equals(TokenValidationStatus.expiringSoon);
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

  group('TokenValidator.extractUserInfo', () {
    test('extracts sub, username, email, and exp', () {
      final jwt = fakeJwt({
        'sub': 'user-42',
        'username': 'jdoe',
        'email': 'jdoe@example.com',
        'exp': 1700000000,
        'iat': 1699990000,
      });
      final info = TokenValidator.extractUserInfo(jwt);
      check(info).isNotNull();
      check(info!['sub']).equals('user-42');
      check(info['username']).equals('jdoe');
      check(info['email']).equals('jdoe@example.com');
      check(info['exp']).equals(1700000000);
      check(info['iat']).equals(1699990000);
    });

    test('falls back to name for username', () {
      final jwt = fakeJwt({
        'sub': 'user-1',
        'name': 'Jane Doe',
      });
      final info = TokenValidator.extractUserInfo(jwt);
      check(info).isNotNull();
      check(info!['username']).equals('Jane Doe');
    });

    test('falls back to preferred_username for username', () {
      final jwt = fakeJwt({
        'sub': 'user-2',
        'preferred_username': 'janedoe',
      });
      final info = TokenValidator.extractUserInfo(jwt);
      check(info).isNotNull();
      check(info!['username']).equals('janedoe');
    });

    test('extracts roles from roles field', () {
      final jwt = fakeJwt({
        'sub': 'user-3',
        'roles': ['admin', 'editor'],
      });
      final info = TokenValidator.extractUserInfo(jwt);
      check(info).isNotNull();
      check(info!['roles'] as List).deepEquals(['admin', 'editor']);
    });

    test('extracts roles from groups field', () {
      final jwt = fakeJwt({
        'sub': 'user-4',
        'groups': ['staff'],
      });
      final info = TokenValidator.extractUserInfo(jwt);
      check(info).isNotNull();
      check(info!['roles'] as List).deepEquals(['staff']);
    });

    test('returns null for non-JWT token', () {
      final info = TokenValidator.extractUserInfo('not-a-jwt');
      check(info).isNull();
    });

    test('returns null for token with only 2 parts', () {
      final info = TokenValidator.extractUserInfo('part1.part2');
      check(info).isNull();
    });

    test('returns null for token with invalid base64 payload', () {
      final info =
          TokenValidator.extractUserInfo('header.!!!invalid!!!.sig');
      check(info).isNull();
    });
  });

  group('TokenValidationResult factory constructors', () {
    test('valid() sets isValid true and status valid', () {
      const result = TokenValidationResult.valid('ok');
      check(result.isValid).isTrue();
      check(result.status).equals(TokenValidationStatus.valid);
      check(result.message).equals('ok');
    });

    test('valid() can include expiryData and serverData', () {
      final expiry = DateTime(2030, 1, 1);
      final result = TokenValidationResult.valid(
        'ok',
        expiryData: expiry,
        serverData: {'key': 'value'},
      );
      check(result.expiryData).equals(expiry);
      check(result.serverData).isNotNull();
    });

    test('invalid() sets isValid false and status invalid', () {
      const result = TokenValidationResult.invalid('bad');
      check(result.isValid).isFalse();
      check(result.status).equals(TokenValidationStatus.invalid);
    });

    test('expired() sets isValid false and isExpired true', () {
      const result = TokenValidationResult.expired('expired token');
      check(result.isValid).isFalse();
      check(result.isExpired).isTrue();
    });

    test('expiringSoon() sets isValid true and isExpiringSoon true', () {
      final result = TokenValidationResult.expiringSoon(
        'expiring',
        DateTime(2030, 1, 1),
      );
      check(result.isValid).isTrue();
      check(result.isExpiringSoon).isTrue();
      check(result.expiryData).isNotNull();
    });

    test('networkError() sets isValid false and hasNetworkError true',
        () {
      const result =
          TokenValidationResult.networkError('network issue');
      check(result.isValid).isFalse();
      check(result.hasNetworkError).isTrue();
    });

    test('apiKeyNotSupported() sets isValid false and correct status',
        () {
      const result =
          TokenValidationResult.apiKeyNotSupported('no api keys');
      check(result.isValid).isFalse();
      check(result.isApiKeyNotSupported).isTrue();
      check(result.status)
          .equals(TokenValidationStatus.apiKeyNotSupported);
    });
  });

  group('TokenValidationResult getters', () {
    test('isExpired returns false for valid result', () {
      const result = TokenValidationResult.valid('ok');
      check(result.isExpired).isFalse();
    });

    test('isExpiringSoon returns false for expired result', () {
      const result = TokenValidationResult.expired('expired');
      check(result.isExpiringSoon).isFalse();
    });

    test('hasNetworkError returns false for valid result', () {
      const result = TokenValidationResult.valid('ok');
      check(result.hasNetworkError).isFalse();
    });

    test('toString includes status info', () {
      const result = TokenValidationResult.valid('ok');
      final str = result.toString();
      check(str).contains('isValid: true');
      check(str).contains('valid');
    });
  });

  group('TokenValidationCache', () {
    setUp(() {
      TokenValidationCache.clearCache();
    });

    test('cacheResult and getCachedResult round-trip', () {
      const token = 'my-test-token-long-enough';
      const result = TokenValidationResult.valid('cached');

      TokenValidationCache.cacheResult(token, result);
      final cached = TokenValidationCache.getCachedResult(token);

      check(cached).isNotNull();
      check(cached!.isValid).isTrue();
      check(cached.message).equals('cached');
    });

    test('getCachedResult returns null for unknown token', () {
      final cached = TokenValidationCache.getCachedResult(
        'unknown-token-xyz',
      );
      check(cached).isNull();
    });

    test('clearCache removes all entries', () {
      const token = 'my-cached-token-here';
      const result = TokenValidationResult.valid('ok');

      TokenValidationCache.cacheResult(token, result);
      TokenValidationCache.clearCache();

      final cached = TokenValidationCache.getCachedResult(token);
      check(cached).isNull();
    });

    test('different tokens produce different cache entries', () {
      const token1 = 'token-one-long-enough';
      const token2 = 'token-two-long-enough';
      const result1 = TokenValidationResult.valid('first');
      const result2 = TokenValidationResult.invalid('second');

      TokenValidationCache.cacheResult(token1, result1);
      TokenValidationCache.cacheResult(token2, result2);

      final cached1 = TokenValidationCache.getCachedResult(token1);
      final cached2 = TokenValidationCache.getCachedResult(token2);

      check(cached1).isNotNull();
      check(cached1!.isValid).isTrue();
      check(cached2).isNotNull();
      check(cached2!.isValid).isFalse();
    });
  });

  group('TokenValidator.generateCacheKey', () {
    test('returns a 16-character hex string', () {
      final key = TokenValidator.generateCacheKey('test-token');
      check(key.length).equals(16);
      check(RegExp(r'^[a-f0-9]{16}$').hasMatch(key)).isTrue();
    });

    test('same token always produces same key', () {
      final key1 = TokenValidator.generateCacheKey('same-token');
      final key2 = TokenValidator.generateCacheKey('same-token');
      check(key1).equals(key2);
    });

    test('different tokens produce different keys', () {
      final key1 = TokenValidator.generateCacheKey('token-a');
      final key2 = TokenValidator.generateCacheKey('token-b');
      check(key1).not((it) => it.equals(key2));
    });
  });

  group('TokenValidator.validateTokenWithServer', () {
    test('returns valid on successful server call', () async {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(hours: 1)),
      });

      final result = await TokenValidator.validateTokenWithServer(
        jwt,
        () async => {'status': 'ok'},
      );

      check(result.isValid).isTrue();
      check(result.serverData).isNotNull();
    });

    test('returns format error if token is invalid', () async {
      final result = await TokenValidator.validateTokenWithServer(
        '',
        () async => 'ok',
      );

      check(result.isValid).isFalse();
      check(result.status).equals(TokenValidationStatus.invalid);
    });

    test('returns networkError on timeout', () async {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(hours: 1)),
      });

      final result = await TokenValidator.validateTokenWithServer(
        jwt,
        () async => throw Exception('timeout'),
      );

      check(result.hasNetworkError).isTrue();
    });

    test('returns invalid on 401 error', () async {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(hours: 1)),
      });

      final result = await TokenValidator.validateTokenWithServer(
        jwt,
        () async => throw Exception('401 Unauthorized'),
      );

      check(result.isValid).isFalse();
      check(result.status).equals(TokenValidationStatus.invalid);
    });

    test('returns invalid on 403 error', () async {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(hours: 1)),
      });

      final result = await TokenValidator.validateTokenWithServer(
        jwt,
        () async => throw Exception('403 Forbidden'),
      );

      check(result.isValid).isFalse();
      check(result.status).equals(TokenValidationStatus.invalid);
    });

    test('returns networkError on generic error', () async {
      final jwt = fakeJwt({
        'sub': 'user1',
        'exp': unixSeconds(const Duration(hours: 1)),
      });

      final result = await TokenValidator.validateTokenWithServer(
        jwt,
        () async => throw Exception('connection refused'),
      );

      check(result.hasNetworkError).isTrue();
    });
  });
}
