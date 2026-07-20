import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../utils/debug_logger.dart';
import '../../sync/chat_merger.dart';
import '../app_database.dart';
import '../mappers/chat_blob_mapper.dart';
import '../mappers/conversation_assembler.dart';
import '../tables/chats.dart';
import '../tables/messages.dart';
import 'outbox_dao.dart';

part 'chats_dao.g.dart';

const _chatListColumns =
    'id, title, created_at, updated_at, pinned, archived, folder_id, '
    'last_read_at';

const _archivedChatCountSql = '''
SELECT COUNT(id) AS archived_count
FROM chats
WHERE deleted = 0 AND pinned = 0 AND archived = 1
''';

final class _ChatListWindowStatement {
  const _ChatListWindowStatement(this.sql, this.variables);

  final String sql;
  final List<Variable<int>> variables;
}

_ChatListWindowStatement _chatListWindowStatement({
  required int? regularLimit,
  required int? archivedLimit,
}) {
  final variables = <Variable<int>>[];

  String unpinnedBranch({required bool archived, required int? limit}) {
    final buffer = StringBuffer('''
SELECT $_chatListColumns
FROM chats
WHERE deleted = 0 AND pinned = 0 AND archived = ${archived ? 1 : 0}
''');
    if (limit != null) {
      variables.add(Variable<int>(math.max(0, limit)));
      buffer.write('''
ORDER BY updated_at DESC, id ASC
LIMIT ?
''');
    }
    return buffer.toString();
  }

  final regularSql = unpinnedBranch(archived: false, limit: regularLimit);
  final archivedSql = unpinnedBranch(archived: true, limit: archivedLimit);
  return _ChatListWindowStatement('''
WITH pinned_rows AS (
  SELECT $_chatListColumns
  FROM chats
  WHERE deleted = 0 AND pinned = 1
),
regular_rows AS (
$regularSql
),
archived_rows AS (
$archivedSql
)
SELECT * FROM pinned_rows
UNION ALL
SELECT * FROM regular_rows
UNION ALL
SELECT * FROM archived_rows
ORDER BY updated_at DESC, id ASC
''', variables);
}

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
  /// [regularLimit] and [archivedLimit] independently window unpinned active
  /// and archived rows. Pinned rows are always included regardless of age.
  Stream<List<ChatListEntry>> watchChatList({
    int? regularLimit,
    int? archivedLimit,
  }) {
    if (regularLimit != null || archivedLimit != null) {
      final statement = _chatListWindowStatement(
        regularLimit: regularLimit,
        archivedLimit: archivedLimit,
      );
      final query = customSelect(
        statement.sql,
        variables: statement.variables,
        readsFrom: {chats},
      );
      return query.watch().map(
        (rows) => rows.map(_entryFromCustomRow).toList(growable: false),
      );
    }
    final query = _activeChatsListQuery();
    return query.watch().map(
      (rows) => rows.map(_entryFromProjection).toList(growable: false),
    );
  }

  /// Exact live count for the independently paged archived drawer section.
  /// Pinned rows belong to the pinned section even if a stale server envelope
  /// also marks them archived, so they are deliberately excluded here.
  Stream<int> watchArchivedChatCount() {
    return customSelect(
      _archivedChatCountSql,
      readsFrom: {chats},
    ).watchSingle().map((row) => row.read<int>('archived_count'));
  }

  @visibleForTesting
  Future<List<String>> debugExplainChatListWindow({
    required int regularLimit,
    required int archivedLimit,
  }) async {
    final statement = _chatListWindowStatement(
      regularLimit: regularLimit,
      archivedLimit: archivedLimit,
    );
    final rows = await customSelect(
      'EXPLAIN QUERY PLAN ${statement.sql}',
      variables: statement.variables,
    ).get();
    return rows
        .map((row) => row.read<String>('detail'))
        .toList(growable: false);
  }

  @visibleForTesting
  Future<List<String>> debugExplainArchivedChatCount() async {
    final rows = await customSelect(
      'EXPLAIN QUERY PLAN $_archivedChatCountSql',
    ).get();
    return rows
        .map((row) => row.read<String>('detail'))
        .toList(growable: false);
  }

  /// Shared WHERE + ORDER BY for the active-chats list. Both [watchChatList]
  /// and [getChatPage] start from this so the deleted-filter and ordering stay
  /// structurally identical (the page must compose seamlessly with the watch
  /// stream; see [getChatPage]).
  JoinedSelectStatement<HasResultSet, dynamic> _activeChatsListQuery() {
    return _listProjection()
      ..where(chats.deleted.equals(false))
      ..orderBy([
        OrderingTerm.desc(chats.updatedAt),
        OrderingTerm.asc(chats.id),
      ]);
  }

  /// One-shot page using the same narrow projection and deterministic ordering
  /// as [watchChatList]. The live UI uses [watchChatList]'s regular-row window;
  /// this offset form remains useful for cold-read budgets and batch callers.
  Future<List<ChatListEntry>> getChatPage({
    required int limit,
    required int offset,
  }) async {
    final query = _activeChatsListQuery()..limit(limit, offset: offset);
    final rows = await query.get();
    return rows.map(_entryFromProjection).toList(growable: false);
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

  /// NARROW id-only projection (REQ §10.2) of every non-tombstoned chat that
  /// carries a SERVER id (`id NOT LIKE 'local:%'`). Used by the §7.5 full-ID
  /// deletion reconcile to diff local server-keyed chats against the complete
  /// server id set. `local:` rows (never reached the server) are excluded.
  Future<List<String>> allServerChatIds() async {
    final query = selectOnly(chats)
      ..addColumns([chats.id])
      ..where(chats.deleted.equals(false) & chats.id.like('local:%').not());
    final rows = await query.get();
    return rows.map((row) => row.read(chats.id)!).toList(growable: false);
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
      await _writeChatRows(
        rows: rows,
        shareId: shareId,
        meta: meta,
        listLastReadAt: listLastReadAt,
        existingLastReadAt: existing?.lastReadAt,
        serverUpdatedAt: chat.updatedAt,
        chatDirty: false,
      );
    });
  }

  /// Three-way pull merge (CDT-RFC-001 §7.4) in ONE transaction (REQ §10.1).
  /// Caller MUST hold ChatLocks for `server.chat.id`.
  ///
  /// Reads the existing chat + message rows (and their dirty flags) and:
  ///  * no existing row → plain server insert (first sync; == fast-forward);
  ///  * existing dirty tombstone (deleted && dirty) → SKIP entirely (the
  ///    pending `deleteChat` wins; the drainer purges on confirm) so the
  ///    fast-forward never resurrects a locally-deleted chat;
  ///  * otherwise → pure [mergeChat] then write per [MergeOutcome]:
  ///    - noRemoteChange: rows untouched (only `mustPush` is reported);
  ///    - fastForward: delete+reinsert messages `dirty=false`,
  ///      `serverUpdatedAt = S.updatedAt`, `dirty=false` (today's body);
  ///    - threeWay: upsert the merged envelope `dirty=true`,
  ///      `serverUpdatedAt = base` (UNCHANGED), delete+reinsert merged messages
  ///      with `dirty` set per the merged dirty-id set.
  ///
  /// Returns the [MergeOutcome] and `mustPush`. When the merged result diverges
  /// from the server, this method also reasserts a pending `updateChat` op in
  /// the SAME transaction as the dirty row writes (REQ 4 / outbox atomicity).
  Future<ChatMergeWriteResult> mergeServerChat({
    required ChatRows server,
    String? shareId,
    Map<String, dynamic> meta = const {},
    int? listLastReadAt,
  }) {
    final serverChat = server.chat;
    return transaction(() async {
      final existing = await getChat(serverChat.id);

      // First sync for this id, OR a never-synced envelope stub
      // (serverUpdatedAt == null). Clean stubs can fast-forward to the full
      // server body. Dirty stubs cannot: migration can append local messages to
      // an envelope stub before the first body pull, and _writeChatRows replaces
      // all messages.
      if (existing == null || existing.serverUpdatedAt == null) {
        if (existing != null && existing.dirty) {
          if (existing.deleted) {
            return const ChatMergeWriteResult(
              outcome: MergeOutcome.noRemoteChange,
              mustPush: false,
            );
          }

          final localMessages = await (select(
            messages,
          )..where((t) => t.chatId.equals(serverChat.id))).get();
          final local = chatRowsFromDb(existing, localMessages);
          final dirtyMessageIds = <String>{
            for (final m in localMessages)
              if (m.dirty) m.id,
          };
          final result = mergeChat(
            server: server,
            local: local,
            base: serverChat.updatedAt - 1,
            chatEnvelopeDirty: true,
            dirtyMessageIds: dirtyMessageIds,
          );
          await _writeChatRows(
            rows: result.merged,
            shareId: shareId,
            meta: meta,
            listLastReadAt: listLastReadAt,
            existingLastReadAt: existing.lastReadAt,
            serverUpdatedAt: result.newServerUpdatedAt,
            chatDirty: true,
            dirtyMessageIds: result.dirtyMessageIds,
          );
          return _mergeResultWithUpdateOpIfMissing(
            serverChat.id,
            ChatMergeWriteResult(
              outcome: result.outcome,
              mustPush: result.mustPush,
            ),
          );
        }
        await _writeChatRows(
          rows: server,
          shareId: shareId,
          meta: meta,
          listLastReadAt: listLastReadAt,
          existingLastReadAt: existing?.lastReadAt,
          serverUpdatedAt: serverChat.updatedAt,
          chatDirty: false,
        );
        return const ChatMergeWriteResult(
          outcome: MergeOutcome.fastForward,
          mustPush: false,
        );
      }

      // Dirty tombstone: the pending deleteChat wins. Do not touch rows; the
      // drainer purges on server confirm (§7.5). Never clear `deleted` here.
      if (existing.deleted && existing.dirty) {
        return const ChatMergeWriteResult(
          outcome: MergeOutcome.noRemoteChange,
          mustPush: false,
        );
      }

      final base = existing.serverUpdatedAt!;

      final localMessages = await (select(
        messages,
      )..where((t) => t.chatId.equals(serverChat.id))).get();
      final local = chatRowsFromDb(existing, localMessages);
      final dirtyMessageIds = <String>{
        for (final m in localMessages)
          if (m.dirty) m.id,
      };

      final result = mergeChat(
        server: server,
        local: local,
        base: base,
        chatEnvelopeDirty: existing.dirty,
        dirtyMessageIds: dirtyMessageIds,
      );

      switch (result.outcome) {
        case MergeOutcome.noRemoteChange:
          // Rows untouched; only re-assert push below when needed.
          return _mergeResultWithUpdateOpIfMissing(
            serverChat.id,
            ChatMergeWriteResult(
              outcome: result.outcome,
              mustPush: result.mustPush,
            ),
          );
        case MergeOutcome.fastForward:
          await _writeChatRows(
            rows: result.merged,
            shareId: shareId,
            meta: meta,
            listLastReadAt: listLastReadAt,
            existingLastReadAt: existing.lastReadAt,
            serverUpdatedAt: result.newServerUpdatedAt,
            chatDirty: false,
          );
          return _mergeResultWithUpdateOpIfMissing(
            serverChat.id,
            ChatMergeWriteResult(
              outcome: result.outcome,
              mustPush: result.mustPush,
            ),
          );
        case MergeOutcome.threeWay:
          await _writeChatRows(
            rows: result.merged,
            shareId: shareId,
            meta: meta,
            listLastReadAt: listLastReadAt,
            existingLastReadAt: existing.lastReadAt,
            serverUpdatedAt: result.newServerUpdatedAt,
            chatDirty: true,
            dirtyMessageIds: result.dirtyMessageIds,
          );
          return _mergeResultWithUpdateOpIfMissing(
            serverChat.id,
            ChatMergeWriteResult(
              outcome: result.outcome,
              mustPush: result.mustPush,
            ),
          );
      }
    });
  }

  /// Caller is inside [mergeServerChat]'s transaction. Reasserts an active
  /// updateChat atomically with dirty merge writes unless an update/create
  /// already covers this chat.
  Future<ChatMergeWriteResult> _mergeResultWithUpdateOpIfMissing(
    String chatId,
    ChatMergeWriteResult result,
  ) async {
    if (!result.mustPush) return result;
    final active = await _outboxDao.activeForChat(
      chatId,
      domainKind: OutboxKind.updateChat,
    );
    final hasUpdateOrCreate = active.any((op) {
      final kind = OutboxKind.fromName(op.kind);
      return kind == OutboxKind.updateChat || kind == OutboxKind.createChat;
    });
    if (!hasUpdateOrCreate) {
      await _outboxDao.enqueue(kind: OutboxKind.updateChat, chatId: chatId);
    }
    return result;
  }

  /// Shared chat-body writer. The fast-forward / first-sync callers pass
  /// `chatDirty: false` (chat row + messages all `dirty=false`); the three-way
  /// caller passes `chatDirty: true` with the surviving [dirtyMessageIds] so
  /// those message rows stay dirty. Always `deleted=false`, `bodySynced=true`,
  /// and an incremental synchronization of message rows. `serverUpdatedAt` is
  /// the caller's contract (fast-forward advances it to today's body; three-way
  /// keeps it at `base` so the push advances it). Local-only chats pass null
  /// because they have no remote merge base.
  Future<void> _writeChatRows({
    required ChatRows rows,
    required String? shareId,
    required Map<String, dynamic> meta,
    required int? listLastReadAt,
    required int? existingLastReadAt,
    required int? serverUpdatedAt,
    required bool chatDirty,
    Set<String> dirtyMessageIds = const {},
  }) async {
    final chat = rows.chat;
    final mergedLastReadAt = _maxLastReadAt(existingLastReadAt, listLastReadAt);

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
        serverUpdatedAt: Value(serverUpdatedAt),
        dirty: Value(chatDirty),
        deleted: const Value(false),
        bodySynced: const Value(true),
        rawExtra: Value(jsonEncode(chat.rawExtra)),
        blobMeta: Value(jsonEncode(blobMetaJson(rows))),
        shareId: Value(shareId),
        meta: Value(jsonEncode(meta)),
        lastReadAt: Value(mergedLastReadAt),
      ),
    );

    await _syncMessages(chat.id, rows.messages, dirtyIds: dirtyMessageIds);
  }

  Future<void> _syncMessages(
    String chatId,
    List<MessageRowData> incoming, {
    Set<String> dirtyIds = const {},
  }) async {
    final existingRows = await (select(
      messages,
    )..where((t) => t.chatId.equals(chatId))).get();
    final existingById = <String, MessageRow>{
      for (final row in existingRows) row.id: row,
    };
    final incomingIds = <String>{};
    final inserts = <MessagesCompanion>[];
    final updates =
        <
          ({
            MessageRow existing,
            MessageRowData row,
            String payload,
            bool dirty,
          })
        >[];

    for (final row in incoming) {
      incomingIds.add(row.id);
      final payload = jsonEncode(row.payload);
      final dirty = dirtyIds.contains(row.id);
      final existing = existingById[row.id];
      if (existing == null) {
        inserts.add(_messageCompanion(row, payload: payload, dirty: dirty));
        continue;
      }
      if (!_messageRowMatches(existing, row, payload: payload, dirty: dirty)) {
        updates.add((
          existing: existing,
          row: row,
          payload: payload,
          dirty: dirty,
        ));
      }
    }

    final staleIds = existingById.keys
        .where((id) => !incomingIds.contains(id))
        .toList(growable: false);
    if (staleIds.isEmpty && inserts.isEmpty && updates.isEmpty) return;

    await batch((b) {
      for (final id in staleIds) {
        b.deleteWhere(
          messages,
          (t) => t.chatId.equals(chatId) & t.id.equals(id),
        );
      }
      if (inserts.isNotEmpty) {
        b.insertAll(messages, inserts);
      }
      for (final update in updates) {
        b.update(
          messages,
          _messageUpdateCompanion(
            update.existing,
            update.row,
            payload: update.payload,
            dirty: update.dirty,
          ),
          where: (t) => t.chatId.equals(chatId) & t.id.equals(update.row.id),
        );
      }
    });
  }

  MessagesCompanion _messageCompanion(
    MessageRowData row, {
    required String payload,
    required bool dirty,
  }) {
    return MessagesCompanion.insert(
      id: row.id,
      chatId: row.chatId,
      parentId: Value(row.parentId),
      role: row.role,
      content: row.content,
      model: Value(row.model),
      createdAt: row.createdAt,
      orderIndex: row.orderIndex,
      payload: payload,
      dirty: Value(dirty),
    );
  }

  MessagesCompanion _messageUpdateCompanion(
    MessageRow existing,
    MessageRowData row, {
    required String payload,
    required bool dirty,
  }) {
    return MessagesCompanion(
      parentId: existing.parentId == row.parentId
          ? const Value.absent()
          : Value(row.parentId),
      role: existing.role == row.role ? const Value.absent() : Value(row.role),
      content: existing.content == row.content
          ? const Value.absent()
          : Value(row.content),
      model: existing.model == row.model
          ? const Value.absent()
          : Value(row.model),
      createdAt: existing.createdAt == row.createdAt
          ? const Value.absent()
          : Value(row.createdAt),
      orderIndex: existing.orderIndex == row.orderIndex
          ? const Value.absent()
          : Value(row.orderIndex),
      payload: existing.payload == payload
          ? const Value.absent()
          : Value(payload),
      dirty: existing.dirty == dirty ? const Value.absent() : Value(dirty),
    );
  }

  bool _messageRowMatches(
    MessageRow existing,
    MessageRowData incoming, {
    required String payload,
    required bool dirty,
  }) {
    return existing.parentId == incoming.parentId &&
        existing.role == incoming.role &&
        existing.content == incoming.content &&
        existing.model == incoming.model &&
        existing.createdAt == incoming.createdAt &&
        existing.orderIndex == incoming.orderIndex &&
        existing.payload == payload &&
        existing.dirty == dirty;
  }

  /// Batch-inserts message rows for a chat (caller owns the preceding
  /// `delete(messages)` and the enclosing transaction). `dirty` is set per
  /// [dirtyIds]; when [allDirty] is true every row is dirty (local-create
  /// path). The `payload` column feeds the `chat_fts` insert trigger.
  Future<void> _insertMessages(
    List<MessageRowData> rows, {
    Set<String> dirtyIds = const {},
    bool allDirty = false,
  }) async {
    await batch((b) {
      b.insertAll(messages, [
        for (final message in rows)
          _messageCompanion(
            message,
            payload: jsonEncode(message.payload),
            dirty: allDirty || dirtyIds.contains(message.id),
          ),
      ]);
    });
  }

  /// Envelope-only stub for archived metadata (Q-03 default) and summary
  /// upserts. One tx; insert (bodySynced=false, blobMeta='{}') when absent;
  /// when present, update ONLY title/updatedAt/createdAt, provided
  /// pinned/archived/folderId, and lastReadAt=max(...); NEVER touches messages,
  /// bodySynced, blobMeta, rawExtra.
  Future<void> upsertEnvelopeStub({
    required String id,
    required String title,
    required int createdAt,
    required int updatedAt,
    bool? pinned,
    bool? archived,
    Value<String?> folderId = const Value.absent(),
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
            folderId: folderId,
            lastReadAt: Value(lastReadAt),
            bodySynced: const Value(false),
            blobMeta: const Value('{}'),
          ),
        );
        return;
      }
      await (update(chats)..where((t) => t.id.equals(id))).write(
        ChatsCompanion(
          title: existing.dirty ? const Value.absent() : Value(title),
          createdAt: Value(createdAt),
          updatedAt: existing.dirty ? const Value.absent() : Value(updatedAt),
          pinned: pinned == null ? const Value.absent() : Value(pinned),
          archived: archived == null ? const Value.absent() : Value(archived),
          folderId: folderId,
          lastReadAt: Value(_maxLastReadAt(existing.lastReadAt, lastReadAt)),
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

  /// Inserts or replaces a complete on-device chat without creating outbox
  /// work. This is the durable write seam for direct-provider conversations
  /// that must never be synchronized to Open WebUI.
  ///
  /// The row has no remote merge base (`serverUpdatedAt = null`) and both the
  /// chat and message rows remain clean. Replacing the message set is
  /// intentional: [rows] is the complete local source of truth.
  Future<void> upsertLocalOnlyChat({
    required ChatRows rows,
    Map<String, dynamic> meta = const {},
    int? lastReadAt,
  }) {
    return transaction(() async {
      final existing = await getChat(rows.chat.id);
      await _writeChatRows(
        rows: rows,
        shareId: null,
        meta: meta,
        listLastReadAt: lastReadAt,
        existingLastReadAt: existing?.lastReadAt,
        serverUpdatedAt: null,
        chatDirty: false,
      );
    });
  }

  /// Appends or replaces local-only messages and advances the chat tip without
  /// dirtying rows or enqueuing either an update or completion operation.
  Future<void> appendLocalOnlyMessages({
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
  }) {
    return appendMessagesWithUpdateOp(
      chatId: chatId,
      messages: messages,
      currentMessageId: currentMessageId,
      updatedAt: updatedAt,
      enqueueUpdate: false,
      enqueueCompletion: false,
    );
  }

  /// Updates an on-device chat envelope without marking it dirty or creating an
  /// Open WebUI outbox operation.
  Future<void> updateLocalOnlyEnvelope(
    String chatId, {
    Value<String> title = const Value.absent(),
    Value<String?> folderId = const Value.absent(),
    Value<bool> pinned = const Value.absent(),
    Value<bool> archived = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) async {
    await (update(chats)..where((t) => t.id.equals(chatId))).write(
      ChatsCompanion(
        title: title,
        folderId: folderId,
        pinned: pinned,
        archived: archived,
        updatedAt: updatedAt,
        dirty: const Value(false),
      ),
    );
  }

  /// Permanently removes an on-device chat. Any unexpected stale outbox rows
  /// are deleted defensively so this method cannot leave synchronizable work
  /// behind.
  Future<void> deleteLocalOnlyChat(String chatId) {
    return transaction(() async {
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(chatId))).go();
      await (delete(chats)..where((t) => t.id.equals(chatId))).go();
      await _deleteChatRemapMetadata(chatId);
    });
  }

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
  /// enqueues a `deleteChat` op in one transaction. Rows are normally NOT
  /// hard-deleted here (tombstone discipline §7.5); the drainer's
  /// `pushDeleteChat` purges after the server confirms. The exception is a
  /// pure-local create/delete pair that coalesces to no outbox survivor.
  /// Caller holds the chat lock.
  Future<void> tombstoneWithOutbox(String chatId) {
    return transaction(() async {
      await (update(chats)..where((t) => t.id.equals(chatId))).write(
        const ChatsCompanion(deleted: Value(true), dirty: Value(true)),
      );
      final deleteSeq = await _outboxDao.enqueue(
        kind: OutboxKind.deleteChat,
        chatId: chatId,
      );
      if (deleteSeq == -1) {
        // createChat + deleteChat coalesced away: the chat never reached the
        // server, so no tombstone should remain for reconcile/drain to find.
        await (delete(chats)..where((t) => t.id.equals(chatId))).go();
        await _deleteChatRemapMetadata(chatId);
      }
    });
  }

  /// Pure-local drop of a `local:` chat whose create never reached the server
  /// (W2): hard-deletes the chat row (FK cascades messages) AND deletes every
  /// pending outbox op for it, in one transaction — no `deleteChat` op (the
  /// chat never existed server-side). Caller holds the chat lock.
  Future<void> dropLocalChat(String localId) {
    return transaction(() async {
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(localId))).go();
      await (delete(chats)..where((t) => t.id.equals(localId))).go();
      await _deleteChatRemapMetadata(localId);
    });
  }

  /// §7.5 reconcile purge of a CONFIRMED server-side delete: hard-deletes the
  /// chat row (FK cascades messages) AND drops every pending outbox op for it
  /// (mirrors [dropLocalChat]'s op cleanup) in one transaction. Caller holds
  /// the chat lock. Unlike [dropLocalChat] this is for a SERVER-keyed chat the
  /// reconcile proved gone (404/401), so any pending op for it is moot.
  Future<void> purgeReconciledChat(String chatId) {
    return transaction(() async {
      await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.chatId.equals(chatId))).go();
      await (delete(chats)..where((t) => t.id.equals(chatId))).go();
      await _deleteChatRemapMetadata(chatId);
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
      // A newly-created entity owns this local id as a fresh generation. Drop
      // any historical source mapping before inserting it so an old A->B
      // relation cannot redirect work for a deliberately reused local id.
      await attachedDatabase.syncMetaDao.deleteChatRemapTarget(chat.id);
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
      await _insertMessages(messages, allDirty: true);
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
  /// placeholder rows, updates the chat envelope, enqueues an `updateChat` op
  /// when [enqueueUpdate] is true, and — when [enqueueCompletion] — a
  /// `requestCompletion` op (seq after the update when present) — all in one
  /// transaction. Caller holds the chat lock.
  ///
  /// New message rows take `orderIndex = max(order_index)+1` for the chat,
  /// counting up across the batch; existing rows keep their orderIndex.
  Future<void> appendMessagesWithUpdateOp({
    required String chatId,
    required List<MessageRowData> messages,
    String? currentMessageId,
    int? updatedAt,
    bool enqueueUpdate = true,
    required bool enqueueCompletion,
    RequestCompletionPayload? completion,
  }) async {
    // Append hot-path instrumentation (CDT-RFC-001 §10 Budget 2): the §10 hot
    // path must stay ≤10ms even with the chat_fts INSERT trigger live. Numeric-
    // only data (no message content) so nothing untrusted is logged.
    final sw = Stopwatch()..start();
    await transaction(() async {
      final maxExpr = this.messages.orderIndex.max();
      final maxQuery = selectOnly(this.messages)
        ..addColumns([maxExpr])
        ..where(this.messages.chatId.equals(chatId));
      final maxRow = await maxQuery.getSingle();
      var nextOrder = (maxRow.read(maxExpr) ?? -1) + 1;

      for (final message in messages) {
        final existing =
            await (select(this.messages)..where(
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
            dirty: Value(enqueueUpdate),
          ),
        );
      }

      await (update(chats)..where((t) => t.id.equals(chatId))).write(
        ChatsCompanion(
          currentMessageId: currentMessageId == null
              ? const Value.absent()
              : Value(currentMessageId),
          updatedAt: updatedAt == null
              ? const Value.absent()
              : Value(updatedAt),
          dirty: Value(enqueueUpdate),
        ),
      );

      if (enqueueUpdate) {
        await _outboxDao.enqueue(kind: OutboxKind.updateChat, chatId: chatId);
      }

      if (enqueueCompletion && completion != null) {
        await _outboxDao.enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: chatId,
          payload: completion.toJson(),
        );
      }
    });
    sw.stop();
    DebugLogger.log(
      'append-ms',
      scope: 'perf/append',
      data: {'ms': sw.elapsedMilliseconds, 'count': messages.length},
    );
  }

  /// Stop-streaming abort (W14): deletes PENDING `requestCompletion` ops for
  /// [chatId] so a turn the user stopped is not re-driven by the next drain.
  /// It also removes the matching empty assistant placeholder before the
  /// co-enqueued `updateChat` drains, so the update reconstructs a blob without
  /// a permanent empty assistant bubble. An `inFlight` requestCompletion (the
  /// stream already started) is NOT touched — the stop's transport-cancel
  /// handles it and its op markDone()s on stream finish. Caller holds the chat
  /// lock. Returns the number of requestCompletion ops removed.
  Future<int> cancelPendingCompletion(String chatId) {
    return transaction(() async {
      final pending =
          await (select(_outboxDao.outboxOps)..where(
                (t) =>
                    t.chatId.equals(chatId) &
                    t.kind.equals(OutboxKind.requestCompletion.name) &
                    t.status.equals(OutboxStatus.pending),
              ))
              .get();
      if (pending.isEmpty) return 0;

      final assistantIds = <String>{};
      for (final op in pending) {
        final assistantId = _requestCompletionAssistantId(op.payload);
        if (assistantId != null) assistantIds.add(assistantId);
      }
      final placeholders = assistantIds.isEmpty
          ? const <MessageRow>[]
          : await (select(messages)..where(
                  (t) =>
                      t.chatId.equals(chatId) &
                      t.id.isIn(assistantIds.toList()) &
                      t.role.equals('assistant') &
                      t.content.equals(''),
                ))
                .get();

      final removedOps =
          await (delete(_outboxDao.outboxOps)..where(
                (t) =>
                    t.chatId.equals(chatId) &
                    t.kind.equals(OutboxKind.requestCompletion.name) &
                    t.status.equals(OutboxStatus.pending),
              ))
              .go();

      if (placeholders.isNotEmpty) {
        for (final placeholder in placeholders) {
          await _removeAssistantChildLink(
            chatId: chatId,
            parentId: placeholder.parentId,
            assistantMessageId: placeholder.id,
          );
        }

        await (delete(messages)..where(
              (t) =>
                  t.chatId.equals(chatId) &
                  t.id.isIn([for (final row in placeholders) row.id]),
            ))
            .go();

        final chat = await getChat(chatId);
        if (chat != null &&
            placeholders.any((row) => row.id == chat.currentMessageId)) {
          final replacementTip = placeholders
              .firstWhere((row) => row.id == chat.currentMessageId)
              .parentId;
          await (update(chats)..where((t) => t.id.equals(chatId))).write(
            ChatsCompanion(currentMessageId: Value<String?>(replacementTip)),
          );
        }
      }

      return removedOps;
    });
  }

  /// Cancels one queued assistant completion from the chat UI. Unlike
  /// [cancelPendingCompletion], this is scoped to a single assistant placeholder
  /// and also removes parked `failed` ops so the failed-response affordance can
  /// be dismissed without touching other queued turns for the chat.
  Future<int> cancelQueuedCompletion(
    String chatId, {
    required String assistantMessageId,
  }) {
    return transaction(() async {
      if (assistantMessageId.isEmpty) return 0;

      final queued =
          await (select(_outboxDao.outboxOps)..where(
                (t) =>
                    t.chatId.equals(chatId) &
                    t.kind.equals(OutboxKind.requestCompletion.name) &
                    t.status.isIn(const [
                      OutboxStatus.pending,
                      OutboxStatus.failed,
                    ]),
              ))
              .get();
      if (queued.isEmpty) return 0;

      final matchingOps = [
        for (final op in queued)
          if (_requestCompletionAssistantId(op.payload) == assistantMessageId)
            op,
      ];
      if (matchingOps.isEmpty) return 0;
      final matchingSeqs = [for (final op in matchingOps) op.seq];

      final placeholder =
          await (select(messages)..where(
                (t) =>
                    t.chatId.equals(chatId) &
                    t.id.equals(assistantMessageId) &
                    t.role.equals('assistant'),
              ))
              .getSingleOrNull();

      final removedOps = await (delete(
        _outboxDao.outboxOps,
      )..where((t) => t.seq.isIn(matchingSeqs))).go();

      if (placeholder != null) {
        await _removeAssistantChildLink(
          chatId: chatId,
          parentId: placeholder.parentId,
          assistantMessageId: assistantMessageId,
        );

        await (delete(messages)..where(
              (t) => t.chatId.equals(chatId) & t.id.equals(assistantMessageId),
            ))
            .go();

        final chat = await getChat(chatId);
        await (update(chats)..where((t) => t.id.equals(chatId))).write(
          ChatsCompanion(
            currentMessageId: chat?.currentMessageId == assistantMessageId
                ? Value<String?>(placeholder.parentId)
                : const Value.absent(),
            dirty: const Value(true),
          ),
        );

        await _outboxDao.enqueue(kind: OutboxKind.updateChat, chatId: chatId);
      }

      return removedOps;
    });
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
      await _deleteChatRemapMetadata(chatId);
    });
  }

  Future<void> _deleteChatRemapMetadata(String chatId) async {
    await attachedDatabase.syncMetaDao.deleteChatRemapTarget(chatId);
    await attachedDatabase.syncMetaDao.deleteChatRemapTargetsForServer(chatId);
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
    'unmappableMessageOrder': rows.unmappableMessageOrder,
  };

  static int? _maxLastReadAt(int? local, int? server) {
    if (local == null && server == null) return null;
    return math.max(local ?? 0, server ?? 0);
  }

  static String? _requestCompletionAssistantId(String rawPayload) {
    try {
      final decoded = jsonDecode(rawPayload);
      if (decoded is Map && decoded['assistantMessageId'] is String) {
        final id = decoded['assistantMessageId'] as String;
        return id.isEmpty ? null : id;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _removeAssistantChildLink({
    required String chatId,
    required String? parentId,
    required String assistantMessageId,
  }) async {
    if (parentId == null || parentId.isEmpty || assistantMessageId.isEmpty) {
      return;
    }

    final parent =
        await (select(messages)
              ..where((t) => t.chatId.equals(chatId) & t.id.equals(parentId)))
            .getSingleOrNull();
    if (parent == null) return;

    final updatedPayload = _payloadWithoutChildLink(
      parent.payload,
      assistantMessageId,
    );
    if (updatedPayload == null) return;

    await (update(
      messages,
    )..where((t) => t.chatId.equals(chatId) & t.id.equals(parentId))).write(
      MessagesCompanion(
        payload: Value(updatedPayload),
        dirty: const Value(true),
      ),
    );
  }

  static String? _payloadWithoutChildLink(String rawPayload, String childId) {
    try {
      final decoded = jsonDecode(rawPayload);
      if (decoded is! Map) return null;

      final payload = Map<String, dynamic>.from(decoded);
      var changed = false;

      final topLevelChildren = _childrenIdsWithout(
        payload['childrenIds'],
        childId,
      );
      if (topLevelChildren != null) {
        payload['childrenIds'] = topLevelChildren;
        changed = true;
      }

      final metadata = payload['metadata'];
      if (metadata is Map) {
        final metadataMap = Map<String, dynamic>.from(metadata);
        final metadataChildren = _childrenIdsWithout(
          metadataMap['childrenIds'],
          childId,
        );
        if (metadataChildren != null) {
          metadataMap['childrenIds'] = metadataChildren;
          payload['metadata'] = metadataMap;
          changed = true;
        }
      }

      return changed ? jsonEncode(payload) : null;
    } catch (_) {
      return null;
    }
  }

  static List<dynamic>? _childrenIdsWithout(Object? raw, String childId) {
    if (raw is! List) return null;

    var changed = false;
    final children = <dynamic>[];
    for (final value in raw) {
      if (value == childId) {
        changed = true;
      } else {
        children.add(value);
      }
    }
    return changed ? children : null;
  }

  JoinedSelectStatement<HasResultSet, dynamic> _listProjection() {
    return selectOnly(chats)..addColumns([
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

  ChatListEntry _entryFromCustomRow(QueryRow row) {
    return ChatListEntry(
      id: row.read<String>('id'),
      title: row.read<String>('title'),
      createdAt: row.read<int>('created_at'),
      updatedAt: row.read<int>('updated_at'),
      pinned: row.read<bool>('pinned'),
      archived: row.read<bool>('archived'),
      folderId: row.readNullable<String>('folder_id'),
      lastReadAt: row.readNullable<int>('last_read_at'),
    );
  }
}
