import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Parking Open WebUI: another account backend owns the Chats tab, so no
/// Open WebUI account may be active -- not even the only one saved, which
/// storage otherwise treats as active -- while every account keeps its
/// session for when the user comes back.
void main() {
  late Directory tempDir;
  late OptimizedStorageService storage;
  late WorkerManager workerManager;
  late _RefusingSecureStore secure;
  late HiveBoxes boxes;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('openwebui-park-test');
    Hive.init(tempDir.path);
    boxes = HiveBoxes(
      preferences: await Hive.openBox<dynamic>(HiveBoxNames.preferences),
      caches: await Hive.openBox<dynamic>(HiveBoxNames.caches),
      attachmentQueue: await Hive.openBox<dynamic>(
        HiveBoxNames.attachmentQueue,
      ),
      metadata: await Hive.openBox<dynamic>(HiveBoxNames.metadata),
    );
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    secure = _RefusingSecureStore();
    storage = OptimizedStorageService(
      secureStorage: secure,
      boxes: boxes,
      workerManager: workerManager,
    );
  });

  tearDown(() async {
    workerManager.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ServerConfig server(String id) =>
      ServerConfig(id: id, name: id, url: 'https://$id.example.com');

  Future<void> configure(List<String> ids) =>
      storage.saveServerConfigs(ids.map(server).toList(growable: false));

  test('the only account is not active while parked', () async {
    await configure(['a']);
    await storage.saveAuthToken('token-a');
    // Active by storage's single-account fallback, with no id kept.
    check(await storage.getEffectiveActiveServerId()).equals('a');

    await storage.parkActiveServer(fromServerId: 'a');

    check(storage.isOpenWebUiParked).isTrue();
    check(await storage.getEffectiveActiveServerId()).isNull();
    check(await storage.getActiveServerId()).isNull();
    // Filed away, not deleted: no token is live, the vault holds it.
    check(await storage.getAuthTokenStrict()).isNull();
    check(await storage.vaultedServerIds()).contains('a');

    final container = ProviderContainer(
      overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    check(await container.read(activeServerProvider.future)).isNull();
  });

  test('parking an account active only by fallback clears its live token',
      () async {
    await configure(['a']);
    await storage.saveAuthToken('token-a');
    // An install that never stored an id: the only account is active by the
    // single-account fallback alone.
    await PreferencesStore.remove(PreferenceKeys.activeServerId);
    storage = OptimizedStorageService(
      secureStorage: secure,
      boxes: boxes,
      workerManager: workerManager,
    );
    check(PreferencesStore.getString(PreferenceKeys.activeServerId)).isNull();
    check(await storage.getEffectiveActiveServerId()).equals('a');

    await storage.parkActiveServer(fromServerId: 'a');

    // The secure slot itself, not a cached read: a token left live there
    // would let a cold start sign Open WebUI back in while it is parked.
    check(await secure.read(key: 'auth_token_v2')).isNull();
    check(await storage.vaultedServerIds()).contains('a');
    final restarted = OptimizedStorageService(
      secureStorage: secure,
      boxes: boxes,
      workerManager: workerManager,
    );
    check(await restarted.getAuthTokenStrict()).isNull();
    check(await restarted.getEffectiveActiveServerId()).isNull();
  });

  test('a park that fails keeps the session live for a retry', () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.saveCredentials(
      serverId: 'a',
      username: 'user@example.com',
      password: 'secret',
    );
    final prefs = PreferencesStore.instance;
    var failFlag = true;
    PreferencesStore.debugOverride(
      prefs,
      writeInterceptor: (store, key, value) async =>
          failFlag && key == PreferenceKeys.openWebUiParked && value == true
          ? false
          : null,
    );

    await check(
      storage.parkActiveServer(fromServerId: 'a'),
    ).throws<StateError>();

    // Still active, signed in, with the sign-in live rather than only filed.
    check(storage.isOpenWebUiParked).isFalse();
    check(await storage.getEffectiveActiveServerId()).equals('a');
    check(await storage.getAuthTokenStrict()).equals('token-a');
    check(await storage.getSavedCredentials()).isNotNull();

    // A retry then parks with nothing lost.
    failFlag = false;
    await storage.parkActiveServer(fromServerId: 'a');
    check(await storage.switchActiveServer(toServerId: 'a')).isTrue();
    check(await storage.getAuthTokenStrict()).equals('token-a');
    check(await storage.getSavedCredentials()).isNotNull();
  });

  test('a park whose undo cannot put the session back keeps it for a retry',
      () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.saveCredentials(
      serverId: 'a',
      username: 'user@example.com',
      password: 'secret',
    );
    final prefs = PreferencesStore.instance;
    var failFlag = true;
    PreferencesStore.debugOverride(
      prefs,
      writeInterceptor: (store, key, value) async =>
          failFlag && key == PreferenceKeys.openWebUiParked && value == true
          ? false
          : null,
    );
    // The undo's first write puts the sign-in back live; a locked Keychain
    // refuses it, so nothing comes back out of the vault.
    secure.refusedKey = 'user_credentials_v2';

    // The flag write is what stopped the park, and is what is reported.
    await check(
      storage.parkActiveServer(fromServerId: 'a'),
    ).throws<StateError>();
    check(await storage.getAuthTokenStrict()).isNull();

    // A retry once the Keychain is back must not file the empty live slots
    // over the session still in the vault.
    failFlag = false;
    secure.refusedKey = null;
    await storage.parkActiveServer(fromServerId: 'a');
    check(await storage.switchActiveServer(toServerId: 'a')).isTrue();
    check(await storage.getAuthTokenStrict()).equals('token-a');
    check(await storage.getSavedCredentials()).isNotNull();
  });

  test('a park that fails after clearing the active id puts it back',
      () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    // The id is cleared, then saving the accounts' active flags fails.
    secure.refusedKey = 'openwebui_registry_v1';

    await check(
      storage.parkActiveServer(fromServerId: 'a'),
    ).throws<_KeychainRefused>();

    secure.refusedKey = null;
    check(PreferencesStore.getString(PreferenceKeys.activeServerId)).equals(
      'a',
    );
    check(storage.isOpenWebUiParked).isFalse();
    check(await storage.getActiveServerId()).equals('a');
    check(await storage.getAuthTokenStrict()).equals('token-a');
  });

  test('a park that cannot be undone keeps the session in the vault',
      () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    // The id is cleared, then saving the accounts' active flags fails; the
    // undo can then neither name the account again nor end the park.
    secure.refusedKey = 'openwebui_registry_v1';
    final prefs = PreferencesStore.instance;
    var failUndo = true;
    PreferencesStore.debugOverride(
      prefs,
      writeInterceptor: (store, key, value) async =>
          failUndo &&
              ((key == PreferenceKeys.activeServerId && value == 'a') ||
                  (key == PreferenceKeys.openWebUiParked && value == null))
          ? false
          : null,
    );

    await check(
      storage.parkActiveServer(fromServerId: 'a'),
    ).throws<_KeychainRefused>();
    secure.refusedKey = null;
    failUndo = false;
    check(await storage.getEffectiveActiveServerId()).isNull();

    // Choosing the account again finds its session where the park put it.
    check(await storage.switchActiveServer(toServerId: 'a')).isTrue();
    check(await storage.getAuthTokenStrict()).equals('token-a');
  });

  test('a switch that fails after the park undo keeps the vault for a retry',
      () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    final prefs = PreferencesStore.instance;
    String? failKey = PreferenceKeys.openWebUiParked;
    Object? failValue = true;
    PreferencesStore.debugOverride(
      prefs,
      writeInterceptor: (store, key, value) async =>
          key == failKey && value == failValue ? false : null,
    );
    // The undo cannot put the token back live: it stays in the vault.
    secure.refusedKey = 'auth_token_v2';
    await check(
      storage.parkActiveServer(fromServerId: 'a'),
    ).throws<StateError>();
    secure.refusedKey = null;

    // A switch away then fails after filing the session, with the account
    // still active and its live slots still empty.
    failKey = PreferenceKeys.activeServerId;
    failValue = 'b';
    await check(
      storage.switchActiveServer(fromServerId: 'a', toServerId: 'b'),
    ).throws<StateError>();
    failKey = null;
    check(await storage.getEffectiveActiveServerId()).equals('a');

    // The retry must not file those empty slots over the vault either.
    await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');
    check(
      await storage.switchActiveServer(fromServerId: 'b', toServerId: 'a'),
    ).isTrue();
    check(await storage.getAuthTokenStrict()).equals('token-a');
  });

  test('a sign-in that fails after choosing the account stays parked',
      () async {
    await configure(['a']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.parkActiveServer(fromServerId: 'a');
    final ownership = await storage.captureSavedServerSessionOwnership('a');
    var checks = 0;

    final committed = await storage.commitExistingServerSession(
      ownership: ownership!,
      token: 'token-new',
      // Four checks pass before anything is written; the eighth, right after
      // the account was chosen by id (which ends a park), fails.
      canCommit: () => ++checks < 8,
      publish: () {},
    );

    check(committed).isFalse();
    check(checks).equals(8);
    // Rolled back to parked, so the only account is not active by fallback.
    check(storage.isOpenWebUiParked).isTrue();
    check(await storage.getEffectiveActiveServerId()).isNull();
    check(await storage.getAuthTokenStrict()).isNull();
  });

  test('a selection whose publication fails stays parked', () async {
    await configure(['a']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.parkActiveServer(fromServerId: 'a');

    await check(
      storage.selectUnauthenticatedServerConfig(
        server('a'),
        publish: () => throw StateError('publication failed'),
      ),
    ).throws<StateError>();

    // Rolled back to parked, so the only account is not active by fallback.
    check(storage.isOpenWebUiParked).isTrue();
    check(await storage.getEffectiveActiveServerId()).isNull();
  });

  test('a superseded selection stays parked', () async {
    await configure(['a']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.parkActiveServer(fromServerId: 'a');
    var superseded = false;

    final selected = await storage.selectUnauthenticatedServerConfig(
      server('a'),
      canCommit: () => !superseded,
      publish: () => superseded = true,
    );

    check(selected).isFalse();
    check(storage.isOpenWebUiParked).isTrue();
    check(await storage.getEffectiveActiveServerId()).isNull();
  });

  test('parking an account active by its stored id clears its live token',
      () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');

    await storage.parkActiveServer(fromServerId: 'a');

    check(await secure.read(key: 'auth_token_v2')).isNull();
    check(await storage.vaultedServerIds()).contains('a');
  });

  test('a parked cold start builds no Open WebUI client', () async {
    await configure(['a']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.parkActiveServer(fromServerId: 'a');

    final container = ProviderContainer(
      overrides: [
        optimizedStorageServiceProvider.overrideWithValue(storage),
        workerManagerProvider.overrideWithValue(workerManager),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeServerProvider.future);
    // No API client, so no requests, no socket and nothing for sync to pull
    // with: the engine stays inert.
    check(container.read(apiServiceProvider)).isNull();
    check(container.read(syncApiClientProvider)).isNull();
  });

  test('switching to an account un-parks with its session', () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.parkActiveServer(fromServerId: 'a');

    final signedIn = await storage.switchActiveServer(toServerId: 'a');

    check(signedIn).isTrue();
    check(storage.isOpenWebUiParked).isFalse();
    check(await storage.getActiveServerId()).equals('a');
    check(await storage.getAuthTokenStrict()).equals('token-a');
    check(await storage.vaultedServerIds()).not((it) => it.contains('a'));
  });

  test('a sign-in that chooses an account by id ends the park', () async {
    await configure(['a']);
    await storage.parkActiveServer(fromServerId: 'a');
    await storage.setActiveServerId('a');
    check(storage.isOpenWebUiParked).isFalse();
    check(PreferencesStore.getBool(PreferenceKeys.openWebUiParked)).isNull();
    check(await storage.getEffectiveActiveServerId()).equals('a');
  });

  test('a selection that cannot end the park reads the id it stored',
      () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.parkActiveServer(fromServerId: 'a');
    // Read while parked, which caches that none is active.
    check(await storage.getActiveServerId()).isNull();
    PreferencesStore.debugOverride(
      PreferencesStore.instance,
      writeInterceptor: (store, key, value) async =>
          key == PreferenceKeys.openWebUiParked && value == null
          ? false
          : null,
    );

    await check(storage.setActiveServerId('b')).throws<StateError>();

    // The id landed, and a stored id wins over the park: what is read is
    // that id, not the none cached while parked.
    check(
      PreferencesStore.getString(PreferenceKeys.activeServerId),
    ).equals('b');
    check(await storage.getActiveServerId()).equals('b');
  });

  test('refuses to park an account that is no longer the active one',
      () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('b');
    await storage.saveAuthToken('token-b');

    await check(
      storage.parkActiveServer(fromServerId: 'a'),
    ).throws<StateError>();

    check(storage.isOpenWebUiParked).isFalse();
    check(await storage.getActiveServerId()).equals('b');
    check(await storage.getAuthTokenStrict()).equals('token-b');
  });

  test('every parked session is one a full sign-out revokes', () async {
    await configure(['a', 'b']);
    await storage.setActiveServerId('a');
    await storage.saveAuthToken('token-a');
    await storage.switchActiveServer(fromServerId: 'a', toServerId: 'b');
    await storage.saveAuthToken('token-b');
    await storage.parkActiveServer(fromServerId: 'b');

    // Nothing is active, so both sessions are inactive and vaulted: what
    // AuthStateManager.inactiveAccountSessions hands to the revocation that
    // follows a full sign-out.
    check(await storage.getActiveServerId()).isNull();
    final sessions = await storage.vaultedSessions();
    check(
      {for (final session in sessions) session.config.id: session.token},
    ).deepEquals({'a': 'token-a', 'b': 'token-b'});
  });
}

final class _KeychainRefused implements Exception {
  const _KeychainRefused(this.key);

  final String key;

  @override
  String toString() => 'Keychain refused $key';
}

/// Refuses writes to [refusedKey] while it is set, as a locked Keychain does.
final class _RefusingSecureStore extends InMemorySecureKeyValueStore {
  String? refusedKey;

  @override
  Future<void> write({required String key, required String? value}) {
    if (key == refusedKey) throw _KeychainRefused(key);
    return super.write(key: key, value: value);
  }
}
