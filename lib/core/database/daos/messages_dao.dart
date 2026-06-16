import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../mappers/chat_blob_mapper.dart';
import '../tables/chats.dart';
import '../tables/messages.dart';

part 'messages_dao.g.dart';

/// Message row accessor (CDT-RFC-001 §6, §10.2).
@DriftAccessor(tables: [Messages, Chats])
class MessagesDao extends DatabaseAccessor<AppDatabase>
    with _$MessagesDaoMixin {
  MessagesDao(super.db);

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

  /// Marks an assistant placeholder as submitted/completed without changing its
  /// content. Headless completions use this after the server accepts the
  /// request so replay can distinguish "already sent, awaiting pull" from a
  /// resumable partial stream checkpoint.
  Future<bool> markAssistantResponseDone({
    required String chatId,
    required String messageId,
  }) {
    return transaction(() async {
      final existing = await _messageById(chatId, messageId);
      if (existing == null) return false;

      final payload = _decodePayloadMap(existing.payload);
      final metadata = _asJsonMap(payload['metadata']);
      payload
        ..putIfAbsent('id', () => messageId)
        ..putIfAbsent('role', () => existing.role)
        ..putIfAbsent('content', () => existing.content)
        ..['isStreaming'] = false
        ..['done'] = true
        ..['metadata'] = <String, dynamic>{...metadata, 'responseDone': true};

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
    final existing =
        await (select(messages)
              ..where((t) => t.chatId.equals(row.chatId) & t.id.equals(row.id)))
            .getSingleOrNull();

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
