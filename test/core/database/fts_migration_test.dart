import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/fts/fts_ddl.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A schemaVersion-1 database from the Phase 0 build: only sync_meta exists.
class _V1Database extends GeneratedDatabase {
  _V1Database(super.e);

  late final $SyncMetaTable syncMeta = $SyncMetaTable(this);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => [syncMeta];

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

/// A schemaVersion-3 database that owns ONLY the tables the Phase 4 backfill
/// reads from (chats, messages, sync_meta). It reuses the real generated table
/// classes from AppDatabase so the column names/types match exactly, and it
/// creates them WITHOUT the chat_fts vtable/triggers — reproducing a real
/// pre-Phase-4 install that has already synced. Reopening AppDatabase (v4) over
/// the same file drives onUpgrade(3, 4).
class _V3Database extends GeneratedDatabase {
  _V3Database(super.e);

  late final $ChatsTable chats = $ChatsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $SyncMetaTable syncMeta = $SyncMetaTable(this);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => [
    syncMeta,
    chats,
    messages,
  ];

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('conduit_fts_migration');
    dbFile = File(p.join(tempDir.path, 'mig.sqlite'));
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('onUpgrade 3->4 creates the vtable, triggers, and backfills', () async {
    // 1. Build a v3 install that already synced two chats with messages.
    final v3 = _V3Database(NativeDatabase(dbFile));
    await v3
        .into(v3.chats)
        .insert(
          ChatsCompanion.insert(
            id: 'c1',
            title: 'photosynthesis notes',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await v3
        .into(v3.chats)
        .insert(
          ChatsCompanion.insert(
            id: 'c2',
            title: 'deleted chat',
            createdAt: 1,
            updatedAt: 1,
            deleted: const Value(true),
          ),
        );
    await v3
        .into(v3.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'm1',
            chatId: 'c1',
            role: 'user',
            content: 'chlorophyll absorbs sunlight',
            createdAt: 1,
            orderIndex: 0,
            payload: '{}',
          ),
        );
    await v3
        .into(v3.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'm2',
            chatId: 'c2',
            role: 'user',
            content: 'ghostword should not backfill',
            createdAt: 1,
            orderIndex: 0,
            payload: '{}',
          ),
        );
    // Simulate a post-first-sync install (watermark advanced).
    await v3
        .into(v3.syncMeta)
        .insert(
          SyncMetaCompanion.insert(key: 'pull_watermark', value: '12345'),
        );
    await v3.close();

    // 2. Reopen as the real v4 AppDatabase -> onUpgrade(3, 4) runs.
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    // 3. The flag is set and the index is searchable across both sources.
    check(await db.syncMetaDao.getValue(kFtsBuiltKey)).equals('1');

    final titleHits = await db.searchDao.search('photosynthesis');
    check(titleHits.map((h) => h.chatId).toList()).deepEquals(['c1']);

    final bodyHits = await db.searchDao.search('chlorophyll');
    check(bodyHits.map((h) => h.chatId).toList()).deepEquals(['c1']);

    // 4. The deleted chat's title and messages are NOT backfilled.
    check(await db.searchDao.search('deleted')).isEmpty();
    check(await db.searchDao.search('ghostword')).isEmpty();
    final deletedFtsRows = await db
        .customSelect("SELECT count(*) AS n FROM chat_fts WHERE chat_id = 'c2'")
        .getSingle();
    check(deletedFtsRows.read<int>('n')).equals(0);

    // 5. Triggers are now live: a fresh message is auto-indexed.
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'm3',
            chatId: 'c1',
            role: 'user',
            content: 'mitochondria powerhouse',
            createdAt: 2,
            orderIndex: 1,
            payload: '{}',
          ),
        );
    check(await db.searchDao.search('mitochondria')).isNotEmpty();
  });

  test('onUpgrade 1->5 creates current tables and indexes once', () async {
    final v1 = _V1Database(NativeDatabase(dbFile));
    await v1.customSelect('SELECT 1').get();
    await v1.close();

    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final outboxColumns = await db
        .customSelect('PRAGMA table_info(outbox_ops)')
        .get();
    check(
      outboxColumns.map((row) => row.read<String>('name')).toList(),
    ).contains('content_hash');

    final noteTable = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='notes'",
        )
        .get();
    check(noteTable).isNotEmpty();

    final noteIndex = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='index' "
          "AND name='idx_notes_updated_at'",
        )
        .get();
    check(noteIndex).isNotEmpty();
  });

  test('fresh install creates FTS objects before first backfill', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    // Force the executor open + onCreate to run.
    await db.customSelect('SELECT 1').get();

    // Fresh installs create the vtable/triggers up front, while the expensive
    // backfill remains gated behind buildFtsIfNeeded().
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='chat_fts'",
        )
        .get();
    check(tables).isNotEmpty();
    check(await db.syncMetaDao.getValue(kFtsBuiltKey)).isNull();

    // buildFtsIfNeeded remains idempotent and marks the backfill complete.
    await db.buildFtsIfNeeded();
    final after = await db
        .customSelect("SELECT name FROM sqlite_master WHERE name='chat_fts'")
        .get();
    check(after).isNotEmpty();
    check(await db.syncMetaDao.getValue(kFtsBuiltKey)).equals('1');
  });
}
