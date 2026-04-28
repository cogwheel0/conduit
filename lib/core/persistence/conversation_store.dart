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

  /// Phase 4b — local full-text search across conversations.
  ///
  /// Combines two sources:
  ///   * **Title match** — substring LIKE on `conversations.title`. Cheap
  ///     scan; the conversations table is small (hundreds at most).
  ///   * **Message body match** — FTS5 search over `messages_fts` joined
  ///     back to `messages.conversation_id`. Returns the parent
  ///     conversation for any message whose content matches.
  ///
  /// Results are deduped by conversation id, sorted by `pinned DESC,
  /// updated_at DESC` to mirror the drawer's main listing order, and
  /// capped at [limit]. Archived conversations are excluded by default.
  ///
  /// The returned summaries have `messages` empty — callers needing
  /// the full conversation should follow up with [getConversation].
  ///
  /// Returns an empty list for an empty / whitespace-only query.
  Future<List<Conversation>> searchConversations(
    String query, {
    int limit = 50,
    bool includeArchived = false,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    // Build the FTS5 MATCH expression. We treat each whitespace-separated
    // token as required and append `*` so prefix matches hit (`hel*`
    // matches `hello`). FTS5 special characters are stripped so user
    // input can never inject query operators or unbalanced quotes.
    final ftsQuery = _toFtsMatchExpression(trimmed);
    if (ftsQuery.isEmpty) {
      return _searchByTitleOnly(
        trimmed,
        limit: limit,
        includeArchived: includeArchived,
      );
    }

    final archivedClause = includeArchived ? '' : 'AND c.archived = 0';
    final sql =
        '''
      WITH hits AS (
        SELECT c.id AS id
        FROM conversations c
        WHERE c.title LIKE ? COLLATE NOCASE $archivedClause

        UNION

        SELECT m.conversation_id AS id
        FROM messages_fts
        JOIN messages m ON m.rowid = messages_fts.rowid
        JOIN conversations c ON c.id = m.conversation_id
        WHERE messages_fts MATCH ? $archivedClause
      )
      SELECT c.*
      FROM conversations c
      JOIN hits h ON h.id = c.id
      ORDER BY c.pinned DESC, c.updated_at DESC
      LIMIT ?
    ''';

    try {
      final rows = await _db.rawQuery(sql, ['%$trimmed%', ftsQuery, limit]);
      return rows.map(_decodeConversationRow).toList(growable: false);
    } on DatabaseException catch (error, stack) {
      DebugLogger.error(
        'Local search failed (query=${trimmed.length} chars)',
        scope: 'persistence/db',
        error: error,
        stackTrace: stack,
      );
      // Fall back to title-only — better to return something than nothing.
      return _searchByTitleOnly(
        trimmed,
        limit: limit,
        includeArchived: includeArchived,
      );
    }
  }

  Future<List<Conversation>> _searchByTitleOnly(
    String trimmedQuery, {
    required int limit,
    required bool includeArchived,
  }) async {
    final archivedClause = includeArchived ? '' : 'AND archived = 0';
    final rows = await _db.rawQuery(
      '''
      SELECT * FROM conversations
      WHERE title LIKE ? COLLATE NOCASE $archivedClause
      ORDER BY pinned DESC, updated_at DESC
      LIMIT ?
      ''',
      ['%$trimmedQuery%', limit],
    );
    return rows.map(_decodeConversationRow).toList(growable: false);
  }

  /// Strips FTS5 syntax characters from user input and turns each token
  /// into a prefix match. Empty tokens are dropped; if all tokens are
  /// stripped to nothing, returns an empty string — callers must skip
  /// the FTS query in that case.
  static String _toFtsMatchExpression(String input) {
    final sanitized = input.replaceAll(RegExp(r'''[\"\*\(\):\^]'''), ' ');
    final tokens = sanitized
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"$t"*')
        .toList(growable: false);
    if (tokens.isEmpty) return '';
    return tokens.join(' ');
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

  /// Replaces the cached conversation set with [conversations], pruning any
  /// previously-cached conversations whose ids are not in the new list.
  ///
  /// This is the right call when [conversations] is the canonical full server
  /// snapshot (e.g. after a `getConversations()` refresh). It propagates
  /// web-side deletes into the local cache so a conversation deleted on the
  /// web app actually disappears from the mobile drawer.
  ///
  /// Foreign-key cascade on the messages table cleans up message rows for
  /// pruned conversations.
  Future<void> replaceAllConversations(
    List<Conversation> conversations,
  ) async {
    await _db.transaction((txn) async {
      final keepIds = <String>{for (final c in conversations) c.id};
      final existingRows = await txn.query('conversations', columns: ['id']);
      final existingIds = <String>{
        for (final row in existingRows) row['id'] as String,
      };
      final toDelete = existingIds.difference(keepIds);
      if (toDelete.isNotEmpty) {
        final placeholders = List.filled(toDelete.length, '?').join(',');
        await txn.delete(
          'conversations',
          where: 'id IN ($placeholders)',
          whereArgs: toDelete.toList(),
        );
      }
      for (final conv in conversations) {
        await _upsertConversationInTxn(txn, conv);
      }
    });
  }

  Future<void> _upsertConversationInTxn(
    Transaction txn,
    Conversation conv,
  ) async {
    final newIds = <String>{for (final msg in conv.messages) msg.id};

    // Local-first: messages tagged metadata.localPending=true are queued
    // sends that the server hasn't acknowledged yet. A passive sync that
    // happens to land before the queue drains MUST NOT wipe them, otherwise
    // the user sees their just-sent text vanish. We read the existing rows'
    // payload_json to discover which ids are protected, exclude them from
    // both the deletion set and the replace pass.
    //
    // IMPORTANT: this read MUST happen before any write to the conversations
    // table — `ConflictAlgorithm.replace` on conversations triggers
    // `ON DELETE CASCADE` and would wipe the messages we're trying to
    // inspect. For the same reason we use a plain UPDATE / INSERT for the
    // header row below instead of REPLACE.
    final existingRows = await txn.query(
      'messages',
      columns: ['id', 'payload_json'],
      where: 'conversation_id = ?',
      whereArgs: [conv.id],
    );
    final existingIds = <String>{};
    final protectedIds = <String>{};
    for (final row in existingRows) {
      final id = row['id'] as String;
      existingIds.add(id);
      final payload = row['payload_json'] as String?;
      if (payload == null || payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          final meta = decoded['metadata'];
          if (meta is Map && meta['localPending'] == true) {
            protectedIds.add(id);
          }
        }
      } catch (_) {
        // Malformed row — leave it alone. Better to keep stale data than
        // accidentally classify it as deletable.
      }
    }

    // Now upsert the conversation header without using REPLACE (which would
    // CASCADE-delete the messages we just inspected). Insert-or-ignore +
    // update covers both create and update.
    final now = DateTime.now().millisecondsSinceEpoch;
    final headerRow = _encodeConversationRow(conv, cachedAtMillis: now);
    final inserted = await txn.insert(
      'conversations',
      headerRow,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (inserted == 0) {
      // Row already exists — UPDATE in place so FK CASCADE doesn't fire.
      final updateValues = Map<String, Object?>.from(headerRow)..remove('id');
      await txn.update(
        'conversations',
        updateValues,
        where: 'id = ?',
        whereArgs: [conv.id],
      );
    }

    final toDelete = existingIds.difference(newIds).difference(protectedIds);
    if (toDelete.isNotEmpty) {
      final placeholders = List.filled(toDelete.length, '?').join(',');
      await txn.delete(
        'messages',
        where: 'conversation_id = ? AND id IN ($placeholders)',
        whereArgs: [conv.id, ...toDelete],
      );
    }

    for (final message in conv.messages) {
      // Skip overwriting a row that is currently marked local-pending. The
      // server's payload doesn't know about the queued send yet; once the
      // task succeeds and the flag is cleared, the next sync will overwrite
      // this row with the authoritative version.
      if (protectedIds.contains(message.id)) continue;
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

  /// Upserts [message] under [scaffold.id], creating a header row from
  /// [scaffold] first if the conversation does not yet exist.
  ///
  /// Used by the chat send/streaming path (Phase 3b) where messages can
  /// land before the full conversation has been cached. The scaffold's
  /// `messages` list is ignored — only the header fields seed the row.
  /// If the row already exists, the scaffold is discarded and the
  /// existing header is left intact.
  Future<void> upsertMessageEnsuringConversation({
    required Conversation scaffold,
    required ChatMessage message,
  }) async {
    await _db.transaction((txn) async {
      final existing = await txn.query(
        'conversations',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [scaffold.id],
        limit: 1,
      );
      if (existing.isEmpty) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final header = scaffold.copyWith(messages: const []);
        await txn.insert(
          'conversations',
          _encodeConversationRow(header, cachedAtMillis: now),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.insert(
        'messages',
        _encodeMessageRow(scaffold.id, message),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await _touchConversation(scaffold.id);
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
    await _db.delete('conversations', where: 'id = ?', whereArgs: [id]);
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
    return collapsed.length <= 120
        ? collapsed
        : '${collapsed.substring(0, 119)}…';
  }
}
