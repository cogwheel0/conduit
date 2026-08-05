import 'dart:async';

import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:conduit/features/chatgpt/chatgpt_providers.dart';
import 'package:conduit/features/chatgpt/chatgpt_runtime_client.dart';
import 'package:conduit/features/chatgpt/chatgpt_thread_binding_store.dart';
import 'package:conduit/features/chatgpt/native_generated/api/contract.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _accountA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _accountB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    PreferencesStore.debugReset();
    await PreferencesStore.ensureInitialized();
  });

  tearDown(PreferencesStore.debugReset);

  test('unscoped tombstone defers cleanup without a verified owner', () async {
    await PreferencesStore.putChecked(
      PreferenceKeys.chatGptDisconnectTombstone,
      'pending',
    );
    final bindings = _TrackingBindingStore();
    final profiles = _TrackingDirectProfiles();
    final runtime = _TrackingRuntime();
    final container = ProviderContainer(
      overrides: [
        chatGptRuntimeClientProvider.overrideWithValue(runtime),
        chatGptThreadBindingStoreProvider.overrideWithValue(bindings),
        secureStorageProvider.overrideWithValue(_MemorySecureStorage()),
        directConnectionProfilesProvider.overrideWith(() => profiles),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatGptConnectionProvider.future);

    expect(bindings.deletedFingerprints, isEmpty);
    expect(bindings.chatIds, {'$_accountA-chat', '$_accountB-chat'});
    expect(profiles.removed, isFalse);
    expect(runtime.disconnectCalls, 0);
    expect(
      PreferencesStore.getString(PreferenceKeys.chatGptDisconnectTombstone),
      'pending',
    );
  });

  test('unscoped tombstone recovers live ownership before cleanup', () async {
    await PreferencesStore.putChecked(
      PreferenceKeys.chatGptDisconnectTombstone,
      'pending',
    );
    final bindings = _TrackingBindingStore();
    final profiles = _TrackingDirectProfiles();
    final runtime = _TrackingRuntime(
      authenticated: true,
      accountFingerprint: _accountA,
    );
    final container = ProviderContainer(
      overrides: [
        chatGptRuntimeClientProvider.overrideWithValue(runtime),
        chatGptThreadBindingStoreProvider.overrideWithValue(bindings),
        secureStorageProvider.overrideWithValue(_MemorySecureStorage()),
        directConnectionProfilesProvider.overrideWith(() => profiles),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatGptConnectionProvider.future);

    expect(bindings.deletedFingerprints, [_accountA]);
    expect(bindings.chatIds, {'$_accountB-chat'});
    expect(profiles.removed, isTrue);
    expect(runtime.disconnectCalls, 1);
    expect(runtime.shutdownCalls, 1);
    expect(
      PreferencesStore.getString(PreferenceKeys.chatGptDisconnectTombstone),
      isNull,
    );
  });

  test('disconnect stops before mutation without a verified owner', () async {
    final bindings = _TrackingBindingStore();
    final runtime = _TrackingRuntime();
    final container = ProviderContainer(
      overrides: [
        chatGptRuntimeClientProvider.overrideWithValue(runtime),
        chatGptThreadBindingStoreProvider.overrideWithValue(bindings),
        secureStorageProvider.overrideWithValue(_MemorySecureStorage()),
        directConnectionProfilesProvider.overrideWith(
          _TrackingDirectProfiles.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(chatGptConnectionProvider.future);

    await expectLater(
      container.read(chatGptConnectionProvider.notifier).disconnect(),
      throwsStateError,
    );

    expect(runtime.disconnectCalls, 0);
    expect(runtime.shutdownCalls, 0);
    expect(bindings.chatIds, {'$_accountA-chat', '$_accountB-chat'});
    expect(
      PreferencesStore.getString(PreferenceKeys.chatGptDisconnectTombstone),
      isNull,
    );
  });

  test(
    'authenticated identity never falls back to a stale fingerprint',
    () async {
      await PreferencesStore.putChecked(
        PreferenceKeys.chatGptAccountFingerprint,
        _accountB,
      );
      final bindings = _TrackingBindingStore();
      final runtime = _TrackingRuntime(authenticated: true);
      final container = ProviderContainer(
        overrides: [
          chatGptRuntimeClientProvider.overrideWithValue(runtime),
          chatGptThreadBindingStoreProvider.overrideWithValue(bindings),
          secureStorageProvider.overrideWithValue(_MemorySecureStorage()),
          directConnectionProfilesProvider.overrideWith(
            _TrackingDirectProfiles.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatGptConnectionProvider.future);

      await expectLater(
        container.read(chatGptConnectionProvider.notifier).disconnect(),
        throwsStateError,
      );

      expect(runtime.disconnectCalls, 0);
      expect(bindings.deletedFingerprints, isEmpty);
      expect(bindings.chatIds, {'$_accountA-chat', '$_accountB-chat'});
    },
  );

  test('disconnected auth may use the last verified fingerprint', () async {
    await PreferencesStore.putChecked(
      PreferenceKeys.chatGptAccountFingerprint,
      _accountA,
    );
    final bindings = _TrackingBindingStore();
    final runtime = _TrackingRuntime();
    final container = ProviderContainer(
      overrides: [
        chatGptRuntimeClientProvider.overrideWithValue(runtime),
        chatGptThreadBindingStoreProvider.overrideWithValue(bindings),
        secureStorageProvider.overrideWithValue(_MemorySecureStorage()),
        directConnectionProfilesProvider.overrideWith(
          _TrackingDirectProfiles.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(chatGptConnectionProvider.future);

    await container.read(chatGptConnectionProvider.notifier).disconnect();

    expect(runtime.disconnectCalls, 1);
    expect(bindings.deletedFingerprints, [_accountA]);
    expect(bindings.chatIds, {'$_accountB-chat'});
  });
}

final class _TrackingRuntime implements ChatGptRuntimeClient {
  _TrackingRuntime({bool authenticated = false, String? accountFingerprint})
    : _authenticated = authenticated,
      _accountFingerprint = accountFingerprint;

  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast();
  bool _authenticated;
  String? _accountFingerprint;
  int disconnectCalls = 0;
  int shutdownCalls = 0;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<AuthStateInfo> authState() async => AuthStateInfo(
    authenticated: _authenticated,
    accountFingerprint: _accountFingerprint,
  );

  @override
  Future<void> disconnectAccount() async {
    disconnectCalls += 1;
    _authenticated = false;
    _accountFingerprint = null;
  }

  @override
  Future<void> shutdown() async => shutdownCalls += 1;

  @override
  Future<DeviceCodeChallenge> beginDeviceCodeLogin() =>
      throw UnsupportedError('unused');

  @override
  Future<void> cancelDeviceCodeLogin() => throw UnsupportedError('unused');

  @override
  Future<void> interruptTurn(String runId) => throw UnsupportedError('unused');

  @override
  Future<List<ModelInfo>> listModels() => throw UnsupportedError('unused');

  @override
  Future<RunInfo> startTurn(TurnRequest request) =>
      throw UnsupportedError('unused');
}

final class _TrackingBindingStore implements ChatGptThreadBindingStore {
  final List<String> deletedFingerprints = [];
  final Set<String> chatIds = {'$_accountA-chat', '$_accountB-chat'};

  @override
  Future<int> deleteAccountChats(String accountFingerprint) async {
    deletedFingerprints.add(accountFingerprint);
    return chatIds.remove('$accountFingerprint-chat') ? 1 : 0;
  }

  @override
  Future<void> delete(
    String localChatId,
    String profileId,
    String headMessageId,
  ) async {}

  @override
  Future<ChatGptThreadBinding?> get(
    String localChatId,
    String profileId,
    String headMessageId,
  ) async => null;

  @override
  Future<ChatGptThreadBinding?> latest(
    String localChatId,
    String profileId,
  ) async => null;

  @override
  Future<void> put(ChatGptThreadBinding binding) async {}
}

final class _TrackingDirectProfiles extends DirectConnectionProfilesController {
  bool removed = false;

  @override
  Future<List<DirectConnectionProfile>> build() async => const [];

  @override
  Future<void> removeChatGptAccountProfiles() async => removed = true;
}

final class _MemorySecureStorage implements FlutterSecureStorage {
  final Map<String, String> values = {};

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
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
