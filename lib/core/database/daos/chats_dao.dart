import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../mappers/chat_blob_mapper.dart';
import '../tables/chats.dart';
import '../tables/messages.dart';

part 'chats_dao.g.dart';

/// Exactly the fields the conversation-list UI uses plus `createdAt`
/// (required by `Conversation`). REQ §10.2: never message bodies.
class ChatListEntry {
  const ChatListEntry({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.pinned,
    required this.archived,
    this.folderId,
    this.lastReadAt,
  });

  final String id;
  final String title;

  /// Epoch seconds.
  final int createdAt;
  final int updatedAt;
  final bool pinned;
  final bool archived;
  final String? folderId;

  /// Epoch seconds.
  final int? lastReadAt;
}

/// Chat row accessor (CDT-RFC-001 §6, §7.4, §10).
@DriftAccessor(tables: [Chats, Messages])
class ChatsDao extends DatabaseAccessor<AppDatabase> with _$ChatsDaoMixin {
  ChatsDao(super.db);

  /// NARROW projection (REQ §10.2): selectOnly() with exactly the
  /// [ChatListEntry] columns — payload/rawExtra/blobMeta/meta MUST NOT appear
  /// in the SQL. WHERE deleted = false; ORDER BY updatedAt DESC, id ASC.
  /// Includes archived rows (filtered/archived split happens in existing
  /// derived providers).
  Stream<List<ChatListEntry>> watchChatList() {
    final query = _listProjection()
      ..where(chats.deleted.equals(false))
      ..orderBy([
        OrderingTerm.desc(chats.updatedAt),
        OrderingTerm.asc(chats.id),
      ]);
    return query.watch().map(
      (rows) => rows.map(_entryFromProjection).toList(growable: false),
    );
  }

  /// Same projection, WHERE id = ?.
  Stream<ChatListEntry?> watchChatMeta(String chatId) {
    final query = _listProjection()..where(chats.id.equals(chatId));
    return query.watchSingleOrNull().map(
      (row) => row == null ? null : _entryFromProjection(row),
    );
  }

  /// deleted=false, ORDER BY updatedAt DESC.
  Future<List<ChatListEntry>> getChatsInFolder(String folderId) async {
    final query = _listProjection()
      ..where(chats.folderId.equals(folderId) & chats.deleted.equals(false))
      ..orderBy([OrderingTerm.desc(chats.updatedAt)]);
    final rows = await query.get();
    return rows.map(_entryFromProjection).toList(growable: false);
  }

  /// Full row, one-shot.
  Future<ChatRow?> getChat(String chatId) {
    return (select(chats)..where((t) => t.id.equals(chatId))).getSingleOrNull();
  }

  /// Transactional server write (fast-forward replace, RFC §7.4 line 2 — no
  /// dirty rows exist in Phase 1). Caller MUST hold ChatLocks for
  /// `rows.chat.id`; the DAO does NOT lock. Entire body runs inside ONE
  /// transaction (REQ §10.1) so the list stream emits once per chat merge.
  Future<void> upsertServerChat({
    required ChatRows rows,
    String? shareId,
    Map<String, dynamic> meta = const {},
    int? listLastReadAt,
  }) {
    final chat = rows.chat;
    return transaction(() async {
      final existing = await getChat(chat.id);
      final mergedLastReadAt = _maxLastReadAt(
        existing?.lastReadAt,
        listLastReadAt,
      );

      await into(chats).insertOnConflictUpdate(
        ChatsCompanion.insert(
          id: chat.id,
          title: chat.title,
          folderId: Value(chat.folderId),
          pinned: Value(chat.pinned),
          archived: Value(chat.archived),
          currentMessageId: Value(chat.currentMessageId),
          createdAt: chat.createdAt,
          updatedAt: chat.updatedAt,
          serverUpdatedAt: Value(chat.updatedAt),
          dirty: const Value(false),
          deleted: const Value(false),
          bodySynced: const Value(true),
          rawExtra: Value(jsonEncode(chat.rawExtra)),
          blobMeta: Value(jsonEncode(blobMetaJson(rows))),
          shareId: Value(shareId),
          meta: Value(jsonEncode(meta)),
          lastReadAt: Value(mergedLastReadAt),
        ),
      );

      await (delete(messages)..where((t) => t.chatId.equals(chat.id))).go();

      await batch((b) {
        b.insertAll(messages, [
          for (final message in rows.messages)
            MessagesCompanion.insert(
              id: message.id,
              chatId: message.chatId,
              parentId: Value(message.parentId),
              role: message.role,
              content: message.content,
              model: Value(message.model),
              createdAt: message.createdAt,
              orderIndex: message.orderIndex,
              payload: jsonEncode(message.payload),
              dirty: const Value(false),
            ),
        ]);
      });
    });
  }

