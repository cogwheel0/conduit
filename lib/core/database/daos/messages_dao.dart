import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../mappers/chat_blob_mapper.dart';
import '../models/chat_transcript_window.dart';
import '../tables/chats.dart';
import '../tables/messages.dart';

part 'messages_dao.g.dart';

/// Message row accessor (CDT-RFC-001 §6, §10.2).
@DriftAccessor(tables: [Messages, Chats])
class MessagesDao extends DatabaseAccessor<AppDatabase>
    with _$MessagesDaoMixin {
  MessagesDao(super.db);

  static const int _semanticSiblingRowCap = 200;
  static const int _siblingPredicateChunkSize = 200;

  /// WHERE chatId = ? ORDER BY createdAt ASC, orderIndex ASC. Never a watched
  /// SELECT without the chatId predicate (REQ §10.2).
  Stream<List<MessageRow>> watchForChat(String chatId) {
    return (_forChat(chatId)).watch();
  }

  /// Same order, one-shot.
  Future<List<MessageRow>> getForChat(String chatId) {
    return (_forChat(chatId)).get();
  }

  Future<MessageRow?> getMessage(String chatId, String messageId) {
    return _messageById(chatId, messageId);
  }

  /// Loads one page from the active branch, newest-first at the SQL boundary
  /// and chronological in the returned model. A cursor starts at its parent so
  /// adjacent pages never overlap.
  Future<MessageRowWindow> getActiveBranchPage(
    String chatId, {
    MessageWindowCursor? before,
    int limit = kChatTranscriptPageSize,
  }) async {
    final safeLimit = limit.clamp(1, 500).toInt();
    final primaryRows = await _activeBranchRows(
      chatId,
      before: before,
      limit: safeLimit + 1,
    );
    return _assembleWindow(chatId, primaryRows, safeLimit: safeLimit);
  }

  /// Watches a bounded latest window. Drift invalidates this query for changes
  /// to either the chat tip or any message row, then the same owner-scoped page
  /// query reconstructs versions.
  Stream<MessageRowWindow> watchActiveBranchWindow(
    String chatId, {
    int limit = kChatTranscriptPageSize,
  }) {
    final safeLimit = limit.clamp(1, 500).toInt();
    return customSelect(
      _activeBranchSql,
      variables: [
        Variable.withString(chatId),
        const Variable<String>(null),
        Variable.withString(chatId),
        Variable.withString(chatId),
        Variable.withInt(safeLimit + 1),
      ],
      readsFrom: {chats, messages},
    ).watch().asyncMap((rawRows) async {
      final primaryRows = rawRows
          .map((row) => messages.map(row.data))
          .toList(growable: false);
      return _assembleWindow(chatId, primaryRows, safeLimit: safeLimit);
    });
  }

  /// Explicit full-history boundary for completion, mutation, and export
  /// operations. The conversation parser follows the active tip and ignores
  /// abandoned branches while retaining them for sibling-version discovery.
  Future<List<MessageRow>> getCompleteActiveBranchRows(String chatId) async {
    final newestFirst = await _activeBranchRows(
      chatId,
      before: null,
      limit: kChatTranscriptMaxTraversalRows,
    );
    final primary = newestFirst.reversed.toList(growable: false);
    return (await _withVersionSiblings(
      chatId,
      primary,
      maxSiblingRows: null,
    )).rows;
  }

  Future<MessageRowWindow> _assembleWindow(
    String chatId,
    List<MessageRow> newestFirstRows, {
    required int safeLimit,
  }) async {
    final hasOlder = newestFirstRows.length > safeLimit;
    final selectedNewestFirst = hasOlder
        ? newestFirstRows.sublist(0, safeLimit)
        : newestFirstRows;
    final selected = selectedNewestFirst.reversed.toList(growable: false);
    final expanded = await _withVersionSiblings(
      chatId,
      selected,
      maxSiblingRows: _semanticSiblingRowCap,
    );
    return MessageRowWindow(
      primaryRows: List.unmodifiable(selected),
      rows: List.unmodifiable(expanded.rows),
      hasOlder: hasOlder,
      olderCursor: selected.isEmpty
          ? null
          : MessageWindowCursor(selected.first.id),
      semanticBoundaryTruncated: expanded.truncated,
    );
  }

  /// Marks an assistant placeholder as submitted/completed without changing its
  /// content. Headless completions use this after the server accepts the
  /// request so replay can distinguish "already sent, awaiting pull" from a
  /// resumable partial stream checkpoint.
  Future<bool> markAssistantResponseDone({
    required String chatId,
    required String messageId,
  }) {
    return _updateAssistantPayload(
      chatId: chatId,
      messageId: messageId,
      mutate: (payload) {
        final metadata = _asJsonMap(payload['metadata']);
        payload.remove('error');
        payload
          ..['isStreaming'] = false
          ..['done'] = true
          ..['metadata'] = <String, dynamic>{...metadata, 'responseDone': true};
      },
    );
  }

  /// Durability barrier written immediately before the completion POST.
  ///
  /// The marker means submission may have started; it deliberately does not
  /// claim that the server accepted the request or that a response landed. A
  /// recreated outbox runner recovers by pull only, preventing a duplicate POST
  /// across crashes in the ambiguous marker-to-response window.
  Future<bool> markAssistantCompletionSubmitted({
    required String chatId,
    required String messageId,
  }) {
    return _updateAssistantPayload(
      chatId: chatId,
      messageId: messageId,
      mutate: (payload) {
        final metadata = _asJsonMap(payload['metadata'])
          ..remove('responseDone');
        payload
          ..remove('error')
          ..remove('done')
          ..['isStreaming'] = true
          ..['metadata'] = <String, dynamic>{
            ...metadata,
            'completionSubmitted': true,
          };
      },
    );
  }

  /// Settles a submitted placeholder with an explicit recovery error when the
  /// accepted request cannot be drained or found on the server. A later server
  /// pull may still replace this row with the authoritative response.
  Future<bool> markAssistantCompletionRecoveryFailed({
    required String chatId,
    required String messageId,
    required String error,
  }) {
    return _updateAssistantPayload(
      chatId: chatId,
      messageId: messageId,
      mutate: (payload) {
        final metadata = _asJsonMap(payload['metadata']);
        payload
          ..['isStreaming'] = false
          ..['done'] = true
          ..['error'] = <String, dynamic>{'content': error}
          ..['metadata'] = <String, dynamic>{
            ...metadata,
            'completionSubmitted': true,
            'responseDone': true,
          };
      },
    );
  }

  Future<bool> _updateAssistantPayload({
    required String chatId,
    required String messageId,
    required void Function(Map<String, dynamic> payload) mutate,
  }) {
    return transaction(() async {
      final existing = await _messageById(chatId, messageId);
      if (existing == null) return false;

      final payload = _decodePayloadMap(existing.payload);
      payload
        ..putIfAbsent('id', () => messageId)
        ..putIfAbsent('role', () => existing.role)
        ..putIfAbsent('content', () => existing.content);
      mutate(payload);

      await (update(
        messages,
      )..where((t) => t.chatId.equals(chatId) & t.id.equals(messageId))).write(
        MessagesCompanion(
          payload: Value(jsonEncode(payload)),
          dirty: const Value(false),
        ),
      );
      return true;
    });
  }

  /// Local echo for D-07 (stream completion + pause checkpoint). One tx;
  /// caller holds the chat lock. No-op (returns false) when the chats row is
  /// absent. New rows get `orderIndex = max(order_index) + 1` for the chat;
  /// existing rows keep their orderIndex.
  ///
  /// Rows are written with `dirty = false`: in Phase 1 the server write still
  /// happens through the legacy API path, so no dirty rows may exist
  /// (RFC §7.4 line 2 — `upsertServerChat` fast-forward-replaces on that
  /// assumption). The outbox/dirty discipline arrives in Phase 2.
  Future<bool> upsertLocalEcho(MessageRowData row) {
    return transaction(() async {
      final chatExists = await (select(
        chats,
      )..where((t) => t.id.equals(row.chatId))).getSingleOrNull();
      if (chatExists == null) return false;

      await _upsertLocalEchoRow(row);
      return true;
    });
  }

  /// D-07 completed-turn echo. Caller holds the chat lock. Reads the current
  /// active branch tip, links the echoed user to that tip, links the assistant
  /// to the echoed user, and advances chats.currentMessageId to the assistant
  /// in the same transaction as the message writes. Replaying the same turn is
  /// idempotent: existing turn rows are used to recover the pre-turn tip so the
  /// user row is never re-parented to its own assistant.
  Future<bool> upsertLocalEchoTurn({
    required String chatId,
    required MessageRowData? user,
    required MessageRowData assistant,
  }) {
    return transaction(() async {
      final chat = await (select(
        chats,
      )..where((t) => t.id.equals(chatId))).getSingleOrNull();
      if (chat == null) return false;

      final previousTip = await _previousTipBeforeEchoTurn(
        chatId: chatId,
        currentTip: chat.currentMessageId,
        userId: user?.id,
        assistantId: assistant.id,
      );
      if (user != null) {
        await _upsertLocalEchoRow(_withParent(user, previousTip));
      }
      await _upsertLocalEchoRow(
        _withParent(assistant, user?.id ?? previousTip),
      );
      await (update(chats)..where((t) => t.id.equals(chatId))).write(
        ChatsCompanion(currentMessageId: Value(assistant.id)),
      );
      return true;
    });
  }

  Future<String?> _previousTipBeforeEchoTurn({
    required String chatId,
    required String? currentTip,
    required String? userId,
    required String assistantId,
  }) async {
    if (currentTip == assistantId) {
      final assistant = await _messageById(chatId, assistantId);
      final assistantParent = _safeTip(
        assistant?.parentId,
        userId: userId,
        assistantId: assistantId,
      );
      if (userId != null && assistant?.parentId == userId) {
        final user = await _messageById(chatId, userId);
        return _safeTip(
          user?.parentId,
          userId: userId,
          assistantId: assistantId,
        );
      }
      return assistantParent;
    }

    if (userId != null && currentTip == userId) {
      final user = await _messageById(chatId, userId);
      return _safeTip(user?.parentId, userId: userId, assistantId: assistantId);
    }

    return _safeTip(currentTip, userId: userId, assistantId: assistantId);
  }

  Future<MessageRow?> _messageById(String chatId, String messageId) {
    return (select(messages)
          ..where((t) => t.chatId.equals(chatId) & t.id.equals(messageId)))
        .getSingleOrNull();
  }

  static const String _activeBranchSql = '''
WITH RECURSIVE branch(id, parent_id, depth, path) AS (
  SELECT
    seed.id,
    seed.parent_id,
    0,
    ',' || seed.id || ','
  FROM messages AS seed
  JOIN chats AS owner ON owner.id = seed.chat_id
  WHERE owner.id = ?
    AND seed.id = COALESCE(
      (
        SELECT cursor_row.parent_id
        FROM messages AS cursor_row
        WHERE cursor_row.chat_id = owner.id
          AND cursor_row.id = ?
      ),
      (
        SELECT current_row.id
        FROM messages AS current_row
        WHERE current_row.chat_id = owner.id
          AND current_row.id = owner.current_message_id
      ),
      (
        SELECT fallback.id
        FROM messages AS fallback
        WHERE fallback.chat_id = owner.id
        ORDER BY
          fallback.created_at DESC,
          fallback.order_index DESC,
          fallback.id DESC
        LIMIT 1
      )
    )

  UNION ALL

  SELECT
    parent.id,
    parent.parent_id,
    branch.depth + 1,
    branch.path || parent.id || ','
  FROM branch
  JOIN messages AS parent
    ON parent.chat_id = ?
   AND parent.id = branch.parent_id
  WHERE branch.depth < 9999
    AND instr(branch.path, ',' || parent.id || ',') = 0
)
SELECT message.*
FROM branch
JOIN messages AS message
  ON message.chat_id = ?
 AND message.id = branch.id
ORDER BY branch.depth ASC
LIMIT ?
''';

  Future<List<MessageRow>> _activeBranchRows(
    String chatId, {
    required MessageWindowCursor? before,
    required int limit,
  }) async {
    if (before != null) {
      final cursorRow = await _messageById(chatId, before.messageId);
      if (cursorRow?.parentId == null) return const [];
    }
    final rows = await customSelect(
      _activeBranchSql,
      variables: [
        Variable.withString(chatId),
        before == null
            ? const Variable<String>(null)
            : Variable.withString(before.messageId),
        Variable.withString(chatId),
        Variable.withString(chatId),
        Variable.withInt(limit),
      ],
      readsFrom: {chats, messages},
    ).get();
    return rows.map((row) => messages.map(row.data)).toList(growable: false);
  }

  Future<({List<MessageRow> rows, bool truncated})> _withVersionSiblings(
    String chatId,
    List<MessageRow> primaryRows, {
    required int? maxSiblingRows,
  }) async {
    if (primaryRows.isEmpty) {
      return (rows: const <MessageRow>[], truncated: false);
    }
    final siblingGroups = <(String?, String)>{
      for (final row in primaryRows) (row.parentId, row.role),
    }.toList(growable: false);
    final siblingRows = <QueryRow>[];
    var truncated = false;

    for (
      var offset = 0;
      offset < siblingGroups.length;
      offset += _siblingPredicateChunkSize
    ) {
      if (maxSiblingRows != null && siblingRows.length > maxSiblingRows) {
        truncated = true;
        break;
      }
      final chunk = siblingGroups.sublist(
        offset,
        (offset + _siblingPredicateChunkSize)
            .clamp(0, siblingGroups.length)
            .toInt(),
      );
      final clauses = <String>[];
      final variables = <Variable>[Variable.withString(chatId)];
      for (final group in chunk) {
        final (parentId, role) = group;
        if (parentId == null) {
          clauses.add('(parent_id IS NULL AND role = ?)');
        } else {
          clauses.add('(parent_id = ? AND role = ?)');
          variables.add(Variable.withString(parentId));
        }
        variables.add(Variable.withString(role));
      }
      final remaining = maxSiblingRows == null
          ? null
          : maxSiblingRows + 1 - siblingRows.length;
      final siblingLimitClause = remaining == null ? '' : ' LIMIT $remaining';
      siblingRows.addAll(
        await customSelect(
          'SELECT * FROM messages '
          'WHERE chat_id = ? AND (${clauses.join(' OR ')}) '
          'ORDER BY created_at ASC, order_index ASC, id ASC'
          '$siblingLimitClause',
          variables: variables,
          readsFrom: {messages},
        ).get(),
      );
    }
    if (maxSiblingRows != null && siblingRows.length > maxSiblingRows) {
      truncated = true;
    }
    final retainedSiblingRows = truncated
        ? siblingRows.take(maxSiblingRows!)
        : siblingRows;
    final byId = <String, MessageRow>{
      for (final row in primaryRows) row.id: row,
      for (final row in retainedSiblingRows.map(
        (row) => messages.map(row.data),
      ))
        row.id: row,
    };
    final result = byId.values.toList()
      ..sort((left, right) {
        final byCreated = left.createdAt.compareTo(right.createdAt);
        if (byCreated != 0) return byCreated;
        final byOrder = left.orderIndex.compareTo(right.orderIndex);
        if (byOrder != 0) return byOrder;
        return left.id.compareTo(right.id);
      });
    return (rows: result, truncated: truncated);
  }

  Map<String, dynamic> _decodePayloadMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return _asJsonMap(decoded);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _asJsonMap(Object? value) {
    if (value is Map<String, dynamic>) return Map<String, dynamic>.from(value);
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }

  String? _safeTip(
    String? tip, {
    required String? userId,
    required String assistantId,
  }) {
    if (tip == null || tip == userId || tip == assistantId) {
      return null;
    }
    return tip;
  }

  Future<void> _upsertLocalEchoRow(MessageRowData row) async {
    final existing = await _messageById(row.chatId, row.id);

    final int orderIndex;
    if (existing != null) {
      orderIndex = existing.orderIndex;
    } else {
      final maxExpr = messages.orderIndex.max();
      final maxQuery = selectOnly(messages)
        ..addColumns([maxExpr])
        ..where(messages.chatId.equals(row.chatId));
      final maxRow = await maxQuery.getSingle();
      orderIndex = (maxRow.read(maxExpr) ?? -1) + 1;
    }

    await into(messages).insertOnConflictUpdate(
      MessagesCompanion.insert(
        id: row.id,
        chatId: row.chatId,
        parentId: Value(row.parentId),
        role: row.role,
        content: row.content,
        model: Value(row.model),
        createdAt: row.createdAt,
        orderIndex: orderIndex,
        payload: jsonEncode(row.payload),
        dirty: const Value(false),
      ),
    );
  }

  MessageRowData _withParent(MessageRowData row, String? parentId) {
    return MessageRowData(
      id: row.id,
      chatId: row.chatId,
      parentId: parentId,
      role: row.role,
      content: row.content,
      model: row.model,
      createdAt: row.createdAt,
      orderIndex: row.orderIndex,
      payload: Map<String, dynamic>.from(row.payload)..['parentId'] = parentId,
    );
  }

  SimpleSelectStatement<$MessagesTable, MessageRow> _forChat(String chatId) {
    return select(messages)
      ..where((t) => t.chatId.equals(chatId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.createdAt),
        (t) => OrderingTerm.asc(t.orderIndex),
      ]);
  }
}
