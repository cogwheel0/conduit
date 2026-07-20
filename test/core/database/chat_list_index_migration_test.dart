import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Minimal schema-version-6 fixture containing the two tables touched by the
/// production v6 -> current migration. The attachment table deliberately has
/// its pre-v8 shape so the later receipt-column migration is real as well.
final class _V6MigrationFixture extends GeneratedDatabase {
  _V6MigrationFixture(super.e);

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''
CREATE TABLE chats (
  id TEXT NOT NULL PRIMARY KEY,
  deleted INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
)
''');
      await customStatement('''
CREATE TABLE attachment_queue (
  id TEXT NOT NULL PRIMARY KEY,
  file_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  file_size INTEGER NOT NULL,
  mime_type TEXT,
  checksum TEXT,
  status TEXT NOT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  next_retry_at INTEGER,
  last_error TEXT,
  file_id TEXT,
  enqueued_at INTEGER NOT NULL
)
''');
    },
  );
}

/// A pre-attachment-queue fixture proves the v6 table creation and v8 column
/// addition do not both attempt to create the same receipt columns.
final class _V5MigrationFixture extends GeneratedDatabase {
  _V5MigrationFixture(super.e);

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''
CREATE TABLE chats (
  id TEXT NOT NULL PRIMARY KEY,
  deleted INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
)
''');
    },
  );
}

void main() {
  test(
    'v5 upgrade creates the current attachment receipt shape once',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'conduit_attachment_receipt_migration',
      );
      final databaseFile = File(p.join(directory.path, 'migration.sqlite'));
      AppDatabase? database;
      try {
        final v5 = _V5MigrationFixture(NativeDatabase(databaseFile));
        await v5.customSelect('SELECT 1').get();
        await v5.close();

        database = AppDatabase(NativeDatabase(databaseFile));
        await _expectChatListIndex(database);
      } finally {
        await database?.close();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    },
  );

  test('v6 upgrade creates the bounded chat-list index idempotently', () async {
    final directory = Directory.systemTemp.createTempSync(
      'conduit_chat_list_index_migration',
    );
    final databaseFile = File(p.join(directory.path, 'migration.sqlite'));
    AppDatabase? database;
    try {
      final v6 = _V6MigrationFixture(NativeDatabase(databaseFile));
      await v6.customSelect('SELECT 1').get();
      await v6.close();

      database = AppDatabase(NativeDatabase(databaseFile));
      await _expectChatListIndex(database);

      // Restore the genuine v6 table shape and version while deliberately
      // leaving the chat-list index in place. Reopening AppDatabase now runs
      // the production migration a second time; its IF NOT EXISTS is what is
      // under test, rather than a test-local CREATE INDEX statement.
      await database.customStatement(
        'DROP INDEX IF EXISTS attachment_queue_durable_key_unique',
      );
      await database.customStatement(
        'ALTER TABLE attachment_queue DROP COLUMN durable_key',
      );
      await database.customStatement(
        'ALTER TABLE attachment_queue DROP COLUMN receipt_held',
      );
      await database.customStatement('PRAGMA user_version = 6');
      await database.close();
      database = null;

      database = AppDatabase(NativeDatabase(databaseFile));
      await _expectChatListIndex(database);
    } finally {
      await database?.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });
}

Future<void> _expectChatListIndex(AppDatabase database) async {
  check(database.schemaVersion).equals(8);
  final indexRow = await database
      .customSelect(
        "SELECT sql FROM sqlite_master WHERE type = 'index' "
        "AND name = 'idx_chats_list_window'",
      )
      .getSingle();
  final normalizedSql = indexRow
      .read<String>('sql')
      .replaceAll(RegExp(r'\s+'), ' ');
  check(
    normalizedSql,
  ).contains('(deleted, pinned, archived, updated_at DESC, id ASC)');
  final attachmentColumns = await database
      .customSelect('PRAGMA table_info(attachment_queue)')
      .get();
  final columnNames = attachmentColumns
      .map((row) => row.read<String>('name'))
      .toSet();
  check(columnNames).contains('durable_key');
  check(columnNames).contains('receipt_held');
  final receiptIndex = await database
      .customSelect(
        "SELECT sql FROM sqlite_master WHERE type = 'index' "
        "AND name = 'attachment_queue_durable_key_unique'",
      )
      .getSingle();
  check(receiptIndex.read<String>('sql')).contains('durable_key');
}
