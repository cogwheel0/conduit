import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/sync/hive_cache_migrator.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tempDir;
  late Box<dynamic> preferences;
  late Box<dynamic> caches;
  late Box<dynamic> attachmentQueue;
  late Box<dynamic> metadata;

  HiveBoxes boxes() => HiveBoxes(
    preferences: preferences,
    caches: caches,
    attachmentQueue: attachmentQueue,
    metadata: metadata,
  );

  HiveCacheMigrator migrator({String? activeServerId = 'server-a'}) =>
      HiveCacheMigrator(
        db: db,
        hiveBoxes: boxes(),
        resolveActiveServerId: () async => activeServerId,
      );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('hive-cache-migrator-test');
    Hive.init(tempDir.path);
    preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    attachmentQueue = await Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue);
    metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);
  });

  tearDown(() async {
    await db.close();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('migrates active-server caches into Drift app_cache', () async {
    // Unwrapped (global) string values.
    await caches.put(
      HiveStoreKeys.localUser,
      jsonEncode({'id': 'u1', 'name': 'User'}),
    );
    await caches.put(HiveStoreKeys.localUserAvatar, 'https://x/a.png');
    // Server-scoped wrapped values for the active server.
    await caches.put(HiveStoreKeys.localBackendConfig, {
      'data': {'version': '1.2.3'},
      'serverId': 'server-a',
    });
    await caches.put(HiveStoreKeys.localModels, {
      'data': [
        {'id': 'm1'},
      ],
      'serverId': 'server-a',
    });
    // A different server's scoped value must be skipped.
    await caches.put(HiveStoreKeys.localTools, {
      'data': [
        {'id': 't1'},
      ],
      'serverId': 'server-b',
    });

    await migrator().migrateIfNeeded();

    check(
      await db.appCacheDao.getValue(HiveStoreKeys.localUser),
    ).equals(jsonEncode({'id': 'u1', 'name': 'User'}));
    check(
      await db.appCacheDao.getValue(HiveStoreKeys.localUserAvatar),
    ).equals('https://x/a.png');
    check(
      jsonDecode(
            (await db.appCacheDao.getValue(HiveStoreKeys.localBackendConfig))!,
          )
          as Map,
    ).deepEquals({'version': '1.2.3'});
    check(
      jsonDecode((await db.appCacheDao.getValue(HiveStoreKeys.localModels))!)
          as List,
    ).deepEquals([
      {'id': 'm1'},
    ]);
    // Other server's cache dropped.
    check(await db.appCacheDao.getValue(HiveStoreKeys.localTools)).isNull();

    // Flag set; migrated Hive keys deleted.
    check(await db.syncMetaDao.getValue('hive_caches_migrated')).equals('1');
    check(caches.containsKey(HiveStoreKeys.localUser)).isFalse();
    check(caches.containsKey(HiveStoreKeys.localBackendConfig)).isFalse();
  });

  test('is gated: a second run does not re-import deleted keys', () async {
    await caches.put(HiveStoreKeys.localUserAvatar, 'https://x/a.png');
    await migrator().migrateIfNeeded();

    // Simulate the user clearing the avatar after migration; a second run must
    // not resurrect it from Hive (gate already set).
    await db.appCacheDao.deleteKey(HiveStoreKeys.localUserAvatar);
    await caches.put(HiveStoreKeys.localUserAvatar, 'https://x/a.png');
    await migrator().migrateIfNeeded();

    check(
      await db.appCacheDao.getValue(HiveStoreKeys.localUserAvatar),
    ).isNull();
  });
}
