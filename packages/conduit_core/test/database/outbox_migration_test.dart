import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('a v12 outbox keeps its work and takes a message delete', () async {
    final directory = Directory.systemTemp.createTempSync(
      'conduit_outbox_kind_migration',
    );
    final databaseFile = File(p.join(directory.path, 'migration.sqlite'));
    AppDatabase? database;
    try {
      database = AppDatabase(NativeDatabase(databaseFile));
      await database.customSelect('SELECT 1').get();
      // The v12 table: its kind check predates `deleteMessages`.
      await database.customStatement('DROP TABLE outbox_ops');
      await database.customStatement('''
CREATE TABLE outbox_ops (
  seq INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  chat_id TEXT NULL,
  payload TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NULL,
  last_error TEXT NULL,
  content_hash TEXT NULL,
  CHECK (kind IN ('createChat', 'updateChat', 'deleteChat', 'requestCompletion', 'folderUpsert', 'folderDelete', 'noteCreate', 'noteUpdate', 'noteDelete', 'notePin')),
  CHECK (status IN ('pending', 'inFlight', 'failed')),
  CHECK (attempts >= 0)
)
''');
      await database.customStatement(
        'CREATE INDEX idx_outbox_chat_seq ON outbox_ops (chat_id, seq)',
      );
      await database.customStatement(
        "INSERT INTO outbox_ops (kind, chat_id, attempts) "
        "VALUES ('updateChat', 'c1', 2)",
      );
      await database.customStatement('PRAGMA user_version = 12');
      await database.close();
      database = null;

      database = AppDatabase(NativeDatabase(databaseFile));
      final upgraded = database;
      await upgraded.transaction(
        () => upgraded.outboxDao.enqueue(
          kind: OutboxKind.deleteMessages,
          chatId: 'c1',
          payload: {
            kDeleteMessagesIdsKey: ['a1'],
          },
        ),
      );

      final ops = await upgraded.outboxDao.pendingForChat('c1');
      check([for (final op in ops) (op.kind, op.attempts)])
          .deepEquals([('updateChat', 2), ('deleteMessages', 0)]);
      final indexes = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'outbox_ops'",
          )
          .get();
      check([for (final row in indexes) row.read<String>('name')])
          .contains('idx_outbox_chat_seq');
    } finally {
      await database?.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });
}
