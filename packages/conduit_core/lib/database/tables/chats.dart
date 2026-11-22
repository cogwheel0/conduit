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
  /// merge rule is `max(local, server)`, lowered only by Open WebUI's explicit
  /// unread (0). See `ChatsDao.mergeServerLastReadAt`.
  IntColumn get lastReadAt => integer().nullable()();

  /// The chat holds text from the server's copy never shown here, taken
  /// into a push from this device or returned by one: it shows unread on
  /// this device until it is read here ([ChatsDao.setLastReadAt]) with that
  /// text stored here ([heldTextAt]), or the user marks it read, whatever
  /// its dates say. Its dates
  /// alone can't hold that: a read in the second the push lands, or by a
  /// clock ahead of the server's, is no earlier than the push, and pulls
  /// take the server's `updated_at` and the newer `last_read_at`.
  BoolColumn get heldUnread => boolean().withDefault(const Constant(false))();

  /// Epoch seconds, server clock: the date of the server's copy holding the
  /// text [heldUnread] is for, returned by a push, until a pull stores a
  /// copy that new here. Till then a read here covers only the older copy,
  /// so it leaves the hold. The user's own Mark as Read ends the hold and
  /// leaves this date, for a sync cycle to fetch that copy; a push landing
  /// meanwhile holds the chat again only for a message written after that
  /// read. Null when that text is stored here.
  IntColumn get heldTextAt => integer().nullable()();

  /// A2: `ChatResponse` envelope fields.
  TextColumn get shareId => text().nullable()();

  /// Server `user_id` of the chat owner (v10). Null for local-created rows
  /// and rows written before v10. Differs from the signed-in user only for a
  /// chat reached through a shared folder, which the UI treats as read-only.
  TextColumn get userId => text().nullable()();
  TextColumn get meta => text().withDefault(const Constant('{}'))();

  /// A3: `ChatRows` round-trip bookkeeping (JSON, exact keys: v,
  /// blobHadTitle, blobTitleValue, blobHadHistory, historyHadMessages,
  /// historyHadCurrentId, historyExtra, unmappableMessages,
  /// unmappableMessageOrder).
  TextColumn get blobMeta => text().withDefault(const Constant('{}'))();

  /// A5: true only after a full `ChatResponse` upsert; false for archived
  /// metadata stubs (Q-03 default) and envelope-only stubs.
  BoolColumn get bodySynced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}
