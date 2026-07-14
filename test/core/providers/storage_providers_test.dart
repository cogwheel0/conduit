import 'dart:async';
import 'dart:io';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_manager.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/persistence_providers.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/storage_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/gated_close_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late AppDatabase database;
  late DatabaseManager databaseManager;
  late ProviderContainer container;
  late bool databaseOwnedByManager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');

    tempDirectory = await Directory.systemTemp.createTemp(
      'storage-providers-test',
    );
    Hive.init(tempDirectory.path);
    final boxes = HiveBoxes(
      preferences: await Hive.openBox<dynamic>(HiveBoxNames.preferences),
      caches: await Hive.openBox<dynamic>(HiveBoxNames.caches),
      attachmentQueue: await Hive.openBox<dynamic>(
        HiveBoxNames.attachmentQueue,
      ),
      metadata: await Hive.openBox<dynamic>(HiveBoxNames.metadata),
    );

    database = AppDatabase(NativeDatabase.memory());
    databaseOwnedByManager = false;
    databaseManager = DatabaseManager(
      databaseFileName: (serverId) => serverId,
      openDatabase: (_) {
        databaseOwnedByManager = true;
        return database;
      },
    );
    container = ProviderContainer(
      overrides: [
        hiveBoxesProvider.overrideWithValue(boxes),
        databaseManagerProvider.overrideWithValue(databaseManager),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    if (databaseOwnedByManager) {
      await databaseManager.closeActive();
    } else {
      await database.close();
    }
    PreferencesStore.debugReset();
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'one storage instance re-evaluates access and certification gates',
    () async {
      await database.appCacheDao.setValue(
        HiveStoreKeys.localUserAvatar,
        'avatar-a',
      );

      final storage = container.read(optimizedStorageServiceProvider);

      // Bootstrap permits the auth cache to restore before account ownership
      // has been certified.
      expect(await storage.getLocalUserAvatar(), 'avatar-a');

      container.read(openWebUiDatabaseAccessProvider.notifier).beginPurge();
      expect(await storage.getLocalUserAvatar(), isNull);
      expect(
        identical(container.read(optimizedStorageServiceProvider), storage),
        isTrue,
      );

      // Open access alone is insufficient: the active server must be the one
      // certified by the account-isolation coordinator.
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      expect(await storage.getLocalUserAvatar(), isNull);

      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set('server-b');
      expect(await storage.getLocalUserAvatar(), isNull);

      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set('server-a');
      expect(await storage.getLocalUserAvatar(), 'avatar-a');
      expect(
        identical(container.read(optimizedStorageServiceProvider), storage),
        isTrue,
      );

      container.read(openWebUiDatabaseAccessProvider.notifier).close();
      expect(await storage.getLocalUserAvatar(), isNull);

      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      expect(await storage.getLocalUserAvatar(), 'avatar-a');

      container.read(openWebUiCertifiedDatabaseServerProvider.notifier).clear();
      expect(await storage.getLocalUserAvatar(), isNull);
    },
  );

  test('cache writes wait for their owner and never cross servers', () async {
    final boxes = container.read(hiveBoxesProvider);
    container.dispose();
    if (databaseOwnedByManager) {
      await databaseManager.closeActive();
    } else {
      await database.close();
    }

    final opened = <String, List<GatedCloseDatabase>>{};
    databaseOwnedByManager = false;
    databaseManager = DatabaseManager(
      databaseFileName: (serverId) => serverId,
      openDatabase: (serverId) {
        final openedDatabase = GatedCloseDatabase.memory(failClose: false);
        opened.putIfAbsent(serverId, () => []).add(openedDatabase);
        database = openedDatabase;
        databaseOwnedByManager = true;
        return openedDatabase;
      },
    );
    container = ProviderContainer(
      overrides: [
        hiveBoxesProvider.overrideWithValue(boxes),
        databaseManagerProvider.overrideWithValue(databaseManager),
      ],
    );
    final storage = container.read(optimizedStorageServiceProvider);

    // Open A, then switch to B while A's close remains in flight.
    expect(await storage.getLocalUserAvatar(), isNull);
    final originalA = opened['server-a']!.single;
    final closeGate = Completer<void>();
    originalA.closeGate = closeGate;
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
    expect(await storage.getLocalUserAvatar(), isNull);

    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
    var writeCompleted = false;
    final write = storage
        .saveLocalUserAvatar('avatar-after-close')
        .whenComplete(() => writeCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(writeCompleted, isFalse);
    expect(opened['server-a']!.length, 1);

    closeGate.complete();
    await write;

    expect(opened['server-a']!.length, 2);
    expect(await storage.getLocalUserAvatar(), 'avatar-after-close');

    // Repeat the blocked switch, but change ownership to B before A's close
    // settles. The already-started A mutation must not be retargeted to B.
    final reopenedA = opened['server-a']!.last;
    final ownershipChangeGate = Completer<void>();
    reopenedA.closeGate = ownershipChangeGate;
    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
    expect(await storage.getLocalUserAvatar(), isNull);

    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-a');
    var staleWriteCompleted = false;
    final staleWrite = storage
        .saveLocalUserAvatar('must-remain-owned-by-a')
        .whenComplete(() => staleWriteCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(staleWriteCompleted, isFalse);

    await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-b');
    container
        .read(openWebUiCertifiedDatabaseServerProvider.notifier)
        .set('server-b');
    container.read(openWebUiDatabaseAccessProvider.notifier).open();
    ownershipChangeGate.complete();
    await staleWrite;

    expect(opened['server-a']!.length, 2);
    expect(await storage.getLocalUserAvatar(), isNull);
  });
}
