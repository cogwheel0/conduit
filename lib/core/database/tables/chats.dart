import 'package:drift/drift.dart';

/// Chat envelope rows (CDT-RFC-001 §6 plus Phase 1 amendments A1/A2/A3/A5).
///
/// All timestamps are server epoch SECONDS stored as `int`; no `DateTime`
/// ever enters this table.
@DataClassName('ChatRow')
class Chats extends Table {
  /// Server uuid, or `local:<uuid>` pre-remap (D-10).
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get folderId => text().nullable()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  /// `history.currentId` from the blob.
  TextColumn get currentMessageId => text().nullable()();

  /// Epoch seconds, server clock.
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  /// Merge base; null = never synced.
  IntColumn get serverUpdatedAt => integer().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  /// Tombstone.
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get rawExtra => text().withDefault(const Constant('{}'))();

  // ---- Phase 1 amendments A1/A2/A3/A5 ----
  /// A1: unread-dot state; server `last_read_at` arrives only on LIST items;
  /// merge rule is `max(local, server)`, never lowered.
  IntColumn get lastReadAt => integer().nullable()();

  /// A2: `ChatResponse` envelope fields.
  TextColumn get shareId => text().nullable()();
  TextColumn get meta => text().withDefault(const Constant('{}'))();

  /// A3: `ChatRows` round-trip bookkeeping (JSON, exact keys: v,
  /// blobHadTitle, blobTitleValue, blobHadHistory, historyHadMessages,
  /// historyHadCurrentId, historyExtra, unmappableMessages).
  TextColumn get blobMeta => text().withDefault(const Constant('{}'))();

  /// A5: true only after a full `ChatResponse` upsert; false for archived
  /// metadata stubs (Q-03 default) and envelope-only stubs.
  BoolColumn get bodySynced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}