  /// Envelope-only stub for archived metadata (Q-03 default) and summary
  /// upserts. One tx; insert (bodySynced=false, blobMeta='{}') when absent;
  /// when present, update ONLY title/updatedAt/createdAt/pinned/archived/
  /// folderId and lastReadAt=max(...); NEVER touches messages, bodySynced,
  /// blobMeta, rawExtra.
  Future<void> upsertEnvelopeStub({
    required String id,
    required String title,
    required int createdAt,
    required int updatedAt,
    bool? pinned,
    bool? archived,
    String? folderId,
    int? lastReadAt,
  }) {
    return transaction(() async {
      final existing = await getChat(id);
      if (existing == null) {
        await into(chats).insert(
          ChatsCompanion.insert(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pinned: Value(pinned ?? false),
            archived: Value(archived ?? false),
            folderId: Value(folderId),
            lastReadAt: Value(lastReadAt),
            bodySynced: const Value(false),
            blobMeta: const Value('{}'),
          ),
        );
        return;
      }
      await (update(chats)..where((t) => t.id.equals(id))).write(
        ChatsCompanion(
          title: Value(title),
          createdAt: Value(createdAt),
          updatedAt: Value(updatedAt),
          pinned: pinned == null ? const Value.absent() : Value(pinned),
          archived: archived == null ? const Value.absent() : Value(archived),
          folderId: Value(folderId),
          lastReadAt: Value(
            _maxLastReadAt(existing.lastReadAt, lastReadAt),
          ),
        ),
      );
    });
  }

  /// Partial server-confirmed envelope update; affects 0 rows when id absent.
  Future<int> updateEnvelope(
    String chatId, {
    Value<String> title = const Value.absent(),
    Value<String?> folderId = const Value.absent(),
    Value<bool> pinned = const Value.absent(),
    Value<bool> archived = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) {
    return (update(chats)..where((t) => t.id.equals(chatId))).write(
      ChatsCompanion(
        title: title,
        folderId: folderId,
        pinned: pinned,
        archived: archived,
        updatedAt: updatedAt,
      ),
    );
  }

  /// `UPDATE ... SET last_read_at = max(coalesce(last_read_at, 0), ?)` —
  /// never lowered.
  Future<void> setLastReadAt(String chatId, int epochSeconds) {
    return customUpdate(
      'UPDATE chats SET last_read_at = max(coalesce(last_read_at, 0), ?) '
      'WHERE id = ?',
      variables: [Variable.withInt(epochSeconds), Variable.withString(chatId)],
      updates: {chats},
      updateKind: UpdateKind.update,
    );
  }

  /// Row delete; FK cascades messages; one tx.
  Future<void> hardDelete(String chatId) {
    return transaction(() async {
      await (delete(chats)..where((t) => t.id.equals(chatId))).go();
    });
  }

  /// Serializes [ChatRows] round-trip bookkeeping per amendment A3 (exact
  /// keys).
  static Map<String, dynamic> blobMetaJson(ChatRows rows) => <String, dynamic>{
    'v': 1,
    'blobHadTitle': rows.blobHadTitle,
    'blobTitleValue': rows.blobTitleValue,
    'blobHadHistory': rows.blobHadHistory,
    'historyHadMessages': rows.historyHadMessages,
    'historyHadCurrentId': rows.historyHadCurrentId,
    'historyExtra': rows.historyExtra,
    'unmappableMessages': rows.unmappableMessages,
  };

  static int? _maxLastReadAt(int? local, int? server) {
    if (local == null && server == null) return null;
    final merged = (local ?? 0) > (server ?? 0) ? (local ?? 0) : (server ?? 0);
    return merged;
  }

  JoinedSelectStatement<HasResultSet, dynamic> _listProjection() {
    return selectOnly(chats)
      ..addColumns([
        chats.id,
        chats.title,
        chats.createdAt,
        chats.updatedAt,
        chats.pinned,
        chats.archived,
        chats.folderId,
        chats.lastReadAt,
      ]);
  }

  ChatListEntry _entryFromProjection(TypedResult row) {
    return ChatListEntry(
      id: row.read(chats.id)!,
      title: row.read(chats.title)!,
      createdAt: row.read(chats.createdAt)!,
      updatedAt: row.read(chats.updatedAt)!,
      pinned: row.read(chats.pinned)!,
      archived: row.read(chats.archived)!,
      folderId: row.read(chats.folderId),
      lastReadAt: row.read(chats.lastReadAt),
    );
  }
}
