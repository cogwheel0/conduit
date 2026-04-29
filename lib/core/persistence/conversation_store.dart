import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../utils/debug_logger.dart';
import 'database/app_database.dart';

/// Lifecycle of an outbound message. Stored on the message row itself —
/// SQLite is the single source of truth for whether a send is in flight,
/// retrying, or terminal. There is no separate Hive task queue.
enum MessageSendStatus {
  /// Server has acknowledged the message. Default for any row written from
  /// a server payload.
  sent,

  /// User triggered the send; the worker is either streaming now or about
  /// to be. Survives app restart so a force-quit mid-send becomes a retry.
  sending,

  /// Last attempt failed transiently (network/timeout/5xx). [sendNextAt] holds
  /// the scheduled retry time; the worker will pick it up on its next tick or
  /// on connectivity restore.
  failed,

  /// Last attempt failed in a way that won't succeed on retry (4xx auth /
  /// validation). Bubble shows a permanent error; user must edit and resend
  /// or dismiss.
  permanentFailed;

  static MessageSendStatus fromDb(String? raw) => switch (raw) {
    'sending' => MessageSendStatus.sending,
    'failed' => MessageSendStatus.failed,
    'permanent_failed' => MessageSendStatus.permanentFailed,
    _ => MessageSendStatus.sent,
  };

  String toDb() => switch (this) {
    MessageSendStatus.sent => 'sent',
    MessageSendStatus.sending => 'sending',
    MessageSendStatus.failed => 'failed',
    MessageSendStatus.permanentFailed => 'permanent_failed',
  };
}

/// Snapshot of a row in the outbox view. Used by [MessageOutbox] to decide
/// what to send next; carries enough to reconstruct the original send call.
class PendingMessage {
  PendingMessage({
    required this.messageId,
    required this.conversationId,
    required this.status,
    required this.attempt,
    this.nextAt,
    this.error,
    required this.message,
  });

