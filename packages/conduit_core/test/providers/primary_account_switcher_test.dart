import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/providers/primary_account_switcher.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Parks through storage alone; the real boundary is covered by the park
/// and account-switch tests.
final class _Auth extends AuthStateManager {
  _Auth(this.storage);

  final OptimizedStorageService storage;
  int parks = 0;

  /// Runs while Open WebUI parks, as another action of the user's may.
  Future<void> Function()? duringPark;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'owui');

  @override
  Future<void> parkActiveAccount() async {
    parks++;
    await duringPark?.call();
    await storage.parkActiveServer(
      fromServerId: await storage.getEffectiveActiveServerId(),
    );
  }
}

final class _Accounts extends OpenWebUiAccountsController {
  _Accounts(super.ref, this.storage);

  final OptimizedStorageService storage;
  final List<String> switches = <String>[];
  bool failSwitches = false;

  @override
  Future<OpenWebUiAccountChangeResult> switchTo(
    String accountId, {
    bool force = false,
  }) async {
    if (failSwitches) throw StateError('switch failed');
    switches.add(accountId);
    await storage.switchActiveServer(toServerId: accountId);
    return OpenWebUiAccountChangeResult.done;
  }
}

void main() {
  late Directory tempDir;
  late OptimizedStorageService storage;
  late WorkerManager workers;
  late InMemorySecureKeyValueStore secure;
  late ProviderContainer container;
  late _Auth auth;
  late _Accounts accounts;
  var replying = false;

  const server = LibreChatServer(baseUrl: 'https://chat.example.com');
  final libreChatAccount = LibreChatAccount.forUser(
    server,
    const LibreChatUser(id: 'lc-user', name: 'Dev'),
  );

  setUp(() async {
    replying = false;
    tempDir = await Directory.systemTemp.createTemp('primary-switch-test');
    Hive.init(tempDir.path);
    final boxes = HiveBoxes(
      preferences: await Hive.openBox<dynamic>(HiveBoxNames.preferences),
      caches: await Hive.openBox<dynamic>(HiveBoxNames.caches),
      attachmentQueue: await Hive.openBox<dynamic>(
        HiveBoxNames.attachmentQueue,
      ),
      metadata: await Hive.openBox<dynamic>(HiveBoxNames.metadata),
    );
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    workers = WorkerManager(maxConcurrentTasks: 1);
    secure = InMemorySecureKeyValueStore();
    storage = OptimizedStorageService(
      secureStorage: InMemorySecureKeyValueStore(),
      boxes: boxes,
      workerManager: workers,
    );
    await storage.saveServerConfigs(const [
      ServerConfig(id: 'owui', name: 'owui', url: 'https://owui.example.com'),
    ]);
    await storage.setActiveServerId('owui');
    await storage.saveAuthToken('owui-token');
    await PreferencesStore.put(
      'preferred_backend_v1',
      PreferredBackend.owui.name,
    );

    container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(secure),
        optimizedStorageServiceProvider.overrideWithValue(storage),
        workerManagerProvider.overrideWithValue(workers),
        authStateManagerProvider.overrideWith(() => auth = _Auth(storage)),
        openWebUiAccountsControllerProvider.overrideWith(
          (ref) => accounts = _Accounts(ref, storage),
        ),
        accountChangeReplyGuardProvider.overrideWithValue(() => replying),
        accountChangeStopRepliesProvider.overrideWithValue(() {}),
      ],
    );
    await container.read(authStateManagerProvider.future);
    container.read(openWebUiAccountsControllerProvider);
    await container
        .read(libreChatRegistryProvider.notifier)
        .save(libreChatAccount);
  });

  tearDown(() async {
    container.dispose();
    workers.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  PrimaryAccountSwitcher switcher() =>
      container.read(primaryAccountSwitcherProvider);

  test('to LibreChat parks Open WebUI with its session kept', () async {
    final result = await switcher().useLibreChat(libreChatAccount.id);
    check(result).equals(PrimarySwitchResult.done);
    check(auth.parks).equals(1);
    check(storage.isOpenWebUiParked).isTrue();
    check(await storage.vaultedServerIds()).contains('owui');
    check(container.read(preferredBackendProvider)).equals(
      PreferredBackend.libreChat,
    );
    check(container.read(primaryAccountProvider)).equals(
      PrimaryAccountRef(PrimaryAccountKind.libreChat, libreChatAccount.id),
    );
    check(PrimarySwitchIntent.read()).isNull();
  });

  test('back to Open WebUI takes its session up again', () async {
    await switcher().useLibreChat(libreChatAccount.id);
    final result = await switcher().useOpenWebUi('owui');
    check(result).equals(PrimarySwitchResult.done);
    check(accounts.switches).deepEquals(['owui']);
    check(storage.isOpenWebUiParked).isFalse();
    check(await storage.getAuthTokenStrict()).equals('owui-token');
    check(container.read(preferredBackendProvider)).equals(
      PreferredBackend.owui,
    );
    // LibreChat keeps its account in use for next time.
    check(container.read(activeLibreChatAccountProvider)).isNotNull();
  });

  test('an unknown account is refused', () async {
    check(
      await switcher().useLibreChat('librechat:missing'),
    ).equals(PrimarySwitchResult.unknownAccount);
    check(auth.parks).equals(0);
  });

  test('an unknown Open WebUI account is refused up front', () async {
    await switcher().useLibreChat(libreChatAccount.id);
    check(
      await switcher().useOpenWebUi('missing'),
    ).equals(PrimarySwitchResult.unknownAccount);
    check(accounts.switches).isEmpty();
    check(container.read(preferredBackendProvider)).equals(
      PreferredBackend.libreChat,
    );
    check(PrimarySwitchIntent.read()).isNull();
  });

  test('switches run in the order they were asked for', () async {
    final toLibreChat = switcher().useLibreChat(libreChatAccount.id);
    final back = switcher().useOpenWebUi('owui');
    check(await toLibreChat).equals(PrimarySwitchResult.done);
    check(await back).equals(PrimarySwitchResult.done);
    check(container.read(primaryAccountProvider)).equals(
      const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui'),
    );
    check(storage.isOpenWebUiParked).isFalse();
  });

  test('a reply being written blocks the switch until forced', () async {
    replying = true;
    check(
      await switcher().useLibreChat(libreChatAccount.id),
    ).equals(PrimarySwitchResult.blockedByActiveReply);
    check(storage.isOpenWebUiParked).isFalse();
    check(
      await switcher().useLibreChat(libreChatAccount.id, force: true),
    ).equals(PrimarySwitchResult.done);
  });

  test('signing in to another LibreChat account while one is in charge '
      'still asks before stopping a reply', () async {
    await switcher().useLibreChat(libreChatAccount.id);
    final other = await container
        .read(libreChatAccountsProvider)
        .saveSignedIn(
          server: server,
          session: const LibreChatSession(
            accessToken: 'b',
            user: LibreChatUser(id: 'lc-other', name: 'Other'),
          ),
          activate: false,
        );
    // Saved, but the account in charge has not changed under the guard.
    check(container.read(primaryAccountProvider)).equals(
      PrimaryAccountRef(PrimaryAccountKind.libreChat, libreChatAccount.id),
    );
    replying = true;
    check(
      await switcher().useLibreChat(other.id),
    ).equals(PrimarySwitchResult.blockedByActiveReply);
    check(
      container.read(activeLibreChatAccountProvider)?.id,
    ).equals(libreChatAccount.id);
  });

  test('a switch cut short is finished at the next start', () async {
    // Crashed after parking, before LibreChat took over.
    await PrimarySwitchIntent(
      from: const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui'),
      to: PrimaryAccountRef(PrimaryAccountKind.libreChat, libreChatAccount.id),
    ).write();
    await storage.parkActiveServer(fromServerId: 'owui');

    await switcher().recoverAtStart();
    check(container.read(preferredBackendProvider)).equals(
      PreferredBackend.libreChat,
    );
    check(PrimarySwitchIntent.read()).isNull();
  });

  test('a switch whose backend does not reach disk is finished at the next '
      'start', () async {
    final prefs = PreferencesStore.instance;
    var failBackend = true;
    PreferencesStore.debugOverride(
      prefs,
      writeInterceptor: (store, key, value) async =>
          failBackend && key == PreferenceKeys.preferredBackend ? false : null,
    );

    await check(
      switcher().useLibreChat(libreChatAccount.id),
    ).throws<StateError>();
    // Left for the next start, which would otherwise read Open WebUI as the
    // backend in charge and take it back.
    check(PrimarySwitchIntent.read()).isNotNull();

    failBackend = false;
    await switcher().recoverAtStart();
    check(
      PreferencesStore.getString(PreferenceKeys.preferredBackend),
    ).equals(PreferredBackend.libreChat.name);
    check(storage.isOpenWebUiParked).isTrue();
    check(PrimarySwitchIntent.read()).isNull();
  });

  test('a park cut short before the account was cleared is finished at the '
      'next start', () async {
    await PrimarySwitchIntent(
      from: const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui'),
      to: PrimaryAccountRef(PrimaryAccountKind.libreChat, libreChatAccount.id),
    ).write();
    // Crashed after the park had filed the session away and set the flag,
    // before it cleared the account's id, which still wins over the park.
    await storage.parkActiveServer(fromServerId: 'owui');
    await PreferencesStore.putChecked(PreferenceKeys.activeServerId, 'owui');
    storage.clearCache();
    check(await storage.getEffectiveActiveServerId()).equals('owui');
    check(await storage.getAuthTokenStrict()).isNull();

    await switcher().recoverAtStart();
    check(await storage.getEffectiveActiveServerId()).isNull();
    check(PrimarySwitchIntent.read()).isNull();

    // Nothing was lost on the way: going back takes the session up again.
    await switcher().useOpenWebUi('owui');
    check(await storage.getAuthTokenStrict()).equals('owui-token');
  });

  test('a cut-short switch to a gone Open WebUI account is undone', () async {
    await switcher().useLibreChat(libreChatAccount.id);
    await PrimarySwitchIntent(
      from: PrimaryAccountRef(
        PrimaryAccountKind.libreChat,
        libreChatAccount.id,
      ),
      to: const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'removed'),
    ).write();

    await switcher().recoverAtStart();
    check(accounts.switches).isEmpty();
    check(container.read(preferredBackendProvider)).equals(
      PreferredBackend.libreChat,
    );
    check(PrimarySwitchIntent.read()).isNull();
  });

  test('a parked Open WebUI with nothing in charge is taken back', () async {
    await storage.parkActiveServer(fromServerId: 'owui');
    await container.read(libreChatRegistryProvider.notifier).setActive(null);

    await switcher().recoverAtStart();
    check(storage.isOpenWebUiParked).isFalse();
    check(accounts.switches).deepEquals(['owui']);
    check(container.read(preferredBackendProvider)).equals(
      PreferredBackend.owui,
    );
  });

  test('an account signed out of while Open WebUI parks is not switched to',
      () async {
    auth.duringPark = () => container
        .read(libreChatRegistryProvider.notifier)
        .remove(libreChatAccount.id);

    final result = await switcher().useLibreChat(libreChatAccount.id);

    check(result).equals(PrimarySwitchResult.unknownAccount);
    // Open WebUI is back in charge, with its session.
    check(storage.isOpenWebUiParked).isFalse();
    check(await storage.getAuthTokenStrict()).equals('owui-token');
    check(container.read(preferredBackendProvider)).equals(
      PreferredBackend.owui,
    );
    check(PrimarySwitchIntent.read()).isNull();
  });

  group('routing at startup', () {
    test('waits for a switch cut short to be finished', () async {
      await PrimarySwitchIntent(
        from: const PrimaryAccountRef(PrimaryAccountKind.openWebUi, 'owui'),
        to: PrimaryAccountRef(
          PrimaryAccountKind.libreChat,
          libreChatAccount.id,
        ),
      ).write();
      await storage.parkActiveServer(fromServerId: 'owui');

      check(container.read(primaryBootRecoveryPendingProvider)).isTrue();
      await container.read(primaryBootRecoveryProvider.future);
      check(container.read(primaryBootRecoveryPendingProvider)).isFalse();
      check(container.read(preferredBackendProvider)).equals(
        PreferredBackend.libreChat,
      );
      check(PrimarySwitchIntent.read()).isNull();
    });

    test('does not wait when nothing was left unsettled', () {
      check(container.read(primaryBootRecoveryPendingProvider)).isFalse();
      // Nothing to finish, so nothing runs.
      check(container.read(primaryBootRecoveryProvider.exists)).isFalse();
    });

    test('goes on when the recovery fails', () async {
      await storage.parkActiveServer(fromServerId: 'owui');
      await container.read(libreChatRegistryProvider.notifier).setActive(null);
      accounts.failSwitches = true;

      check(container.read(primaryBootRecoveryPendingProvider)).isTrue();
      await container.read(primaryBootRecoveryProvider.future);
      check(container.read(primaryBootRecoveryPendingProvider)).isFalse();
    });
  });
}
