import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/persistence/conversation_store.dart';
import 'package:conduit/core/persistence/database/app_database.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/persistence_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  setUp(() async {
    PersistenceMigrator.resetForTests();
    tempDir = await Directory.systemTemp.createTemp('conduit_hive_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<HiveBoxes> openBoxes() async {
    final preferences = await Hive.openBox<dynamic>('prefs_test');
    final caches = await Hive.openBox<dynamic>('caches_test');
    final attachmentQueue = await Hive.openBox<dynamic>('attach_test');
    final metadata = await Hive.openBox<dynamic>('metadata_test');
    return HiveBoxes(
      preferences: preferences,
      caches: caches,
      attachmentQueue: attachmentQueue,
      metadata: metadata,
    );
  }

  group('PersistenceMigrator v2 (Hive blobs → SQLite)', () {
    test('migrates per-conversation blobs and deletes the source keys',
        () async {
      final boxes = await openBoxes();
      final convA = _conversation(id: 'a', title: 'Alpha', messages: [
        _message(id: 'a-m1', content: 'hello'),
      ]);
      final convB = _conversation(id: 'b', title: 'Beta');
      await boxes.caches.put('chat_history_a', jsonEncode(convA.toJson()));
      await boxes.caches.put('chat_history_b', jsonEncode(convB.toJson()));
      // Pre-set v1 so the SharedPreferences→Hive step is skipped.
      await boxes.metadata.put('migration_version', 1);

      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final migrator = PersistenceMigrator(hiveBoxes: boxes, database: db);

      await migrator.migrateIfNeeded();

      check(boxes.metadata.get('migration_version')).equals(2);
      check(boxes.caches.containsKey('chat_history_a')).isFalse();
      check(boxes.caches.containsKey('chat_history_b')).isFalse();

      final store = ConversationStore(db);
      final reloadedA = await store.getConversation('a');
      final reloadedB = await store.getConversation('b');
      check(reloadedA).isNotNull();
      check(reloadedA!.title).equals('Alpha');
      check(reloadedA.messages.single.content).equals('hello');
      check(reloadedB).isNotNull();
      check(reloadedB!.title).equals('Beta');
    });

    test('picks up conversations only present in the legacy list-blob',
        () async {
      final boxes = await openBoxes();
      final conv = _conversation(id: 'list-only', title: 'From list');
      await boxes.caches.put(
        'local_conversations',
        jsonEncode([conv.toJson()]),
      );
      await boxes.metadata.put('migration_version', 1);

      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      await PersistenceMigrator(hiveBoxes: boxes, database: db)
          .migrateIfNeeded();

      final reloaded =
          await ConversationStore(db).getConversation('list-only');
      check(reloaded).isNotNull();
      check(reloaded!.title).equals('From list');
    });

    test('a corrupted blob does not abort the rest of the migration',
        () async {
      final boxes = await openBoxes();
      await boxes.caches.put('chat_history_bad', '{not valid json');
      final good = _conversation(id: 'good', title: 'Good');
      await boxes.caches.put('chat_history_good', jsonEncode(good.toJson()));
      await boxes.metadata.put('migration_version', 1);

      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      await PersistenceMigrator(hiveBoxes: boxes, database: db)
          .migrateIfNeeded();

      final store = ConversationStore(db);
      check(await store.getConversation('good')).isNotNull();
      check(await store.getConversation('bad')).isNull();
      check(boxes.metadata.get('migration_version')).equals(2);
    });

    test('rerun is a no-op when version is already 2', () async {
      final boxes = await openBoxes();
      await boxes.caches.put(
        'chat_history_left-over',
        jsonEncode(_conversation(id: 'left-over').toJson()),
      );
      await boxes.metadata.put('migration_version', 2);

      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      await PersistenceMigrator(hiveBoxes: boxes, database: db)
          .migrateIfNeeded();

      // Existing key remains untouched (since we declared we're already on v2).
      check(boxes.caches.containsKey('chat_history_left-over')).isTrue();
      check(await ConversationStore(db).getConversation('left-over')).isNull();
    });
  });
}

Conversation _conversation({
  required String id,
  String title = 'untitled',
  List<ChatMessage> messages = const [],
}) {
  return Conversation(
    id: id,
    title: title,
    createdAt: DateTime(2026, 4, 1),
    updatedAt: DateTime(2026, 4, 1),
    messages: messages,
  );
}

ChatMessage _message({
  required String id,
  String role = 'user',
  String content = '',
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    timestamp: DateTime(2026, 4, 1),
  );
}
