import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../mappers/chat_blob_mapper.dart';
import '../tables/chats.dart';
import '../tables/messages.dart';
import 'outbox_dao.dart';

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

  // ---- local-mutation variants (CDT-RFC-001 §7.2.1, Wiring W1) ------------
  //
  // Each writes its rows AND (when [enqueue]) its outbox op in ONE drift
  // transaction so an op can never exist without its data (REQ §7.2.1). The
  // CALLER holds ChatLocks.runExclusive(chatId); these methods NEVER lock
  // internally (R9 reentrancy). The enqueue joins the SAME transaction by
  // calling [OutboxDao.enqueue] (which opens no transaction of its own).
  //
  // The server-origin variants above (`upsertServerChat`, `upsertEnvelopeStub`,
  // `updateEnvelope`, `hardDelete`) stay enqueue-free — pull-merge / echo are
  // server-origin writes and must never produce outbox ops.

  OutboxDao get _outboxDao => attachedDatabase.outboxDao;

  /// Local envelope edit: wraps [updateEnvelope]'s write, marks the chat
  /// `dirty` so the conflict gate / merge sees it, and (when [enqueue])
  /// enqueues an `updateChat` op — all in one transaction. Caller holds the
  /// chat lock. `dirty=true` is always set for a local mutation; the
  /// non-enqueuing server-confirmed path stays on bare [updateEnvelope].
  Future<void> updateEnvelopeWithOutbox(
    String chatId, {
    Value<String> title = const Value.absent(),
    Value<String?> folderId = const Value.absent(),
    Value<bool> pinned = const Value.absent(),
    Value<bool> archived = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
    required bool enqueue,
  }) {
    return transaction(() async {
      await (update(chats)..where((t) => t.id.equals(chatId))).write(
        ChatsCompanion(
          title: title,
          folderId: folderId,
          pinned: pinned,
          archived: archived,
          updatedAt: updatedAt,
          dirty: const Value(true),
        ),
      );
      if (enqueue) {
        await _outboxDao.enqueue(kind: OutboxKind.updateChat, chatId: chatId);
      }
    });
  }

  /// Local delete: tombstones the chat (`deleted=true, dirty=true`) and
  /// enqueues a `deleteChat` op in one transaction. Rows are NOT hard-deleted
  /// here (tombstone discipline §7.5); the drainer's `pushDeleteChat` purges
  /// after the server confirms. Caller holds the chat lock.
  Future<void> tombstoneWithOutbox(String chatId) {
    return transaction(() async {
      await (update(chats)..where((t) => t.id.equals(chatId))).write(
        const ChatsCompanion(
          deleted: Value(true),
          dirty: Value(true),
        ),
      );
      await _outboxDao.enqueue(kind: OutboxKind.deleteChat, chatId: chatId);
    });
  }

  /// Pure-local drop of a `local:` chat whose create never reached the server
  /// (W2): hard-deletes the chat row (FK cascades messages) AND deletes every
  /// pending outbox op for it, in one transaction — no `deleteChat` op (the
  /// chat never existed server-side). Caller holds the chat lock.
  Future<void> dropLocalChat(String localId) {
    return transaction(() async {
      await (delete(_outboxDao.outboxOps)
            ..where((t) => t.chatId.equals(localId)))
          .go();
      await (delete(chats)..where((t) => t.id.equals(localId))).go();
    });
  }

  /// Offline compose (W3.b): inserts the `local:` chat row + its message rows
  /// (all `dirty=true`) and enqueues a `createChat` op carrying [contentHash],
  /// then — when an assistant placeholder is present — a `requestCompletion`
  /// op (seq AFTER the create, so the drainer creates+remaps before running
  /// the completion against the server id, §B2.4) — all in one transaction.
  /// Caller holds `ChatLocks(chat.id)`.
  Future<void> insertLocalChatWithCreateOp({
    required ChatRowData chat,
    required List<MessageRowData> messages,
    required ChatRows blobRows,
    required String contentHash,
    RequestCompletionPayload? completion,
  }) {
    return transaction(() async {
      await into(chats).insert(
        ChatsCompanion.insert(
          id: chat.id,
          title: chat.title,
          folderId: Value(chat.folderId),
          pinned: Value(chat.pinned),
          archived: Value(chat.archived),
          currentMessageId: Value(chat.currentMessageId),
          createdAt: chat.createdAt,
          updatedAt: chat.updatedAt,
          serverUpdatedAt: const Value(null),
          dirty: const Value(true),
          deleted: const Value(false),
          bodySynced: const Value(true),
          rawExtra: Value(jsonEncode(chat.rawExtra)),
          blobMeta: Value(jsonEncode(blobMetaJson(blobRows))),
        ),
      );
      await batch((b) {
        b.insertAll(this.messages, [
          for (final message in messages)
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
              dirty: const Value(true),
            ),
        ]);
      });
      await _outboxDao.enqueue(
        kind: OutboxKind.createChat,
        chatId: chat.id,
        contentHash: contentHash,
      );
      if (completion != null) {
        await _outboxDao.enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: chat.id,
          payload: completion.toJson(),
        );
      }
    });
  }

  /// Send-on-existing-chat (W3.c): upserts the user message + assistant
  /// placeholder rows (`dirty=true`), updates the chat envelope
  /// (`currentMessageId`, `updatedAt`, `dirty=true`), enqueues an `updateChat`
  /// op, and — when [enqueueCompletion] — a `requestCompletion` op (seq after
  /// the update) — all in one transaction. Caller holds the chat lock.
  ///
  /// New message rows take `orderIndex = max(order_index)+1` for the chat,
  /// counting up across the batch; existing rows keep their orderIndex.
  Future<void> appendMessagesWithUpdateOp({
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
    required bool enqueueCompletion,
    RequestCompletionPayload? completion,
  }) {
    return transaction(() async {
      final maxExpr = this.messages.orderIndex.max();
      final maxQuery = selectOnly(this.messages)
        ..addColumns([maxExpr])
        ..where(this.messages.chatId.equals(chatId));
      final maxRow = await maxQuery.getSingle();
      var nextOrder = (maxRow.read(maxExpr) ?? -1) + 1;

      for (final message in messages) {
        final existing = await (select(this.messages)..where(
              (t) => t.chatId.equals(chatId) & t.id.equals(message.id),
            ))
            .getSingleOrNull();
        final orderIndex = existing?.orderIndex ?? nextOrder++;
        await into(this.messages).insertOnConflictUpdate(
          MessagesCompanion.insert(
            id: message.id,
            chatId: chatId,
            parentId: Value(message.parentId),
            role: message.role,
            content: message.content,
            model: Value(message.model),
            createdAt: message.createdAt,
            orderIndex: orderIndex,
            payload: jsonEncode(message.payload),
            dirty: const Value(true),
          ),
        );
      }

      await (update(chats)..where((t) => t.id.equals(chatId))).write(
        ChatsCompanion(
          currentMessageId: currentMessageId == null
              ? const Value.absent()
              : Value(currentMessageId),
          updatedAt: updatedAt == null ? const Value.absent() : Value(updatedAt),
          dirty: const Value(true),
        ),
      );

      await _outboxDao.enqueue(kind: OutboxKind.updateChat, chatId: chatId);

      if (enqueueCompletion && completion != null) {
        await _outboxDao.enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: chatId,
          payload: completion.toJson(),
        );
      }
    });
  }

  /// Stop-streaming abort (W14): deletes PENDING `requestCompletion` ops for
  /// [chatId] so a turn the user stopped is not re-driven by the next drain. An
  /// `inFlight` requestCompletion (the stream already started) is NOT touched —
  /// the stop's transport-cancel handles it and its op markDone()s on stream
  /// finish. Caller holds the chat lock. Returns the number of ops removed.
  Future<int> cancelPendingCompletion(String chatId) {
    return (delete(_outboxDao.outboxOps)
          ..where(
            (t) =>
                t.chatId.equals(chatId) &
                t.kind.equals(OutboxKind.requestCompletion.name) &
                t.status.equals(OutboxStatus.pending),
          ))
        .go();
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
