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

      final existing = await (select(messages)..where(
            (t) => t.chatId.equals(row.chatId) & t.id.equals(row.id),
          ))
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
      return true;
    });
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
