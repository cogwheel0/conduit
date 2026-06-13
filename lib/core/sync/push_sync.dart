import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import '../database/mappers/chat_blob_mapper.dart';
import '../database/mappers/conversation_assembler.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'clock.dart';
import 'id_remapper.dart';
import 'sync_api_client.dart';

/// Per-kind outbox push handlers (CDT-RFC-001 §7.2/§7.3/§7.4).
///
/// Every handler acquires the chat (or folder) lock internally so push
/// reconstruct/serialize serializes with pull-merge and stream-echo for the
/// same id (REQ §10). Constructor injection only — no Riverpod here, mirroring
/// [PullSync].
///
/// §3.iii is the governing invariant: createChat and updateChat ALWAYS send
/// the COMPLETE blob reconstructed live from rows via
/// [ChatBlobMapper.rowsToBlob] at push time. Outbox payloads are empty; the
/// blob is never snapshotted at enqueue, so the latest committed rows are what
/// reach the server even after coalescing collapsed several ops into one.
class PushSync {
  PushSync({
    required SyncApiClient client,
    required AppDatabase db,
    required ChatLocks chatLocks,
    required ChatLocks folderLocks,
    required SyncClock clock,
    required IdRemapper remapper,
  })  : _client = client,
        _db = db,
        _chatLocks = chatLocks,
        _folderLocks = folderLocks,
        _clock = clock,
        _remapper = remapper;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ChatLocks _chatLocks;
  final ChatLocks _folderLocks;

  /// Held for signature parity + future use. The dirty/serverUpdatedAt rule
  /// uses the server response `updated_at`, never a device clock (§7.2
  /// timestamp rule), so push handlers do not read this yet.
  // ignore: unused_field
  final SyncClock _clock;
  final IdRemapper _remapper;

  // ---- createChat (§7.3) ----

  /// Pushes the new local chat [localId], remaps it to the server id, and
  /// clears dirty for the reconstructed snapshot. Returns the server id.
  ///
  /// The reconstruct+POST run under the [localId] lock (single span — no
  /// mid-flight write window for create), then the remap runs under the
  /// SERVER id lock so the §7.3 transaction commits before the drainer marks
  /// the op done.
  Future<String?> pushCreateChat(String localId) async {
    // Re-run idempotency (§7.3): the remap repoints this op's chat_id from
    // local:<uuid> to the server id INSIDE the §7.3 transaction, which commits
    // BEFORE the drainer markDone()s the op. A crash (or a pull-side crash-heal)
    // between that commit and markDone leaves the op live with a NON-local id.
    // Re-running must NOT POST a second chat: a non-local id means the server
    // chat already exists, so the create is already satisfied — return it as-is.
    if (!localId.startsWith('local:')) {
      DebugLogger.log(
        'create-already-satisfied',
        scope: 'sync/push',
        data: {'chatId': localId},
      );
      return localId;
    }

    final _CreatePush? pushed = await _chatLocks.runExclusive(localId, () async {
      final chat = await _db.chatsDao.getChat(localId);
      if (chat == null) {
        // Annihilated by a delete before we ran, or already remapped.
        return null;
      }
      final messages = await _db.messagesDao.getForChat(localId);
      final rows = chatRowsFromDb(chat, messages);
      final blob = ChatBlobMapper.rowsToBlob(rows)..['id'] = '';
      final resp = await _client.createChat(blob, folderId: chat.folderId);
      final serverId = resp['id'];
      if (serverId is! String || serverId.isEmpty) {
        throw StateError('createChat response without a string id');
      }
      return _CreatePush(
        serverId: serverId,
        serverCreatedAt: _epoch(resp['created_at']) ?? chat.createdAt,
        serverUpdatedAt: _epoch(resp['updated_at']) ?? chat.updatedAt,
        capturedMessageIds: [for (final m in messages) m.id],
      );
    });

    if (pushed == null) return null;

    // Remap under the SERVER id lock: the §7.3 single transaction (rewrite
    // chats.id + messages.chatId + pending outbox.chatId) commits here, BEFORE
    // the drainer marks the createChat op done.
    await _chatLocks.runExclusive(
      pushed.serverId,
      () => _remapper.remapChat(
        localId: localId,
        serverId: pushed.serverId,
        serverCreatedAt: pushed.serverCreatedAt,
        serverUpdatedAt: pushed.serverUpdatedAt,
      ),
    );

    // Dirty-clear (§7.2): the whole reconstruct+POST happened under one lock
    // span, so there was no mid-flight window for create — clear dirty for the
    // captured message snapshot (now living under serverId) and the chat row.
    await _chatLocks.runExclusive(pushed.serverId, () async {
      await _clearDirty(
        chatId: pushed.serverId,
        messageIds: pushed.capturedMessageIds,
        serverUpdatedAt: pushed.serverUpdatedAt,
      );
    });

    return pushed.serverId;
  }

  // ---- updateChat (§3.iii + §7.2) ----

