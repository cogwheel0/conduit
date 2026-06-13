import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'daos/chats_dao.dart';
import 'daos/folders_dao.dart';
import 'daos/messages_dao.dart';
import 'daos/sync_meta_dao.dart';
import 'tables/chats.dart';
import 'tables/folders.dart';
import 'tables/messages.dart';
import 'tables/outbox.dart';
import 'tables/sync_meta.dart';

part 'app_database.g.dart';

/// Conduit's per-server local database (CDT-RFC-001).
///
/// Phase 1: chats, messages, folders, and the (not yet drained) outbox join
/// the Phase 0 sync_meta table; schema version 2.
///
/// One database file exists per [ServerConfig]; lifecycle (open/close/delete
/// on server switch or removal) is owned by the Phase 1 DatabaseManager.
@DriftDatabase(
  tables: [SyncMeta, Chats, Messages, Folders, OutboxOps],
  daos: [ChatsDao, MessagesDao, FoldersDao, SyncMetaDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens the database file for [serverId] on a background isolate.
  ///
  /// This function is the single seam where at-rest encryption (SQLCipher)
  /// can be introduced later (CDT-RFC-001 D-08).
  factory AppDatabase.forServer(String serverId) {
    return AppDatabase(
      driftDatabase(
        name: serverId,
        native: DriftNativeOptions(
          databaseDirectory: getApplicationSupportDirectory,
        ),
      ),
    );
  }

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // Heals dev installs of the Phase 0 build whose v1 file has only
        // sync_meta.
        await m.createTable(chats);
        await m.createTable(messages);
        await m.createTable(folders);
        await m.createTable(outboxOps);
        await _createIndexes();
      }
    },
    beforeOpen: (details) async {
      // Required for the messages -> chats cascade.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Drift's `@TableIndex` cannot express DESC/partial indexes; create them
  /// by hand (CDT-RFC-001 §10).
  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_chat_created '
      'ON messages (chat_id, created_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_chats_updated_at '
      'ON chats (updated_at DESC);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_chats_dirty ON chats (dirty) '
      'WHERE dirty;',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_outbox_status '
      'ON outbox_ops (status, next_attempt_at);',
    );
  }
}
