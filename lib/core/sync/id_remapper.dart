import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../database/mappers/chat_blob_mapper.dart';
import '../utils/debug_logger.dart';

const _outboxStatusesRewrittenOnChatRemap = <String>[
  'pending',
  'inFlight',
  'failed',
];

/// A completed local->server id rewrite (CDT-RFC-001 §7.3).
///
/// Emitted synchronously on [IdRemapper.remapEvents] AFTER the rewrite
/// transaction commits, so a route/active-chat consumer can swap `local:<uuid>`
/// for [toId] before post-commit DB-watch emissions surface the old id.
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

  /// `'chat'`, `'folder'`, or `'note'`.
  final String entityKind;

  @override
  String toString() => 'RemapEvent($entityKind: $fromId -> $toId)';
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
///   * every pending|inFlight|failed outbox op's `chat_id` column (which holds the
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
  // Synchronous delivery lets route consumers swap a remapped open note/chat
  // before post-commit Drift watch emissions for the old local id are handled.
  final StreamController<RemapEvent> _events =
      StreamController<RemapEvent>.broadcast(sync: true);

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
    var didRewriteLocal = false;
    await _db.transaction(() async {
      final local = await _getChat(localId);
      if (local == null) {
        // The local row is already gone (a prior pull may have merged the
        // server chat and a previous remap completed). Still repoint any
        // pending ops + leftover messages defensively, then return. The
        // chat_id-only message UPDATE fires no FTS trigger, so repoint any
        // leftover msg FTS rows to match.
        await _rewriteMessagesChatId(localId, serverId);
        await _remapFtsRows(localId, serverId);
        await _rewriteOutboxChatId(localId, serverId);
        return;
      }
      didRewriteLocal = true;

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
          // _deleteMessagesForChat is a DIRECT delete on `messages`, so trigger
          // #2 already purges the local msg FTS rows; the subsequent
          // _deleteChatRow fires trigger #7 (purges the local title row). No
          // surviving local FTS rows remain to repoint, so the FTS remap is a
          // safe no-op on this branch.
          await _rewriteOutboxChatId(localId, serverId);
          await _deleteMessagesForChat(localId);
          await _deleteChatRow(localId);
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
      // (c) Repoint the message FTS rows to serverId. This MUST run BEFORE
      // _deleteChatRow(localId): _rewriteMessagesChatId is an UPDATE of
      // `chat_id` only, which fires NO FTS trigger (trigger #3 is AFTER UPDATE
      // OF content), so the msg FTS rows still key localId. If the local chat
      // row were deleted first, trigger #7 (`chats AFTER DELETE -> DELETE FROM
      // chat_fts WHERE chat_id = old.id`) would eat those orphaned msg rows and
      // permanently drop the content from the index.
      await _remapFtsRows(localId, serverId);
      // (d) The local row now has no children: delete it cleanly. Trigger #7
      // purges only the local title FTS row (msg rows now key serverId; the
      // serverId title row was already created by trigger #4 in step (a)).
      await _deleteChatRow(localId);
      // (e) Repoint live and parked outbox ops (the running createChat op is
      // inFlight; after remap the drainer markDone()s it — harmless).
      await _rewriteOutboxChatId(localId, serverId);
    });

    if (!didRewriteLocal) return;
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
    var didRewriteLocal = false;
    await _db.transaction(() async {
      final local = await _getFolder(localId);
      if (local == null) {
        await _rewriteChatsFolderId(localId, serverId);
        await _rewriteOutboxChatId(localId, serverId);
        return;
      }
      didRewriteLocal = true;
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

    if (!didRewriteLocal) return;
    DebugLogger.log(
      'remap-folder',
      scope: 'sync/remap',
      data: {'from': localId, 'to': serverId},
    );
    _events.add(
      RemapEvent(fromId: localId, toId: serverId, entityKind: 'folder'),
    );
  }

  /// Rewrites note [localId] to [serverId] in one transaction (CDT-RFC-001
  /// Phase 5, §7.3). Notes are FLAT documents — there are NO child rows to
  /// repoint (no messages, no folder backrefs), so this is the simplest remap:
  /// INSERT-copy the row at the server id stamping the server timestamps,
  /// repoint the note's FTS rows + any conflict-copy back-pointer + pending
  /// outbox ops, then delete the local row. Callers MUST hold the NOTE lock for
  /// BOTH the local and server id around the remap.
  ///
  /// R-09: [serverCreatedAt]/[serverUpdatedAt] are raw NANOSECONDS and are
  /// copied verbatim — no unit conversion anywhere on the note path.
  Future<void> remapNote({
    required String localId,
    required String serverId,
    required int serverCreatedAt,
    required int serverUpdatedAt,
  }) async {
    if (localId == serverId) return;
    var didRewriteLocal = false;
    await _db.transaction(() async {
      final local = await _getNote(localId);
      if (local == null) {
        // The local row is already gone (a prior pull merged the server note).
        // Repoint any leftover FTS rows + conflict back-pointers + pending ops.
        await _remapNoteFtsRows(localId, serverId);
        await _rewriteNoteConflictOf(localId, serverId);
        await _rewriteOutboxChatId(localId, serverId);
        await _db.syncMetaDao.setNoteRemapTarget(localId, serverId);
        return;
      }
      didRewriteLocal = true;
      final serverRow = await _getNote(serverId);
      if (serverRow != null) {
        // A pull already inserted the server note: discard the local duplicate,
        // repoint its ops + conflict back-pointers, drop its FTS rows + row.
        await _rewriteNoteConflictOf(localId, serverId);
        await _rewriteOutboxChatId(localId, serverId);
        await _deleteNoteRow(localId); // trigger #12 purges local FTS rows.
        await _db.syncMetaDao.setNoteRemapTarget(localId, serverId);
        return;
      }
      // (a) INSERT a row at serverId copying every column, stamping the server
      // (ns) timestamps + serverUpdatedAt and clearing every field-LWW dirty
      // flag (the create is now server-acknowledged). Trigger #8 indexes the
      // serverId FTS rows on insert.
      await _insertNoteCopy(
        from: local,
        newId: serverId,
        serverCreatedAt: serverCreatedAt,
        serverUpdatedAt: serverUpdatedAt,
      );
      // (b) The serverId FTS rows are created by trigger #8 above; purge the
      // stale localId FTS rows by deleting the local row last (trigger #12).
      await _rewriteNoteConflictOf(localId, serverId);
      await _deleteNoteRow(localId);
      // (c) Repoint pending|inFlight outbox ops (the running noteCreate op is
      // inFlight; after remap the drainer markDone()s it).
      await _rewriteOutboxChatId(localId, serverId);
      await _db.syncMetaDao.setNoteRemapTarget(localId, serverId);
    });

    if (!didRewriteLocal) return;
    DebugLogger.log(
      'remap-note',
      scope: 'sync/remap',
      data: {'from': localId, 'to': serverId},
    );
    _events.add(
      RemapEvent(fromId: localId, toId: serverId, entityKind: 'note'),
    );
  }

  // ---- note helpers ----

  Future<NoteRow?> _getNote(String id) {
    return (_db.select(
      _db.notes,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<void> _insertNoteCopy({
    required NoteRow from,
    required String newId,
    required int serverCreatedAt,
    required int serverUpdatedAt,
  }) async {
    await _db
        .into(_db.notes)
        .insert(
          NotesCompanion.insert(
            id: newId,
            title: from.title,
            data: Value(from.data),
            meta: Value(from.meta),
            isPinned: Value(from.isPinned),
            createdAt: serverCreatedAt,
            updatedAt: serverUpdatedAt,
            serverUpdatedAt: Value(serverUpdatedAt),
            // Create acknowledged: clear the title/data dirty axes. Keep the
            // pin axis dirty if it was — a pending pin still owes its /pin push.
            dirtyTitle: const Value(false),
            dirtyData: const Value(false),
            dirtyPinned: Value(from.dirtyPinned),
            deleted: Value(from.deleted),
            rawExtra: Value(from.rawExtra),
            isConflictCopy: Value(from.isConflictCopy),
            conflictOf: Value(from.conflictOf),
          ),
        );
  }

  Future<void> _deleteNoteRow(String id) {
    return (_db.delete(_db.notes)..where((t) => t.id.equals(id))).go();
  }

  /// Repoints a conflict copy's `conflict_of` back-pointer from [fromId] to
  /// [toId] when the CANONICAL note it copied was itself remapped. (A conflict
  /// copy references its canonical by id; if that canonical was a `local:` note
  /// that just got a server id, keep the pointer valid.)
  Future<void> _rewriteNoteConflictOf(String fromId, String toId) {
    return _db.customUpdate(
      'UPDATE notes SET conflict_of = ? WHERE conflict_of = ?',
      variables: [Variable.withString(toId), Variable.withString(fromId)],
      updates: {_db.notes},
      updateKind: UpdateKind.update,
    );
  }

  /// Repoints the note FTS rows (`kind IN ('note_title','note_text')`) from
  /// [localId] to [serverId] on the standalone `chat_fts` vtable. Used on the
  /// merge-collision branches where the local row is dropped without trigger
  /// #8 re-indexing under the server id. Tolerant of a not-yet-built index.
  Future<void> _remapNoteFtsRows(String localId, String serverId) {
    return _remapFtsRowsWhere(
      localId,
      serverId,
      "kind IN ('note_title', 'note_text')",
    );
  }

  /// Repoints `chat_fts` rows matching [kindClause] from [localId] to
  /// [serverId]. Tolerant of a not-yet-built index (the vtable may not exist
  /// before the post-first-sync [AppDatabase.buildFtsIfNeeded] gate fires); in
  /// that case there are no rows to move and the backfill later indexes them
  /// under serverId, so this is a safe no-op.
  Future<void> _remapFtsRowsWhere(
    String localId,
    String serverId,
    String kindClause,
  ) async {
    final exists = await _db
        .customSelect(
          "SELECT 1 FROM sqlite_master WHERE name = 'chat_fts' LIMIT 1",
        )
        .get();
    if (exists.isEmpty) return;
    await _db.customUpdate(
      "UPDATE chat_fts SET chat_id = ? WHERE chat_id = ? AND $kindClause",
      variables: [Variable.withString(serverId), Variable.withString(localId)],
    );
  }

  // ---- chat helpers (raw SQL keeps this decoupled from the concurrent
  //      OutboxDao + avoids PK-update FK trouble) ----

  Future<ChatRow?> _getChat(String id) {
    return (_db.select(
      _db.chats,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
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
    await _db
        .into(_db.chats)
        .insert(
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
    return (_db.delete(
      _db.messages,
    )..where((t) => t.chatId.equals(chatId))).go();
  }

  Future<void> _deleteChatRow(String id) {
    return (_db.delete(_db.chats)..where((t) => t.id.equals(id))).go();
  }

  // ---- folder helpers ----

  Future<FolderRow?> _getFolder(String id) {
    return (_db.select(
      _db.folders,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<void> _insertFolderCopy({
    required FolderRow from,
    required String newId,
    required int serverUpdatedAt,
  }) async {
    await _db
        .into(_db.folders)
        .insert(
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

  /// Repoints live and parked outbox ops from [fromId] to [toId]. Mirrors the
  /// concurrent `OutboxDao.rewriteChatId` contract but is expressed as raw SQL
  /// so the remapper does not depend on that DAO existing. The `chat_id`
  /// column holds the folder id for folder ops, so this serves both kinds.
  Future<void> _rewriteOutboxChatId(String fromId, String toId) {
    return _db.customUpdate(
      "UPDATE outbox_ops SET chat_id = ? "
      'WHERE chat_id = ? '
      "AND status IN (${_outboxStatusesRewrittenOnChatRemap.map((_) => '?').join(', ')})",
      variables: [
        Variable.withString(toId),
        Variable.withString(fromId),
        for (final status in _outboxStatusesRewrittenOnChatRemap)
          Variable.withString(status),
      ],
      updates: {_db.outboxOps},
      updateKind: UpdateKind.update,
    );
  }

  /// Repoints the message FTS rows from [localId] to [serverId] (CDT-RFC-001
  /// §7.3 + Phase 4 FTS).
  ///
  /// Why this is needed: [_rewriteMessagesChatId] is an `UPDATE messages SET
  /// chat_id = ?`. The FTS maintenance trigger on messages (#3) fires only
  /// `AFTER UPDATE OF content`, so a chat_id-only update leaves the standalone
  /// `chat_fts` message rows still keyed to `localId`. Those orphaned rows would
  /// then be eaten by trigger #7 (`chats AFTER DELETE` -> `DELETE FROM chat_fts
  /// WHERE chat_id = old.id`) when [_deleteChatRow] purges the local chat,
  /// permanently dropping the chat's message content from the index. Repoint
  /// them directly on the vtable instead.
  ///
  /// Restricted to `kind = 'msg'`: the serverId title row is (re)created by
  /// trigger #4 in [_insertChatCopy], and the stale local title row is purged by
  /// trigger #7 on [_deleteChatRow]. Repointing the title here would leave a
  /// duplicate title row at serverId.
  ///
  /// Tolerant of a not-yet-built index: when the `chat_fts` vtable does not
  /// exist (remap can run before the post-first-sync [AppDatabase.buildFtsIfNeeded]
  /// gate fires), there are no msg FTS rows to move and the backfill will later
  /// index the rows under serverId, so this is a safe no-op.
  Future<void> _remapFtsRows(String localId, String serverId) {
    return _remapFtsRowsWhere(localId, serverId, "kind = 'msg'");
  }
}