  /// Pushes the FULL reconstructed blob for [chatId] and applies the
  /// dirty/serverUpdatedAt rule. The entire reconstruct -> POST -> clear runs
  /// under one lock span, so no stream-echo can interleave: "rows dirtied
  /// mid-flight stay dirty" holds because only the captured snapshot's dirty
  /// is cleared.
  ///
  /// CONFLICT GATE (§7.2, Phase 2 stub per §11): pushUpdateChat does NOT
  /// re-pull. The Phase 1 pull fast-forward-merged (no dirty rows existed),
  /// and Phase 2 trusts the current rows as the merged result; full three-way
  /// merge is Phase 3. It reconstructs from the CURRENT rows (which already
  /// overlay local dirty edits) and pushes the complete blob.
  Future<void> pushUpdateChat(String chatId) async {
    await _chatLocks.runExclusive(chatId, () async {
      final chat = await _db.chatsDao.getChat(chatId);
      if (chat == null || chat.deleted) {
        // A deleteChat op will handle a tombstoned/absent chat.
        return;
      }
      final messages = await _db.messagesDao.getForChat(chatId);
      final capturedMessageIds = [for (final m in messages) m.id];
      final rows = chatRowsFromDb(chat, messages);
      final blob = ChatBlobMapper.rowsToBlob(rows);

      final resp = await _client.updateChat(chatId, blob);
      if (resp == null) {
        // 404: chat gone server-side. Phase 2 treats this as terminal (log +
        // let the drainer markDone); Phase 3 reconciles.
        DebugLogger.warning(
          'update-404',
          scope: 'sync/push',
          data: {'chatId': chatId},
        );
        return;
      }
      final serverUpdatedAt = _epoch(resp['updated_at']) ?? chat.updatedAt;

      // pin/archive toggle-delta (B1): the toggle endpoints IGNORE the body
      // and pin/archive live in the envelope, NOT the blob, so update_chat
      // never changes them. Derive both deltas from this same ChatResponse and
      // issue at most one toggle each (Phase 2 acceptable simplification).
      final serverPinned = resp['pinned'] == true;
      if (chat.pinned != serverPinned) {
        // Confirm against /pinned in case the ChatResponse pinned is stale,
        // then flip on a real delta.
        final live = await _client.getChatPinned(chatId);
        if (live != chat.pinned) {
          await _client.togglePin(chatId);
        }
      }
      final serverArchived = resp['archived'] == true;
      if (chat.archived != serverArchived) {
        // Symmetric with the pin path: re-read the live archived state (the
        // ChatResponse value can be stale relative to a concurrent toggle by
        // another client) and flip only on a real delta, so a racing client
        // can't make this blindly toggle archive back to the wrong state.
        final liveRaw = await _client.getChatRaw(chatId);
        final liveArchived = liveRaw?['archived'] == true;
        if (liveArchived != chat.archived) {
          await _client.toggleArchive(chatId);
        }
      }

      // folder-move delta: update_chat IGNORES folder_id, so a changed folder
      // must go through the dedicated /folder endpoint.
      //
      // FOLDER-BEFORE-CHAT ORDERING (§7.6, non-negotiable 6): never send a
      // `local:`-prefixed folder id — the folder's createChat hasn't been
      // drained+remapped yet, so the server would 400/404 the move (or store
      // the bogus local id verbatim). Skip the move this attempt and leave the
      // chat dirty (do NOT clear dirty) so a later drain — after IdRemapper
      // rewrites chats.folderId to the real server id — re-runs this op and
      // sends the move. This makes ordering self-healing without a cross-entity
      // dependency graph.
      final serverFolderId =
          resp['folder_id'] is String ? resp['folder_id'] as String : null;
      final localFolderPending =
          chat.folderId != null && chat.folderId!.startsWith('local:');
      if (localFolderPending) {
        DebugLogger.log(
          'update-defer-local-folder',
          scope: 'sync/push',
          data: {'chatId': chatId, 'folderId': chat.folderId},
        );
        // Leave the chat dirty; a later drain (post folder remap) completes it.
        // Still advance serverUpdatedAt for the blob/toggles already pushed so
        // the conflict gate sees the server ack; dirty stays true.
        await _storeServerUpdatedAtKeepDirty(
          chatId: chatId,
          serverUpdatedAt: serverUpdatedAt,
        );
        return;
      }
      if (chat.folderId != serverFolderId) {
        await _client.moveChatToFolder(chatId, chat.folderId);
      }

      // Store serverUpdatedAt + clear dirty ONLY for the captured snapshot:
      // any row dirtied after the capture (none possible inside this single
      // lock span, but defensively) stays dirty.
      await _clearDirty(
        chatId: chatId,
        messageIds: capturedMessageIds,
        serverUpdatedAt: serverUpdatedAt,
      );
    });
  }

  // ---- deleteChat (§7.5) ----

  /// Confirms the server delete (or 404 already-gone), then purges the local
  /// rows. On a terminal 401/403 the [SyncTerminalException] propagates so the
  /// drainer parks the op; the rows stay tombstoned (NOT purged).
  Future<void> pushDeleteChat(String chatId) async {
    await _chatLocks.runExclusive(chatId, () async {
      // 404 -> false (already gone) -> still proceed to purge. 401/403 throws
      // and aborts the purge.
      await _client.deleteChat(chatId);
      await _db.chatsDao.hardDelete(chatId);
    });
  }

