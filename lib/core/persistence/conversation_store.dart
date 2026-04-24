import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../utils/debug_logger.dart';
import 'database/app_database.dart';

/// Persists [Conversation] and [ChatMessage] records as rows in SQLite.
///
/// The hot fields (id, title, timestamps, pinned/archived, parent_id, role)
/// live in dedicated columns so they can be indexed and ordered cheaply.
/// Everything else round-trips through a `payload_json` blob — this preserves
/// full fidelity with the existing freezed models and keeps wire-compat with
/// OpenWebUI's nested JSON shape on the way out.
class ConversationStore {
  ConversationStore(this._database);

  final AppDatabase _database;

  Database get _db => _database.raw;

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns a lightweight list of conversations ordered by recency.
  ///
  /// Each result has its `messages` list empty — load the full conversation
  /// via [getConversation] when you need them. Pinned conversations sort to
  /// the top.
  Future<List<Conversation>> getAllSummaries({int? limit}) async {
    final rows = await _db.query(
      'conversations',
      orderBy: 'pinned DESC, updated_at DESC',
      limit: limit,
    );
    return rows.map(_decodeConversationRow).toList(growable: false);
  }

  /// Returns a fully hydrated conversation, with its messages ordered by
  /// timestamp ascending. Returns `null` if the conversation is not cached.
  Future<Conversation?> getConversation(String id) async {
    final convRows = await _db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (convRows.isEmpty) return null;

    final messageRows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [id],
      orderBy: 'timestamp ASC',
    );