  final String messageId;
  final String conversationId;
  final MessageSendStatus status;
  final int attempt;
  final DateTime? nextAt;
  final String? error;
  final ChatMessage message;
}

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

    // Local-first: messages whose `send_status` is anything other than 'sent'
    // are local writes the server hasn't seen yet (queued, in-flight, failed,
    // permanent-failed). A passive sync that happens to land before the
    // outbox drains MUST NOT wipe them — that would make the user's
    // just-tapped send vanish.
    //
    // IMPORTANT: this read MUST happen before any write to the conversations
    // table — `ConflictAlgorithm.replace` on conversations triggers
    // `ON DELETE CASCADE` and would wipe the messages we're trying to
    // inspect. For the same reason we use a plain UPDATE / INSERT for the
    // header row below instead of REPLACE.
    final existingRows = await txn.query(
      'messages',
      columns: ['id', 'send_status'],
      where: 'conversation_id = ?',
      whereArgs: [conv.id],
    );
    final existingIds = <String>{};
    final protectedIds = <String>{};
    for (final row in existingRows) {
      final id = row['id'] as String;
      existingIds.add(id);
      final status = MessageSendStatus.fromDb(row['send_status'] as String?);
      if (status != MessageSendStatus.sent) {
        protectedIds.add(id);
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
      // Skip overwriting a row that's still in the outbox. The server's
      // payload doesn't know about it yet; once the worker reaches `sent`,
      // the next sync overwrites with the authoritative version.
      if (protectedIds.contains(message.id)) continue;
      await _upsertMessageRow(txn, conv.id, message);
    }
  }

  /// UPSERT a message row, preserving the row's outbox state on conflict.
  ///
  /// The default flow (server sync, streaming updates, edits) must NOT
  /// reset `send_status` or the retry counters — those are owned by the
  /// outbox's own writes (`markSending`, `markSent`, `scheduleRetry`,
  /// `markPermanentFailed`). For brand-new sends, callers should write the
  /// row first via this helper (which leaves status at the column DEFAULT
  /// of 'sent') and then call [markSending] to flip it. Or use
  /// [insertMessageAsSending] which does both atomically.
  Future<void> _upsertMessageRow(
    DatabaseExecutor exec,
    String conversationId,
    ChatMessage message,
  ) async {
    final parentId = _readParentId(message.metadata);
    final payload = jsonEncode(message.toJson());
    final ts = message.timestamp.millisecondsSinceEpoch;
    await exec.rawInsert(
      '''
      INSERT INTO messages (
        id, conversation_id, role, timestamp, parent_id, payload_json
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        conversation_id = excluded.conversation_id,
        role = excluded.role,
        timestamp = excluded.timestamp,
        parent_id = excluded.parent_id,
        payload_json = excluded.payload_json
      ''',
      [message.id, conversationId, message.role, ts, parentId, payload],
    );
  }

  /// Insert (or update) [message] under [conversationId] AND set its
  /// `send_status` to 'sending' atomically. Used by the chat input on a
  /// fresh send so the bubble is durably outbound before any network work.
  Future<void> insertMessageAsSending({
    required String conversationId,
    required ChatMessage message,
  }) async {
    final parentId = _readParentId(message.metadata);
    final payload = jsonEncode(message.toJson());
    final ts = message.timestamp.millisecondsSinceEpoch;
    await _db.rawInsert(
      '''
      INSERT INTO messages (
        id, conversation_id, role, timestamp, parent_id, payload_json,
        send_status, send_attempt, send_next_at, send_error
      ) VALUES (?, ?, ?, ?, ?, ?, 'sending', 0, NULL, NULL)
      ON CONFLICT(id) DO UPDATE SET
        conversation_id = excluded.conversation_id,
        role = excluded.role,
        timestamp = excluded.timestamp,
        parent_id = excluded.parent_id,
        payload_json = excluded.payload_json,
        send_status = 'sending',
        send_attempt = 0,
        send_next_at = NULL,
        send_error = NULL
      ''',
      [message.id, conversationId, message.role, ts, parentId, payload],
    );
    await _touchConversation(conversationId);
  }

  /// Append a single message to an existing conversation. Used by the
  /// granular write paths in chat_providers (Phase 3b).
  Future<void> appendMessage(String conversationId, ChatMessage message) async {
    await _upsertMessageRow(_db, conversationId, message);
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
      await _upsertMessageRow(txn, scaffold.id, message);
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
    await _upsertMessageRow(_db, conversationId, message);
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

  // ---------------------------------------------------------------------------
  // Outbox — replaces the Hive task queue for sendText. SQLite is the single
  // source of truth for which messages are queued, retrying, or terminal.
  // ---------------------------------------------------------------------------

  /// Mark an existing message row as outbound. Called when the user taps send,
  /// before any network work, so the bubble survives a force-quit.
  ///
  /// Resets retry counters because a fresh send is starting (the row may have
  /// been in `failed` state from a prior attempt). The actual retry-with-
  /// backoff path uses [scheduleRetry] instead, which preserves [attempt].
  Future<void> markSending(String messageId) async {
    await _db.update(
      'messages',
      {
        'send_status': MessageSendStatus.sending.toDb(),
        'send_attempt': 0,
        'send_next_at': null,
        'send_error': null,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Mark a message as fully delivered (server has acknowledged). Clears all
  /// retry state. Called from the worker's success branch.
  Future<void> markSent(String messageId) async {
    await _db.update(
      'messages',
      {
        'send_status': MessageSendStatus.sent.toDb(),
        'send_attempt': 0,
        'send_next_at': null,
        'send_error': null,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Schedule a retry for a transient failure. The worker will pick this row
  /// up after [nextAt] passes (or immediately when connectivity is restored).
  Future<void> scheduleRetry({
    required String messageId,
    required int attempt,
    required DateTime nextAt,
    required String error,
  }) async {
    await _db.update(
      'messages',
      {
        'send_status': MessageSendStatus.failed.toDb(),
        'send_attempt': attempt,
        'send_next_at': nextAt.millisecondsSinceEpoch,
        'send_error': error,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Mark a message as terminally failed — retrying won't help (4xx, auth).
  /// The bubble shows the error and offers a manual retry which transitions
  /// the row back to `sending`.
  Future<void> markPermanentFailed({
    required String messageId,
    required String error,
  }) async {
    await _db.update(
      'messages',
      {
        'send_status': MessageSendStatus.permanentFailed.toDb(),
        'send_next_at': null,
        'send_error': error,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Cancel a pending or failed send (user dismissed). Just deletes the row
  /// — the conversation remains, but the abandoned attempt is gone.
  Future<void> cancelPending(String messageId) async {
    await _db.delete('messages', where: 'id = ?', whereArgs: [messageId]);
  }

  /// Read send status for one message. Returns `sent` for unknown ids so
  /// callers don't have to handle null specially.
  Future<MessageSendStatus> getSendStatus(String messageId) async {
    final rows = await _db.query(
      'messages',
      columns: ['send_status'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return MessageSendStatus.sent;
    return MessageSendStatus.fromDb(rows.first['send_status'] as String?);
  }

  /// All rows currently in the outbox (sending or failed) regardless of
  /// conversation, ordered by timestamp ASC so older queued sends drain first.
  /// Used by the worker on bootstrap and after each tick.
  Future<List<PendingMessage>> pendingMessages() async {
    final rows = await _db.query(
      'messages',
      where: "send_status IN ('sending', 'failed')",
      orderBy: 'timestamp ASC',
    );
    return rows.map(_decodePendingRow).whereType<PendingMessage>().toList(
      growable: false,
    );
  }

  /// Stream of all pending message ids per conversation, used by the
  /// active-branch resolver to know which messages should override the
  /// server's currentId. Lightweight — no payload decode.
  Future<Map<String, List<String>>> pendingMessageIdsByConversation() async {
    final rows = await _db.query(
      'messages',
      columns: ['id', 'conversation_id', 'timestamp'],
      where: "send_status IN ('sending', 'failed', 'permanent_failed')",
      orderBy: 'timestamp ASC',
    );
    final result = <String, List<String>>{};
    for (final row in rows) {
      final convId = row['conversation_id'] as String;
      result.putIfAbsent(convId, () => <String>[]).add(row['id'] as String);
    }
    return result;
  }

  PendingMessage? _decodePendingRow(Map<String, Object?> row) {
    final message = _decodeMessageRow(row);
    if (message == null) return null;
    final nextAtMillis = row['send_next_at'] as int?;
    return PendingMessage(
      messageId: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      status: MessageSendStatus.fromDb(row['send_status'] as String?),
      attempt: (row['send_attempt'] as int?) ?? 0,
      nextAt: nextAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(nextAtMillis),
      error: row['send_error'] as String?,
      message: message,
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
