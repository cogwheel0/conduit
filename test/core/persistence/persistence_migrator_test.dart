import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/persistence_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<dynamic> preferences;
  late Box<dynamic> caches;
  late Box<dynamic> attachmentQueue;
  late Box<dynamic> metadata;

  HiveBoxes hiveBoxes() {
    return HiveBoxes(
      preferences: preferences,
      caches: caches,
      attachmentQueue: attachmentQueue,
      metadata: metadata,
    );
  }

  Future<void> migrate() {
    return PersistenceMigrator(hiveBoxes: hiveBoxes()).migrateIfNeeded();
  }

  void checkSharedPreferencesRemoved(
    SharedPreferences prefs,
    Iterable<String> keys,
  ) {
    for (final key in keys) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PersistenceMigrator.debugResetMigrationComplete();
    tempDir = await Directory.systemTemp.createTemp(
      'persistence-migrator-test',
    );
    Hive.init(tempDir.path);
    preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    attachmentQueue = await Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue);
    metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);
  });

  tearDown(() async {
    PersistenceMigrator.debugResetMigrationComplete();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'migrates legacy caches/queues into Hive but leaves preferences in '
    'shared_preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final conversations = [
        {
          'id': 'conversation-1',
          'title': 'First conversation',
          'updated_at': 1710000000,
        },
        {
          'id': 'conversation-2',
          'title': 'Second conversation',
          'folder_id': 'folder-1',
        },
      ];
      final folders = [
        {'id': 'folder-1', 'name': 'Work'},
      ];
      final attachmentUploads = [
        {'id': 'upload-1', 'path': '/tmp/example.txt', 'mimeType': 'text/plain'},
      ];
      final tasks = [
        {'id': 'task-1', 'type': 'chat-sync', 'attempt': 2},
      ];

      // Preferences are NO LONGER migrated to Hive — shared_preferences is the
      // live store for them again.
      await prefs.setBool(PreferenceKeys.reduceMotion, true);
      await prefs.setString(PreferenceKeys.defaultModel, 'gpt-4.1');

      await prefs.setString(
        HiveStoreKeys.localConversations,
        jsonEncode(conversations),
      );
      await prefs.setString(HiveStoreKeys.localFolders, jsonEncode(folders));
      await prefs.setString(
        LegacyPreferenceKeys.attachmentUploadQueue,
        jsonEncode(attachmentUploads),
      );
      await prefs.setString(LegacyPreferenceKeys.taskQueue, jsonEncode(tasks));

      await migrate();

      // Caches/queues still migrate into Hive (they move to Drift in PR-2).
      check(
        caches.get(HiveStoreKeys.localConversations) as List<dynamic>,
      ).deepEquals(conversations);
      check(
        caches.get(HiveStoreKeys.localFolders) as List<dynamic>,
      ).deepEquals(folders);
      check(
        attachmentQueue.get(HiveStoreKeys.attachmentQueueEntries)
            as List<dynamic>,
      ).deepEquals(attachmentUploads);
      check(
        caches.get(HiveStoreKeys.taskQueue) as List<dynamic>,
      ).deepEquals(tasks);
      check(metadata.get(HiveStoreKeys.migrationVersion)).equals(1);

      // Preferences are neither copied into Hive nor removed from prefs.
      check(preferences.containsKey(PreferenceKeys.reduceMotion)).isFalse();
      check(preferences.containsKey(PreferenceKeys.defaultModel)).isFalse();
      check(prefs.getBool(PreferenceKeys.reduceMotion)).equals(true);
      check(prefs.getString(PreferenceKeys.defaultModel)).equals('gpt-4.1');

      // Only the legacy cache/queue keys are removed from shared_preferences.
      checkSharedPreferencesRemoved(prefs, [
        HiveStoreKeys.localConversations,
        HiveStoreKeys.localFolders,
        LegacyPreferenceKeys.attachmentUploadQueue,
        LegacyPreferenceKeys.taskQueue,
      ]);
    },
  );

  test('empty SharedPreferences still records migration version', () async {
    await migrate();

    check(preferences.isEmpty).isTrue();
    check(caches.isEmpty).isTrue();
    check(attachmentQueue.isEmpty).isTrue();
    check(metadata.get(HiveStoreKeys.migrationVersion)).equals(1);
  });

  test(
    'malformed cache JSON is skipped while valid cache JSON migrates',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final folders = [
        {'id': 'folder-1', 'name': 'Recovered folder'},
      ];

      await prefs.setString(HiveStoreKeys.localConversations, '{not json');
      await prefs.setString(HiveStoreKeys.localFolders, jsonEncode(folders));

      await migrate();

      check(caches.get(HiveStoreKeys.localConversations)).isNull();
      check(
        caches.get(HiveStoreKeys.localFolders) as List<dynamic>,
      ).deepEquals(folders);
      check(metadata.get(HiveStoreKeys.migrationVersion)).equals(1);
      checkSharedPreferencesRemoved(prefs, [
        HiveStoreKeys.localConversations,
        HiveStoreKeys.localFolders,
      ]);
    },
  );

  test('second migrateIfNeeded call leaves migrated data unchanged', () async {
    final prefs = await SharedPreferences.getInstance();
    final conversations = [
      {'id': 'conversation-1', 'title': 'Original conversation'},
    ];

    await prefs.setString(
      HiveStoreKeys.localConversations,
      jsonEncode(conversations),
    );

    await migrate();
    await prefs.setString(
      HiveStoreKeys.localConversations,
      jsonEncode([
        {'id': 'conversation-2', 'title': 'Reintroduced legacy cache'},
      ]),
    );
    await migrate();

    check(
      caches.get(HiveStoreKeys.localConversations) as List<dynamic>,
    ).deepEquals(conversations);
    check(metadata.get(HiveStoreKeys.migrationVersion)).equals(1);
  });
}