  // ---- folderUpsert / folderDelete (§7.6) ----

  /// Pushes a folder create-or-update. A `local:` folder with
  /// `createIfAbsent` is created server-side then remapped; otherwise the name
  /// and parent deltas are pushed. Clears `folders.dirty` on success.
  Future<void> pushFolderUpsert(Map<String, dynamic> payload) async {
    final folderId = payload['folderId'];
    if (folderId is! String || folderId.isEmpty) {
      DebugLogger.warning('folder-upsert-no-id', scope: 'sync/push');
      return;
    }
    await _folderLocks.runExclusive(folderId, () async {
      final createIfAbsent = payload['createIfAbsent'] == true;
      final name = payload['name'] is String ? payload['name'] as String : null;
      final parentId =
          payload['parentId'] is String ? payload['parentId'] as String : null;
      final data = _asMap(payload['data']);
      final meta = _asMap(payload['meta']);

      if (createIfAbsent && folderId.startsWith('local:')) {
        final resp = await _client.createFolder(
          name: name ?? '',
          parentId: parentId,
        );
        final serverId = resp['id'];
        if (serverId is! String || serverId.isEmpty) {
          throw StateError('createFolder response without a string id');
        }
        final serverUpdatedAt = _epoch(resp['updated_at']) ?? 0;
        // Remap under the SERVER folder lock (we already hold the local one),
        // committing the §7.3 transaction before the op is marked done.
        await _folderLocks.runExclusive(
          serverId,
          () => _remapper.remapFolder(
            localId: folderId,
            serverId: serverId,
            serverUpdatedAt: serverUpdatedAt,
          ),
        );
        await _clearFolderDirty(serverId);
        return;
      }

      await _client.updateFolder(
        folderId,
        name: name,
        data: data,
        meta: meta,
      );
      if (parentId != null || payload.containsKey('parentId')) {
        await _client.updateFolderParent(folderId, parentId);
      }
      await _clearFolderDirty(folderId);
    });
  }

  /// Deletes the folder server-side with `delete_contents=false` (BINDING: the
  /// server default `true` would also delete contained chats), then purges the
  /// local folder row.
  Future<void> pushFolderDelete(String folderId) async {
    await _folderLocks.runExclusive(folderId, () async {
      await _client.deleteFolder(folderId, deleteContents: false);
      await _db.foldersDao.hardDelete(folderId);
    });
  }

  // ---- helpers ----

  /// Caller holds the chat lock. Stores [serverUpdatedAt] + clears dirty for
  /// the chat row and exactly [messageIds] in ONE transaction (REQ §7.2/§10).
  Future<void> _clearDirty({
    required String chatId,
    required List<String> messageIds,
    required int serverUpdatedAt,
  }) {
    return _db.transaction(() async {
      await _db.customUpdate(
        'UPDATE chats SET server_updated_at = ?, dirty = 0 WHERE id = ?',
        variables: [
          Variable.withInt(serverUpdatedAt),
          Variable.withString(chatId),
        ],
        updates: {_db.chats},
        updateKind: UpdateKind.update,
      );
      if (messageIds.isEmpty) return;
      await (_db.update(_db.messages)
            ..where((t) => t.chatId.equals(chatId) & t.id.isIn(messageIds)))
          .write(const MessagesCompanion(dirty: Value(false)));
    });
  }

  /// Folder-before-chat deferral (§7.6): the chat still references a `local:`
  /// folder whose create has not been remapped, so the folder-move half of
  /// this update cannot run yet. Advance `server_updated_at` for the blob +
  /// toggles already pushed, KEEP `dirty=true`, and re-enqueue a fresh
  /// `updateChat` op (coalesces against any later edit) so a subsequent drain —
  /// after `IdRemapper.remapFolder` rewrites `chats.folderId` to the server id
  /// — re-runs and issues the move. One transaction (REQ §10). Caller holds the
  /// chat lock.
  Future<void> _storeServerUpdatedAtKeepDirty({
    required String chatId,
    required int serverUpdatedAt,
  }) {
    return _db.transaction(() async {
      await _db.customUpdate(
        'UPDATE chats SET server_updated_at = ? WHERE id = ?',
        variables: [
          Variable.withInt(serverUpdatedAt),
          Variable.withString(chatId),
        ],
        updates: {_db.chats},
        updateKind: UpdateKind.update,
      );
      await _db.outboxDao.enqueue(kind: OutboxKind.updateChat, chatId: chatId);
    });
  }

  Future<void> _clearFolderDirty(String folderId) {
    return (_db.update(_db.folders)..where((t) => t.id.equals(folderId)))
        .write(const FoldersCompanion(dirty: Value(false)));
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static int? _epoch(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

/// Result of the createChat POST carried out of the local-id lock span.
class _CreatePush {
  const _CreatePush({
    required this.serverId,
    required this.serverCreatedAt,
    required this.serverUpdatedAt,
    required this.capturedMessageIds,
  });

  final String serverId;
  final int serverCreatedAt;
  final int serverUpdatedAt;
  final List<String> capturedMessageIds;
}
