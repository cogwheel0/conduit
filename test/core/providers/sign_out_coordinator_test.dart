import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/auth/auth_state_manager.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/database_manager.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:drift/native.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

final class _ClearedAuthStateManager extends AuthStateManager {
  _ClearedAuthStateManager([this.outcome = FullAppDataClearOutcome.cleared]);

  final FullAppDataClearOutcome outcome;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated, token: 'session-token');

  @override
  Future<FullAppDataClearOutcome> logoutAndClearAppData({
    required bool keepServerDetails,
    required Future<void> Function() beforeClear,
  }) async {
    await beforeClear();
    return outcome;
  }
}

final class _EmptyDirectProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

final class _EmptyHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    PreferencesStore.debugReset();
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await PreferencesStore.ensureInitialized();
  });

  tearDown(PreferencesStore.debugReset);

  test('full-data sign-out purges the direct-local chat database', () async {
    var purgeCalls = 0;
    final container = ProviderContainer(
      overrides: [
        authStateManagerProvider.overrideWith(_ClearedAuthStateManager.new),
        directConnectionProfilesProvider.overrideWith(_EmptyDirectProfiles.new),
        hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
        directLocalDatabasePurgeProvider.overrideWithValue(() async {
          purgeCalls++;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authStateManagerProvider.future);
    await container.read(directConnectionProfilesProvider.future);
    container.read(hermesConfigProvider);
    final result = await container
        .read(signOutCoordinatorProvider)
        .signOut(keepServerDetails: true);

    check(result).equals(SignOutRequestResult.completed);
    check(purgeCalls).equals(1);
  });

  test(
    'WebView failure cannot skip an otherwise successful local-data purge',
    () async {
      check(
        classifyFullAppDataClearOutcome(
          completeLocalCleanup: false,
          clearAllAppData: true,
          durableAuthDataCleared: true,
        ),
      ).equals(
        FullAppDataClearOutcome.localDataClearedSessionCleanupIncomplete,
      );

      var purgeCalls = 0;
      final container = ProviderContainer(
        overrides: [
          authStateManagerProvider.overrideWith(
            () => _ClearedAuthStateManager(
              FullAppDataClearOutcome.localDataClearedSessionCleanupIncomplete,
            ),
          ),
          directConnectionProfilesProvider.overrideWith(
            _EmptyDirectProfiles.new,
          ),
          hermesConfigProvider.overrideWith(_EmptyHermesConfig.new),
          directLocalDatabasePurgeProvider.overrideWithValue(() async {
            purgeCalls++;
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(authStateManagerProvider.future);
      await container.read(directConnectionProfilesProvider.future);
      container.read(hermesConfigProvider);
      await container
          .read(signOutCoordinatorProvider)
          .signOut(keepServerDetails: true);

      check(purgeCalls).equals(1);
    },
  );

  test('direct-local purge reopens an empty on-device chat store', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'conduit_sign_out_direct_local',
    );
    final manager = DatabaseManager(
      databaseDirectory: () async => tempDir,
      openDatabase: (fileName) => AppDatabase(
        NativeDatabase(File(p.join(tempDir.path, '$fileName.sqlite'))),
      ),
    );
    addTearDown(() async {
      await manager.closeActive();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final container = ProviderContainer(
      overrides: [
        directLocalDatabaseManagerProvider.overrideWithValue(manager),
      ],
    );
    addTearDown(container.dispose);

    final database = manager.openForServerId(kDirectLocalDatabaseId);
    await database.chatsDao.upsertLocalOnlyChat(
      rows: ChatBlobMapper.blobToRows(
        chatId: 'device-chat',
        blob: const <String, dynamic>{
          'title': 'Device chat',
          'history': <String, dynamic>{
            'messages': <String, dynamic>{},
            'currentId': null,
          },
        },
        title: 'Device chat',
        folderId: null,
        pinned: false,
        archived: false,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    check(await database.chatsDao.getChat('device-chat')).isNotNull();

    await container.read(directLocalDatabasePurgeProvider)();
    final reopened = manager.openForServerId(kDirectLocalDatabaseId);

    check(await reopened.chatsDao.getChat('device-chat')).isNull();
  });
}
