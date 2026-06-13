import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../database/mappers/chat_blob_mapper.dart';
import '../utils/debug_logger.dart';

/// A completed local->server id rewrite (CDT-RFC-001 §7.3).
///
/// Emitted on [IdRemapper.remapEvents] AFTER the rewrite transaction commits,
/// so a route/active-chat consumer can swap `local:<uuid>` for [toId] without
/// a visible rebuild (Wiring C).
class RemapEvent {
  const RemapEvent({
    required this.fromId,
    required this.toId,
    required this.entityKind,
  });

  /// The pre-remap local id (`local:<uuid>`).
  final String fromId;

  /// The server-minted id the local rows were rewritten to.
  final String toId;

  /// `'chat'` or `'folder'`.
  final String entityKind;

  @override
  String toString() =>
      'RemapEvent($entityKind: $fromId -> $toId)';
}

/// Stable createChat fingerprint for the §7.3 crash-heal path.
///
/// Definition (BINDING, must match what a pulled server blob would hash to):
/// sha256 hex of the canonical-JSON encoding of `ChatBlobMapper.rowsToBlob`,
/// with map keys sorted recursively, EXCLUDING the volatile top-level keys the
/// remap/server rewrite: `timestamp` AND `id`. The top-level `id` is exactly
/// what createChat sends as `''` and the §7.3 remap rewrites to the server
/// uuid, so the server stores it verbatim in `chat` (vendored
/// `Chats.insert_new_chat` persists `form_data.chat` as-is). Hashing it would
/// make the local op fingerprint (no `id`, built from local rows) differ from
/// the pulled-back digest (`id: ''`), so the crash-heal would never match.
/// Excluding it makes "the same function run over `blobToRows(serverBlob)`
/// after a pull yields the identical digest" actually hold. Envelope
/// `created_at`/`updated_at` are not part of the blob and never participate.
String createChatContentHash(ChatRows rows) {
  final blob = ChatBlobMapper.rowsToBlob(rows);
  final stable = Map<String, dynamic>.of(blob)
    ..remove('timestamp')
    ..remove('id');
  return sha256.convert(utf8.encode(_canonicalJson(stable))).toString();
}

/// Deterministic JSON: object keys sorted ascending, recursively.
String _canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(value, buffer);
  return buffer.toString();
}

void _writeCanonical(Object? value, StringBuffer out) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    out.write('{');
    var first = true;
    for (final key in keys) {
      if (!first) out.write(',');
      first = false;
      out.write(jsonEncode(key));
      out.write(':');
      _writeCanonical(value[key], out);
    }
    out.write('}');
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _writeCanonical(value[i], out);
    }
    out.write(']');
  } else {
    // Scalars (String/num/bool/null) encode deterministically already.
    out.write(jsonEncode(value));
  }
}

/// Single-transaction local->server id remap (CDT-RFC-001 §7.3).
///
/// Each remap rewrites, in ONE drift transaction committed BEFORE the running
/// `createChat`/`createFolder` outbox op is marked done:
///   * the chat (or folder) row's primary key,
///   * every child `messages.chatId` (chats) / `chats.folderId` (folders),
///   * every pending|inFlight outbox op's `chat_id` column (which holds the
///     folder id for folder ops),
///   * (Phase 4 seam) FTS rows `local:<uuid>` -> serverId.
///
/// Because `chats.id` is a PK and `messages.chatId` is an FK with cascade, the
/// PK cannot be updated in place while children exist. The transaction instead
/// INSERT-copies a row at the server id, repoints the children, then deletes
/// the local row (which now has no children). Callers MUST already hold the
/// chat/folder lock for BOTH the local id and the server id around the remap.
class IdRemapper {
  IdRemapper(this._db);

  final AppDatabase _db;
  final StreamController<RemapEvent> _events =
      StreamController<RemapEvent>.broadcast();

  /// Fires once per committed remap (Wiring C consumer).
  Stream<RemapEvent> get remapEvents => _events.stream;

  /// Releases the broadcast controller. Tests close the db; production keeps
  /// the keepAlive provider alive for the db lifetime.
  Future<void> dispose() => _events.close();