    final conv = _decodeConversationRow(convRows.first);
    final messages = messageRows
        .map(_decodeMessageRow)
        .whereType<ChatMessage>()
        .toList(growable: false);
    return conv.copyWith(messages: messages);
  }

  /// Returns just the message IDs in a conversation (in storage order).
  /// Useful for cheap diff checks without decoding payloads.
  Future<List<String>> getMessageIds(String conversationId) async {
    final rows = await _db.query(
      'messages',
      columns: ['id'],
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
    );
    return rows.map((row) => row['id'] as String).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Upserts a single conversation along with its messages atomically.
  /// Messages no longer present in [conversation.messages] are removed.
  Future<void> upsertConversation(Conversation conversation) async {
    await _db.transaction((txn) async {
      await _upsertConversationInTxn(txn, conversation);
    });
  }

  /// Bulk variant of [upsertConversation]. Wraps everything in a single
  /// transaction so the drawer cache stays internally consistent.
  Future<void> upsertConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    await _db.transaction((txn) async {
      for (final conv in conversations) {
        await _upsertConversationInTxn(txn, conv);
      }
    });
  }

  Future<void> _upsertConversationInTxn(
    Transaction txn,
    Conversation conv,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.insert(
      'conversations',
      _encodeConversationRow(conv, cachedAtMillis: now),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final newIds = <String>{
      for (final msg in conv.messages) msg.id,
    };
    final existingIdRows = await txn.query(
      'messages',
      columns: ['id'],
      where: 'conversation_id = ?',
      whereArgs: [conv.id],
    );
    final existingIds = <String>{
      for (final row in existingIdRows) row['id'] as String,
    };

    final toDelete = existingIds.difference(newIds);
    if (toDelete.isNotEmpty) {
      final placeholders = List.filled(toDelete.length, '?').join(',');
      await txn.delete(
        'messages',
        where: 'conversation_id = ? AND id IN ($placeholders)',
        whereArgs: [conv.id, ...toDelete],
      );
    }

    for (final message in conv.messages) {
      await txn.insert(
        'messages',
        _encodeMessageRow(conv.id, message),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Append a single message to an existing conversation. Used by the
  /// granular write paths in chat_providers (Phase 3b).
  Future<void> appendMessage(String conversationId, ChatMessage message) async {
    await _db.insert(
      'messages',
      _encodeMessageRow(conversationId, message),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _touchConversation(conversationId);
  }

  /// Update an existing message in place. Conversation row is touched so
  /// the drawer's `updated_at` ordering reflects the change.
  Future<void> updateMessage(ChatMessage message) async {
    final convRows = await _db.query(
      'messages',
      columns: ['conversation_id'],
      where: 'id = ?',
      whereArgs: [message.id],
      limit: 1,
    );
    if (convRows.isEmpty) {
      DebugLogger.log(
        'updateMessage: ${message.id} not found',
        scope: 'persistence/db',
      );
      return;
    }
    final conversationId = convRows.first['conversation_id'] as String;
    await _db.insert(
      'messages',
      _encodeMessageRow(conversationId, message),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _touchConversation(conversationId);
  }

  /// Remove a single message from a conversation.
  Future<void> deleteMessage(String conversationId, String messageId) async {
    await _db.delete(
      'messages',
      where: 'conversation_id = ? AND id = ?',
      whereArgs: [conversationId, messageId],
    );
    await _touchConversation(conversationId);
  }

  /// Remove a conversation and all of its messages.
  Future<void> deleteConversation(String id) async {
    await _db.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Drop every conversation and message. Used by `clearAuthData`.
  Future<void> deleteAll() async {
    await _db.transaction((txn) async {
      await txn.delete('messages');
      await txn.delete('conversations');
    });
  }

  Future<void> _touchConversation(String conversationId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final preview = await _computePreview(conversationId);
    final count = Sqflite.firstIntValue(
      await _db.rawQuery(
        'SELECT COUNT(*) FROM messages WHERE conversation_id = ?',
        [conversationId],
      ),
    );
    await _db.update(
      'conversations',
      {
        'updated_at': now,
        'cached_at': now,
        'message_count': count ?? 0,
        'last_message_preview': preview,
      },
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<String?> _computePreview(String conversationId) async {
    final rows = await _db.query(
      'messages',
      columns: ['payload_json'],
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      final payload = jsonDecode(rows.first['payload_json'] as String);
      if (payload is Map && payload['content'] is String) {
        return _previewFromContent(payload['content'] as String);
      }
    } catch (_) {
      // Best-effort — leave preview empty.
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Row encode / decode
  // ---------------------------------------------------------------------------

  Map<String, Object?> _encodeConversationRow(
    Conversation conv, {
    required int cachedAtMillis,
  }) {
    final payload = conv.toJson();
    payload['messages'] = const <dynamic>[];

    final lastMessage = conv.messages.isEmpty ? null : conv.messages.last;
    final preview = lastMessage == null
        ? null
        : _previewFromContent(lastMessage.content);

    return <String, Object?>{
      'id': conv.id,
      'title': conv.title,
      'updated_at': conv.updatedAt.millisecondsSinceEpoch,
      'cached_at': cachedAtMillis,
      'pinned': conv.pinned ? 1 : 0,
      'archived': conv.archived ? 1 : 0,
      'message_count': conv.messages.length,
      'last_message_preview': preview,
      'payload_json': jsonEncode(payload),
    };
  }

  Conversation _decodeConversationRow(Map<String, Object?> row) {
    final raw = row['payload_json'] as String;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    decoded['messages'] = const <dynamic>[];
    return Conversation.fromJson(decoded);
  }

  Map<String, Object?> _encodeMessageRow(
    String conversationId,
    ChatMessage message,
  ) {
    final parentId = _readParentId(message.metadata);
    return <String, Object?>{
      'id': message.id,
      'conversation_id': conversationId,
      'role': message.role,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'parent_id': parentId,
      'payload_json': jsonEncode(message.toJson()),
    };
  }

  ChatMessage? _decodeMessageRow(Map<String, Object?> row) {
    try {
      final raw = row['payload_json'] as String;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return ChatMessage.fromJson(decoded);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to decode message ${row['id']}',
        scope: 'persistence/db',
        error: error,
        stackTrace: stack,
      );
      return null;
    }
  }

  String? _readParentId(Map<String, dynamic>? metadata) {
    if (metadata == null) return null;
    final value = metadata['parentId'];
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static String? _previewFromContent(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return null;
    final collapsed = trimmed.replaceAll(RegExp(r'\s+'), ' ');
    return collapsed.length <= 120 ? collapsed : '${collapsed.substring(0, 119)}…';
  }
}
