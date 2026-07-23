import 'dart:async';

import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/ollama_thinking.dart';
import 'package:conduit/features/direct_connections/services/direct_connection_profile_store.dart';
import 'package:checks/checks.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(PreferencesStore.debugReset);

  test('profile store keeps full profile only in secure storage', () async {
    const platformStorage = FlutterSecureStorage();
    final secure = SecureCredentialStorage(instance: platformStorage);
    final store = DirectConnectionProfileStore(secure);
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Private provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://example.test/v1',
      apiKey: 'top-secret',
      customHeaders: const {'X-Tenant-Secret': 'tenant-secret'},
    );

    await store.save([profile]);

    final raw = await secure.getDirectConnectionProfiles();
    expect(raw, contains('top-secret'));
    final loaded = (await store.load()).single;
    expect(loaded.apiKey, 'top-secret');
    expect(loaded.customHeaders['X-Tenant-Secret'], 'tenant-secret');
    expect(
      PreferencesStore.getBool(PreferenceKeys.directConnectionsConfigured),
      isTrue,
    );
    final preferences = PreferencesStore.instance;
    for (final secret in const ['top-secret', 'tenant-secret']) {
      expect(
        preferences.getKeys().any(
          (key) => (preferences.get(key)?.toString() ?? '').contains(secret),
        ),
        isFalse,
      );
    }

    await store.clear();
    expect(await secure.getDirectConnectionProfiles(), isNull);
    expect(
      PreferencesStore.getBool(PreferenceKeys.directConnectionsConfigured),
      isFalse,
    );
  });

  test(
    'profile store round-trips per-model Ollama keep-alive values',
    () async {
      const platformStorage = FlutterSecureStorage();
      final secure = SecureCredentialStorage(instance: platformStorage);
      final store = DirectConnectionProfileStore(secure);
      final profile = DirectConnectionProfile(
        id: 'home-ollama',
        name: 'Home Ollama',
        adapterKey: kOllamaAdapterKey,
        baseUrl: 'http://localhost:11434',
        ollamaKeepAliveByModel: const {
          'llama3.2:latest': '30m',
          'qwen3:latest': '-1',
        },
        ollamaThinkingByModel: const {
          'gpt-oss:120b': 'medium',
          'qwen3:latest': 'high',
        },
      );

      await store.save([profile]);
      final loaded = (await store.load()).single;

      check(loaded.ollamaKeepAliveFor('llama3.2:latest')).equals('30m');
      check(loaded.ollamaKeepAliveFor('qwen3:latest')).equals('-1');
      check(
        loaded.ollamaThinkingFor('gpt-oss:120b'),
      ).equals(OllamaThinkingSetting.medium);
      check(
        loaded.ollamaThinkingFor('qwen3:latest'),
      ).equals(OllamaThinkingSetting.high);
      check(sameDirectConnectionProfileValues(profile, loaded)).isTrue();
    },
  );

  test('Ollama Cloud recognition accepts only the official API root', () {
    check(isOllamaCloudApiBaseUrl('https://ollama.com')).isTrue();
    check(isOllamaCloudApiBaseUrl('https://ollama.com/')).isTrue();
    check(isOllamaCloudApiBaseUrl('https://ollama.com:443')).isTrue();

    check(isOllamaCloudApiBaseUrl('http://ollama.com')).isFalse();
    check(isOllamaCloudApiBaseUrl('https://www.ollama.com')).isFalse();
    check(isOllamaCloudApiBaseUrl('https://ollama.com/api')).isFalse();
    check(isOllamaCloudApiBaseUrl('https://ollama.com?query=1')).isFalse();
    check(isOllamaCloudApiBaseUrl('https://ollama.com/#fragment')).isFalse();
    check(isOllamaCloudApiBaseUrl('https://user@ollama.com')).isFalse();
    check(isOllamaCloudApiBaseUrl('https://ollama.com.example')).isFalse();
  });

  test(
    'unsupported document version is surfaced without deleting data',
    () async {
      const platformStorage = FlutterSecureStorage();
      final secure = SecureCredentialStorage(instance: platformStorage);
      await secure.saveDirectConnectionProfiles('{"version":99,"profiles":[]}');
      final store = DirectConnectionProfileStore(secure);

      await expectLater(store.load(), throwsFormatException);
      expect(await secure.getDirectConnectionProfiles(), isNotNull);
    },
  );

  test(
    'repository strips an origin change even when called directly',
    () async {
      const platformStorage = FlutterSecureStorage();
      final store = DirectConnectionProfileStore(
        SecureCredentialStorage(instance: platformStorage),
      );
      final original = DirectConnectionProfile(
        id: 'profile-one',
        name: 'Private provider',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://one.test/v1',
        apiKey: 'old-secret',
        customHeaders: const {'X-Key': 'old-header'},
      );
      await store.save([original]);

      final stripped = await store.save([
        original.copyWith(baseUrl: 'https://two.test/v1'),
      ]);

      expect(stripped.single.apiKey, isNull);
      expect(stripped.single.customHeaders, isEmpty);

      final confirmed = await store.save(
        [
          stripped.single.copyWith(
            baseUrl: 'https://three.test/v1',
            apiKey: 'new-secret',
          ),
        ],
        secretsConfirmedForNewOrigin: const {'profile-one'},
      );
      expect(confirmed.single.apiKey, 'new-secret');
    },
  );

  test('overlapping mutations commit in invocation order', () async {
    final platformStorage = _GatedSecureStorage();
    final secure = SecureCredentialStorage(instance: platformStorage);
    final store = DirectConnectionProfileStore(secure);
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Private provider',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://one.test/v1',
      apiKey: 'secret',
    );

    final save = store.save([profile]);
    await platformStorage.writeStarted.future;
    final clear = store.clear();
    await Future<void>.delayed(Duration.zero);
    expect(platformStorage.deleteCalls, 0);

    platformStorage.allowWrite.complete();
    await save;
    await clear;

    expect(await secure.getDirectConnectionProfiles(), isNull);
    expect(platformStorage.deleteCalls, 1);
  });
}

final class _GatedSecureStorage implements FlutterSecureStorage {
  final Map<String, String> values = {};
  final Completer<void> writeStarted = Completer<void>();
  final Completer<void> allowWrite = Completer<void>();
  int deleteCalls = 0;
  bool _gateNextWrite = true;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

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
    if (_gateNextWrite) {
      _gateNextWrite = false;
      writeStarted.complete();
      await allowWrite.future;
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
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
    deleteCalls++;
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
