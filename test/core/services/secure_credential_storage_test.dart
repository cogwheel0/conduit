import 'dart:convert';

import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _credentialsKey = 'user_credentials_v2';
const _authTokenKey = 'auth_token_v2';
const _serverConfigsKey = 'server_configs_v2';
const _availabilityKey = 'test_availability';
const _hermesApiKey = 'hermes_api_key_v1';
const _hermesSessionKey = 'hermes_session_key_v1';

void main() {
  late _FakeSecureStorage fake;
  late SecureCredentialStorage storage;

  setUp(() {
    fake = _FakeSecureStorage();
    storage = SecureCredentialStorage(instance: fake);
  });

  group('credentials', () {
    test('saveCredentials round-trips the saved credentials', () async {
      await storage.saveCredentials(
        serverId: 's1',
        username: 'u',
        password: 'p',
        authType: 'ldap',
      );

      final credentials = await storage.getSavedCredentials();

      expect(credentials, isNotNull);
      expect(credentials!['serverId'], 's1');
      expect(credentials['username'], 'u');
      expect(credentials['password'], 'p');
      expect(credentials['authType'], 'ldap');
      expect(credentials['savedAt'], isNotEmpty);
    });

    test('saveCredentials defaults authType to credentials', () async {
      await storage.saveCredentials(
        serverId: 's1',
        username: 'u',
        password: 'p',
      );

      final credentials = await storage.getSavedCredentials();

      expect(credentials?['authType'], 'credentials');
    });

    test('getSavedCredentials returns null when nothing is stored', () async {
      final credentials = await storage.getSavedCredentials();

      expect(credentials, isNull);
    });

    test('getSavedCredentials deletes stored non-map JSON', () async {
      fake.store[_credentialsKey] = jsonEncode('just a string');

      final credentials = await storage.getSavedCredentials();

      expect(credentials, isNull);
      expect(fake.store.containsKey(_credentialsKey), isFalse);
    });

    test(
      'getSavedCredentials deletes stored credentials missing password',
      () async {
        fake.store[_credentialsKey] = jsonEncode({
          'serverId': 's1',
          'username': 'u',
          'authType': 'credentials',
          'savedAt': DateTime.now().toIso8601String(),
          'deviceId': 'device',
          'version': '2.1',
        });

        final credentials = await storage.getSavedCredentials();

        expect(credentials, isNull);
        expect(fake.store.containsKey(_credentialsKey), isFalse);
      },
    );

    test('getSavedCredentials tolerates a foreign deviceId', () async {
      fake.store[_credentialsKey] = _storedCredentialsJson(
        deviceId: 'someone-elses-device',
      );

      final credentials = await storage.getSavedCredentials();

      expect(credentials, isNotNull);
      expect(credentials!['serverId'], 's1');
      expect(credentials['username'], 'u');
      expect(credentials['password'], 'p');
      expect(credentials['authType'], 'credentials');
    });

    test(
      'getSavedCredentials returns null and keeps data on read error',
      () async {
        fake.store[_credentialsKey] = _storedCredentialsJson();
        fake.failReadsFor.add(_credentialsKey);

        final credentials = await storage.getSavedCredentials();

        expect(credentials, isNull);
        expect(fake.store.containsKey(_credentialsKey), isTrue);
      },
    );

    test('saveCredentials throws when secure storage is unavailable', () async {
      fake.failWritesFor.add(_availabilityKey);

      await expectLater(
        storage.saveCredentials(serverId: 's1', username: 'u', password: 'p'),
        throwsA(isA<Exception>()),
      );
    });

    test('deleteSavedCredentials removes stored credentials', () async {
      await storage.saveCredentials(
        serverId: 's1',
        username: 'u',
        password: 'p',
      );

      await storage.deleteSavedCredentials();

      expect(fake.store.containsKey(_credentialsKey), isFalse);
      expect(await storage.getSavedCredentials(), isNull);
    });
  });

  group('auth token', () {
    test('saveAuthToken round-trips the saved token', () async {
      await storage.saveAuthToken('tok');

      final token = await storage.getAuthToken();

      expect(token, 'tok');
    });

    test('getAuthToken returns null when nothing is stored', () async {
      final token = await storage.getAuthToken();

      expect(token, isNull);
    });

    test('getAuthToken returns null on read error', () async {
      fake.store[_authTokenKey] = 'tok';
      fake.failReadsFor.add(_authTokenKey);

      final token = await storage.getAuthToken();

      expect(token, isNull);
    });

    test('saveAuthToken throws on write error', () async {
      fake.failWritesFor.add(_authTokenKey);

      await expectLater(storage.saveAuthToken('tok'), throwsStateError);
    });

    test('deleteAuthToken removes the saved token', () async {
      await storage.saveAuthToken('tok');

      await storage.deleteAuthToken();

      expect(fake.store.containsKey(_authTokenKey), isFalse);
    });
  });

  group('server configs', () {
    test('saveServerConfigs round-trips the saved JSON', () async {
      const configsJson = '[{"id":"a"}]';

      await storage.saveServerConfigs(configsJson);

      expect(await storage.getServerConfigs(), configsJson);
    });

    test('getServerConfigs throws on read error', () async {
      fake.store[_serverConfigsKey] = '[{"id":"a"}]';
      fake.failReadsFor.add(_serverConfigsKey);

      await expectLater(storage.getServerConfigs(), throwsStateError);
    });
  });

  group('Hermes keys', () {
    test('reads stored API and session keys', () async {
      fake.store[_hermesApiKey] = 'api-key';
      fake.store[_hermesSessionKey] = 'session-key';

      expect(await storage.getHermesApiKey(), 'api-key');
      expect(await storage.getHermesSessionKey(), 'session-key');
    });

    test('does not mask keychain read failures as missing keys', () async {
      fake.failReadsFor.addAll({_hermesApiKey, _hermesSessionKey});

      await expectLater(storage.getHermesApiKey(), throwsStateError);
      await expectLater(storage.getHermesSessionKey(), throwsStateError);
    });

    test('retries a transient keychain read failure once', () async {
      fake.store[_hermesApiKey] = 'api-key';
      fake.remainingReadFailures[_hermesApiKey] = 1;

      expect(await storage.getHermesApiKey(), 'api-key');
    });
  });

  group('clearAll', () {
    test(
      'clearAll removes stored data and swallows deleteAll errors',
      () async {
        await storage.saveCredentials(
          serverId: 's1',
          username: 'u',
          password: 'p',
        );
        await storage.saveAuthToken('tok');

        await storage.clearAll();

        expect(fake.store, isEmpty);

        fake.store[_credentialsKey] = _storedCredentialsJson();
        fake.store[_authTokenKey] = 'tok';
        fake.failDeleteAll = true;

        await expectLater(storage.clearAll(), completes);
        expect(fake.store.containsKey(_credentialsKey), isTrue);
        expect(fake.store.containsKey(_authTokenKey), isTrue);
      },
    );
  });
}

String _storedCredentialsJson({String deviceId = 'device'}) {
  return jsonEncode({
    'serverId': 's1',
    'username': 'u',
    'password': 'p',
    'authType': 'credentials',
    'savedAt': DateTime.now().toIso8601String(),
    'deviceId': deviceId,
    'version': '2.1',
  });
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> store = {};
  final Set<String> failReadsFor = {};
  final Map<String, int> remainingReadFailures = {};
  final Set<String> failWritesFor = {};
  bool failDeleteAll = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final remainingFailures = remainingReadFailures[key] ?? 0;
    if (remainingFailures > 0) {
      remainingReadFailures[key] = remainingFailures - 1;
      throw StateError('transient read failed for $key');
    }
    if (failReadsFor.contains(key)) {
      throw StateError('read failed for $key');
    }

    return store[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWritesFor.contains(key)) {
      throw StateError('write failed for $key');
    }

    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failDeleteAll) {
      throw StateError('deleteAll failed');
    }

    store.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