  /// Rewrites chat [localId] to [serverId] in one transaction (§7.3).
  Future<void> remapChat({
    required String localId,
    required String serverId,
    required int serverCreatedAt,
    required int serverUpdatedAt,
  }) async {
    if (localId == serverId) {
      // Idempotent no-op: a prior crash-heal already adopted the server id.
      return;
    }
    await _db.transaction(() async {
      final local = await _getChat(localId);
      if (local == null) {
        // The local row is already gone (a prior pull may have merged the
        // server chat and a previous remap completed). Still repoint any
        // pending ops + leftover messages defensively, then return.
        await _rewriteMessagesChatId(localId, serverId);
        await _rewriteOutboxChatId(localId, serverId);
        return;
      }

      final serverRow = await _getChat(serverId);
      if (serverRow != null) {
        // Crash-heal collision: a pull already inserted the server chat.
        // Keep exactly one row at serverId, preferring the side that carries
        // the messages (BINDING simplest-correct rule §7.3 step 1).
        final serverMsgCount = await _messageCount(serverId);
        if (serverMsgCount == 0) {
          // Server row is a bodiless stub; prefer the local rows. Drop the
          // stub, then fall through to the INSERT-copy/rename below.
          await _deleteChatRow(serverId);
        } else {
          // Server row already has the body (the authoritative copy). Discard
          // the local duplicate: repoint its ops, drop its messages + row.
          await _rewriteOutboxChatId(localId, serverId);
          await _deleteMessagesForChat(localId);
          await _deleteChatRow(localId);
          await _remapFtsRows(localId, serverId);
          return;
        }
      }

      // (a) INSERT a row at serverId copying every column from the local row,
      // stamping the server timestamps + clearing dirty for the chat envelope
      // (message dirty is decided per-row by the push handler, not here).
      await _insertChatCopy(
        from: local,
        newId: serverId,
        serverCreatedAt: serverCreatedAt,
        serverUpdatedAt: serverUpdatedAt,
      );
      // (b) Repoint children to the new id.
      await _rewriteMessagesChatId(localId, serverId);
      // (c) The local row now has no children: delete it cleanly.
      await _deleteChatRow(localId);
      // (d) Repoint pending|inFlight outbox ops (the running createChat op is
      // inFlight; after remap the drainer markDone()s it — harmless).
      await _rewriteOutboxChatId(localId, serverId);
      // (e) FTS seam (Phase 4).
      await _remapFtsRows(localId, serverId);
    });

    DebugLogger.log(
      'remap-chat',
      scope: 'sync/remap',
      data: {'from': localId, 'to': serverId},
    );
    _events.add(
      RemapEvent(fromId: localId, toId: serverId, entityKind: 'chat'),
    );
  }

  /// Rewrites folder [localId] to [serverId] in one transaction. Same
  /// INSERT-copy/repoint-children/delete-local shape as [remapChat]; children
  /// are the chats whose `folderId` points at the local folder.
  Future<void> remapFolder({
    required String localId,
    required String serverId,
    required int serverUpdatedAt,
  }) async {
    if (localId == serverId) return;
    await _db.transaction(() async {
      final local = await _getFolder(localId);
      if (local == null) {
        await _rewriteChatsFolderId(localId, serverId);
        await _rewriteOutboxChatId(localId, serverId);
        return;
      }
      final serverRow = await _getFolder(serverId);
      if (serverRow != null) {
        // A pull already created the server folder: discard the local stub,
        // repoint its chats + ops to the surviving server row.
        await _rewriteChatsFolderId(localId, serverId);
        await _rewriteOutboxChatId(localId, serverId);
        await _deleteFolderRow(localId);
        return;
      }
      await _insertFolderCopy(
        from: local,
        newId: serverId,
        serverUpdatedAt: serverUpdatedAt,
      );
      await _rewriteChatsFolderId(localId, serverId);
      await _deleteFolderRow(localId);
      await _rewriteOutboxChatId(localId, serverId);
    });

    DebugLogger.log(
      'remap-folder',
      scope: 'sync/remap',
      data: {'from': localId, 'to': serverId},
    );
    _events.add(
      RemapEvent(fromId: localId, toId: serverId, entityKind: 'folder'),
    );
  }

  // ---- chat helpers (raw SQL keeps this decoupled from the concurrent
  //      OutboxDao + avoids PK-update FK trouble) ----

