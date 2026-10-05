// Upgrades from old installs, over the on-disk data those versions left.
//
// test/fixtures/legacy_install/v3.3.1/conduit_hive holds the Hive boxes of a
// v3.3.1 install (the last release before Hive left the preference path),
// written by hive_ce 2.14.0, the version v2.0.0 first shipped
// (test/fixtures/legacy_install/generate.sh rebuilds it). The app runs the
// same chain at startup (lib/main.dart): PersistenceMigrator, then
// HivePrefsMigrator, and later the sync engine's migrations: the outbound task
// queue first, then HiveCacheMigrator.
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/hive_prefs_migrator.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/persistence_migrator.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/hive_cache_migrator.dart';
import 'package:conduit_core/sync/outbox_task_queue_migrator.dart';
import 'package:drift/native.dart';
import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';

const _fixture = 'test/fixtures/legacy_install/v3.3.1/conduit_hive';

class _FixedClock implements SyncClock {
  @override
  int nowEpochSeconds() => 1700000000;
}

void main() {
  late Directory home;
  late InMemoryKeyValueStore prefs;
  late AppDatabase db;

  /// Opens the boxes the way the app's HiveBootstrap does.
  Future<HiveBoxes> openBoxes() async {
    Hive.init('${home.path}/conduit_hive');
    final opened = await Future.wait<Box<dynamic>>([
      Hive.openBox<dynamic>(HiveBoxNames.preferences),
      Hive.openBox<dynamic>(HiveBoxNames.caches),
      Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue),
      Hive.openBox<dynamic>(HiveBoxNames.metadata),
    ]);
    return HiveBoxes(
      preferences: opened[0],
      caches: opened[1],
      attachmentQueue: opened[2],
      metadata: opened[3],
    );
  }

  Future<void> runStartupChain(HiveBoxes boxes) async {
    await PersistenceMigrator(
      hiveBoxes: boxes,
      preferences: prefs,
    ).migrateIfNeeded();
    await HivePrefsMigrator(hiveBoxes: boxes).migrateIfNeeded();
    // The sync engine converts the queued sends before the caches, as here.
    await OutboxTaskQueueMigrator(
      db: db,
      hiveBoxes: boxes,
      chatLocks: ConversationLocks(),
      clock: _FixedClock(),
      resolveDefaultModel: () => 'llama3:8b',
    ).migrateIfNeeded();
    await HiveCacheMigrator(
      db: db,
      hiveBoxes: boxes,
      resolveActiveServerId: () async =>
          PreferencesStore.getString(PreferenceKeys.activeServerId),
    ).migrateIfNeeded();
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('legacy-install');
    prefs = InMemoryKeyValueStore();
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(prefs);
    PersistenceMigrator.debugResetMigrationComplete();
    HivePrefsMigrator.debugReset();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    await Hive.close();
    PreferencesStore.debugReset();
    PersistenceMigrator.debugResetMigrationComplete();
    HivePrefsMigrator.debugReset();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test(
    'a v3.3.1 install keeps its settings, caches and upload queue',
    () async {
      final target = Directory('${home.path}/conduit_hive')..createSync();
      for (final file in Directory(_fixture).listSync().whereType<File>()) {
        file.copySync('${target.path}/${file.uri.pathSegments.last}');
      }

      await runStartupChain(await openBoxes());

      // Preferences: Hive preferences_v1 → shared_preferences, types kept.
      check(PreferencesStore.getBool(PreferenceKeys.hiveToPrefsMigrationV1))
          .equals(true);
      check(PreferencesStore.getString(PreferenceKeys.activeServerId))
          .equals('server-a');
      check(PreferencesStore.getString(PreferenceKeys.themeMode))
          .equals('dark');
      check(PreferencesStore.getString(PreferenceKeys.themePalette))
          .equals('ocean');
      check(PreferencesStore.getString(PreferenceKeys.localeCode)).equals('de');
      check(PreferencesStore.getBool(PreferenceKeys.reviewerMode))
          .equals(false);
      // A key the current app no longer names is copied all the same.
      check(PreferencesStore.getBool('haptic_feedback')).equals(true);
      check(PreferencesStore.getDouble(PreferenceKeys.ttsSpeechRate))
          .equals(0.9);
      check(PreferencesStore.getInt(PreferenceKeys.voiceSilenceDuration))
          .equals(1500);
      check(PreferencesStore.getStringList(PreferenceKeys.pinnedModels))
          .isNotNull()
          .deepEquals(['llama3:8b', 'gpt-4o']);
      check(
        jsonDecode(
          PreferencesStore.getString(PreferenceKeys.serverFeatureAvailability)!,
        ),
      ).isA<Map<String, dynamic>>().deepEquals({
        'server-a': {'notes': true, 'channels': false},
      });
      final transportKey =
          '${PreferenceKeys.transportOptionsPrefix}:'
          '${base64Url.encode(utf8.encode('server-a'))}';
      check(jsonDecode(PreferencesStore.getString(transportKey)!))
          .isA<Map<String, dynamic>>()
          .deepEquals({'allowPolling': true, 'allowWebsocketOnly': false});

      // Caches: Hive caches_v1 → the active server's Drift app_cache; another
      // server's scoped value is dropped (re-fetchable).
      check(
        jsonDecode((await db.appCacheDao.getValue(HiveStoreKeys.localUser))!),
      ).isA<Map<String, dynamic>>().deepEquals({
        'id': 'user-1',
        'name': 'Legacy User',
      });
      check(await db.appCacheDao.getValue(HiveStoreKeys.localUserAvatar))
          .equals('/user.png');
      check(
        jsonDecode(
          (await db.appCacheDao.getValue(HiveStoreKeys.localBackendConfig))!,
        ),
      ).isA<Map<String, dynamic>>()['version'].equals('0.6.5');
      check(await db.appCacheDao.getValue(HiveStoreKeys.localModels))
          .isNotNull()
          .contains('llama3:8b');
      check(await db.appCacheDao.getValue(HiveStoreKeys.localTools)).isNull();

      // The pending upload survives, with its retry state.
      final uploads = await db.attachmentQueueDao.getAll();
      check(uploads.map((row) => row.id)).deepEquals(['att-1']);
      check(uploads.single.fileName).equals('photo.jpg');
      check(uploads.single.retryCount).equals(1);
    },
  );

  test('a send still queued in a v3.3.1 install is not lost', () async {
    final target = Directory('${home.path}/conduit_hive')..createSync();
    for (final file in Directory(_fixture).listSync().whereType<File>()) {
      file.copySync('${target.path}/${file.uri.pathSegments.last}');
    }
    final boxes = await openBoxes();
    // The user sent a message offline; it was still queued when they updated.
    await boxes.caches.put(HiveStoreKeys.taskQueue, <Map<String, dynamic>>[
      {
        'runtimeType': 'sendTextMessage',
        'id': 'queued-1',
        'conversationId': null,
        'text': 'Sent while offline',
        'attachments': <String>[],
        'toolIds': <String>['tool-a'],
        'status': 'queued',
      },
      {
        'runtimeType': 'sendTextMessage',
        'id': 'done-1',
        'conversationId': null,
        'text': 'Already delivered',
        'attachments': <String>[],
        'toolIds': <String>[],
        'status': 'succeeded',
      },
    ]);

    await runStartupChain(boxes);

    // Only the queued send becomes a local chat, with its outbox operations.
    final chats = await db.select(db.chats).get();
    check(chats).length.equals(1);
    final messages = await db.messagesDao.getForChat(chats.single.id);
    check(messages.where((m) => m.role == 'user').map((m) => m.content))
        .deepEquals(['Sent while offline']);
    final ops = await db.outboxDao.pendingForChat(chats.single.id);
    check(ops.map((op) => op.kind))
        .deepEquals(['createChat', 'requestCompletion']);

    // The queue is consumed, and the rest of the install still migrates.
    check(boxes.caches.get(HiveStoreKeys.taskQueue)).isNull();
    check(
      await db.syncMetaDao.getValue(OutboxTaskQueueMigrator.migratedFlagKey),
    ).equals('1');
    check(PreferencesStore.getString(PreferenceKeys.themeMode)).equals('dark');
    check(await db.attachmentQueueDao.getAll()).length.equals(1);
  });

  test('the chain is idempotent across launches', () async {
    final target = Directory('${home.path}/conduit_hive')..createSync();
    for (final file in Directory(_fixture).listSync().whereType<File>()) {
      file.copySync('${target.path}/${file.uri.pathSegments.last}');
    }
    await runStartupChain(await openBoxes());
    await Hive.close();

    // The user changes a setting in the new version, then relaunches.
    await PreferencesStore.put(PreferenceKeys.themeMode, 'light');
    PersistenceMigrator.debugResetMigrationComplete();
    HivePrefsMigrator.debugReset();
    await runStartupChain(await openBoxes());

    check(PreferencesStore.getString(PreferenceKeys.themeMode)).equals('light');
    check(await db.attachmentQueueDao.getAll()).length.equals(1);
  });

  test('a pre-Hive install (before v2.0.0) moves its queues forward', () async {
    // Before v2.0.0 everything lived in shared_preferences, with the caches
    // and queues as JSON strings; there is no conduit_hive directory yet.
    prefs = InMemoryKeyValueStore({
      PreferenceKeys.themeMode: 'dark',
      PreferenceKeys.activeServerId: 'server-a',
      HiveStoreKeys.localConversations: jsonEncode([
        {'id': 'chat-1', 'title': 'Old chat'},
      ]),
      LegacyPreferenceKeys.attachmentUploadQueue: jsonEncode([
        {
          'id': 'att-0',
          'filePath': '/tmp/a.png',
          'fileName': 'a.png',
          'fileSize': 10,
          'status': 'pending',
          'retryCount': 0,
          'enqueuedAt': '2025-08-01T00:00:00.000Z',
        },
      ]),
    });
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(prefs);

    final boxes = await openBoxes();
    await runStartupChain(boxes);

    // Preferences stay where they were; the queues moved on.
    check(PreferencesStore.getString(PreferenceKeys.themeMode)).equals('dark');
    check(prefs.getString(LegacyPreferenceKeys.attachmentUploadQueue)).isNull();
    check(boxes.metadata.get(HiveStoreKeys.migrationVersion)).equals(1);
    check(boxes.caches.get(HiveStoreKeys.localConversations))
        .isA<List<dynamic>>()
        .length
        .equals(1);
    final uploads = await db.attachmentQueueDao.getAll();
    check(uploads.map((row) => row.id)).deepEquals(['att-0']);
  });
}
