import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'daos/chats_dao.dart';
import 'daos/folders_dao.dart';
import 'daos/messages_dao.dart';
import 'daos/outbox_dao.dart';
import 'daos/search_dao.dart';
import 'daos/sync_meta_dao.dart';
import 'fts/fts_ddl.dart';
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
  daos: [ChatsDao, MessagesDao, FoldersDao, SyncMetaDao, OutboxDao, SearchDao],
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
  int get schemaVersion => 4;

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
      if (from < 3) {
        // Phase 2 write path: the §7.3 crash-heal fingerprint column and the
        // per-chat FIFO claim-scan index. Both idempotent (the v1->v2 heal
        // above already runs _createIndexes, which now also creates the
        // chat_seq index).
        await m.addColumn(outboxOps, outboxOps.contentHash);
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_outbox_chat_seq '
          'ON outbox_ops (chat_id, seq);',
        );
      }
      if (from < 4) {
        // Phase 4 FTS5 search (CDT-RFC-001 §10). Create the vtable + triggers
        // on existing installs, then backfill IMMEDIATELY for installs already
        // past their first sync (their post-first-sync population gate already
        // fired and won't re-fire). All idempotent.
        await _createFts();
        await customStatement(kBackfillMessages);
        await customStatement(kBackfillTitles);
        await syncMetaDao.setValue(kFtsBuiltKey, '1');
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
    // Per-chat FIFO claim scans (`claimNextRunnable` head check, §7.2).
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_outbox_chat_seq '
      'ON outbox_ops (chat_id, seq);',
    );
  }

  /// Creates the FTS5 vtable + the six maintenance triggers (CDT-RFC-001
  /// Phase 4 §A/§C). All DDL uses IF NOT EXISTS, so this is safe to call on
  /// every open and cheap. Idempotent.
  Future<void> _createFts() async {
    await customStatement(kCreateChatFts);
    for (final trigger in kChatFtsTriggers) {
      await customStatement(trigger);
    }
  }

  /// Post-first-sync FTS population (CDT-RFC-001 Phase 4 §E): gated,
  /// idempotent, and safe to re-run on failure.
  ///
  ///  1. ensures the vtable + triggers exist (idempotent [_createFts]);
  ///  2. returns immediately if the dedicated `fts_built` flag is already set;
  ///  3. otherwise backfills BOTH sources (message content + non-deleted chat
  ///     titles) in ONE transaction, then sets the flag.
  ///
  /// The flag is dedicated (separate from `hive_cache_purged`) so a failed
  /// backfill leaves it unset and retries on the next sync cycle. This method
  /// MUST be invoked off the first-interactive-render path (the conversation
  /// list already streams from `watchChatList` before this runs — §10.6).
  Future<void> buildFtsIfNeeded() async {
    await _createFts();
    final built = await syncMetaDao.getValue(kFtsBuiltKey);
    if (built == '1') return;
    await transaction(() async {
      await customStatement(kBackfillMessages);
      await customStatement(kBackfillTitles);
      await syncMetaDao.setValue(kFtsBuiltKey, '1');
    });
  }
}