  Future<ChatRow?> _getChat(String id) {
    return (_db.select(_db.chats)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<int> _messageCount(String chatId) async {
    final count = countAll();
    final query = _db.selectOnly(_db.messages)
      ..addColumns([count])
      ..where(_db.messages.chatId.equals(chatId));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> _insertChatCopy({
    required ChatRow from,
    required String newId,
    required int serverCreatedAt,
    required int serverUpdatedAt,
  }) async {
    await _db.into(_db.chats).insert(
          ChatsCompanion.insert(
            id: newId,
            title: from.title,
            folderId: Value(from.folderId),
            pinned: Value(from.pinned),
            archived: Value(from.archived),
            currentMessageId: Value(from.currentMessageId),
            createdAt: serverCreatedAt,
            updatedAt: serverUpdatedAt,
            serverUpdatedAt: Value(serverUpdatedAt),
            // The chat envelope is now server-acknowledged; the push handler
            // clears message dirty per its captured snapshot.
            dirty: const Value(false),
            deleted: Value(from.deleted),
            bodySynced: Value(from.bodySynced),
            rawExtra: Value(from.rawExtra),
            blobMeta: Value(from.blobMeta),
            shareId: Value(from.shareId),
            meta: Value(from.meta),
            lastReadAt: Value(from.lastReadAt),
          ),
        );
  }

  Future<void> _rewriteMessagesChatId(String fromId, String toId) {
    return _db.customUpdate(
      'UPDATE messages SET chat_id = ? WHERE chat_id = ?',
      variables: [Variable.withString(toId), Variable.withString(fromId)],
      updates: {_db.messages},
      updateKind: UpdateKind.update,
    );
  }

  Future<void> _deleteMessagesForChat(String chatId) {
    return (_db.delete(_db.messages)..where((t) => t.chatId.equals(chatId)))
        .go();
  }

  Future<void> _deleteChatRow(String id) {
    return (_db.delete(_db.chats)..where((t) => t.id.equals(id))).go();
  }

  // ---- folder helpers ----

  Future<FolderRow?> _getFolder(String id) {
    return (_db.select(_db.folders)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<void> _insertFolderCopy({
    required FolderRow from,
    required String newId,
    required int serverUpdatedAt,
  }) async {
    await _db.into(_db.folders).insert(
          FoldersCompanion.insert(
            id: newId,
            name: from.name,
            parentId: Value(from.parentId),
            createdAt: from.createdAt,
            updatedAt: serverUpdatedAt,
            serverUpdatedAt: Value(serverUpdatedAt),
            dirty: const Value(false),
            deleted: Value(from.deleted),
            rawExtra: Value(from.rawExtra),
          ),
        );
  }

  Future<void> _rewriteChatsFolderId(String fromId, String toId) {
    return _db.customUpdate(
      'UPDATE chats SET folder_id = ? WHERE folder_id = ?',
      variables: [Variable.withString(toId), Variable.withString(fromId)],
      updates: {_db.chats},
      updateKind: UpdateKind.update,
    );
  }

  Future<void> _deleteFolderRow(String id) {
    return (_db.delete(_db.folders)..where((t) => t.id.equals(id))).go();
  }

  // ---- outbox + FTS ----

  /// Repoints pending|inFlight outbox ops from [fromId] to [toId]. Mirrors the
  /// concurrent `OutboxDao.rewriteChatId` contract but is expressed as raw SQL
  /// so the remapper does not depend on that DAO existing. The `chat_id`
  /// column holds the folder id for folder ops, so this serves both kinds.
  /// Done ('failed' rows are terminal/parked and never repointed).
  Future<void> _rewriteOutboxChatId(String fromId, String toId) {
    return _db.customUpdate(
      "UPDATE outbox_ops SET chat_id = ? "
      "WHERE chat_id = ? AND status IN ('pending', 'inFlight')",
      variables: [Variable.withString(toId), Variable.withString(fromId)],
      updates: {_db.outboxOps},
      updateKind: UpdateKind.update,
    );
  }

  /// Phase 4 introduces FTS; Phase 2 has none. No-op hook so the §7.3 FTS
  /// rewrite (`local:<uuid>` -> serverId) has a single seam to fill later.
  Future<void> _remapFtsRows(String localId, String serverId) async {
    // TODO(phase4): rewrite FTS doc ids local:<uuid> -> serverId here.
  }
}
