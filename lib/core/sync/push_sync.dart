import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../database/mappers/chat_blob_mapper.dart';
import '../database/mappers/conversation_assembler.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'clock.dart';
import 'id_remapper.dart';
import 'outbox_drainer.dart';
import 'sync_api_client.dart';

const int _sqliteVariableBatchSize = 900;

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
    required ConversationLocks chatLocks,
    required FolderLocks folderLocks,
    required SyncClock clock,
    required IdRemapper remapper,
  }) : _client = client,
       _db = db,
       _chatLocks = chatLocks,
       _folderLocks = folderLocks,
       _clock = clock,
       _remapper = remapper;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ConversationLocks _chatLocks;
  final FolderLocks _folderLocks;

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
  /// The reconstruct+POST run under the [localId] lock, and the SERVER id lock
  /// is acquired before releasing it so a pull cannot fast-forward the server
  /// row between POST and remap. The §7.3 transaction commits before the
  /// drainer marks the op done.
  Future<String?> pushCreateChat(String localId, {String? contentHash}) async {
    // Re-run idempotency (§7.3): the remap repoints this op's chat_id from
    // local:<uuid> to the server id INSIDE the §7.3 transaction, which commits
    // BEFORE the drainer markDone()s the op. A crash (or a pull-side crash-heal)
    // between that commit and markDone leaves the op live with a NON-local id.
    // Re-running must NOT POST a second chat: a non-local id means the server
    // chat already exists, so the create is already satisfied — return it as-is.
    if (!localId.startsWith('local:')) {
      return _chatLocks.runExclusive(localId, () async {
        DebugLogger.log(
          'create-already-satisfied',
          scope: 'sync/push',
          data: {'chatId': localId},
        );
        final chat = await _db.chatsDao.getChat(localId);
        if (chat != null) {
          final messages = await _db.messagesDao.getForChat(localId);
          final capturedMessageIds = _messageIdsIfSnapshotMatches(
            chat,
            messages,
            contentHash,
          );
          await _clearDirty(
            chatId: localId,
            messageIds: capturedMessageIds,
            serverUpdatedAt: chat.serverUpdatedAt ?? chat.updatedAt,
          );
        }
        return localId;
      });
    }

    return _chatLocks.runExclusive(localId, () async {
      final chat = await _db.chatsDao.getChat(localId);
      if (chat == null) {
        // Annihilated by a delete before we ran, or already remapped.
        return null;
      }
      final messages = await _db.messagesDao.getForChat(localId);
      final rows = chatRowsFromDb(chat, messages);
      final blob = ChatBlobMapper.rowsToBlob(rows)..['id'] = '';
      if (chat.folderId != null && chat.folderId!.startsWith('local:')) {
        DebugLogger.log(
          'create-defer-local-folder',
          scope: 'sync/push',
          data: {'chatId': localId, 'folderId': chat.folderId},
        );
        throw _OutboxDeferred(
          'createChat deferred until folder remap completes: $localId',
        );
      }
      final resp = await _client.createChat(blob, folderId: chat.folderId);
      final serverId = resp['id'];
      if (serverId is! String || serverId.isEmpty) {
        throw StateError('createChat response without a string id');
      }
      final pushed = _CreatePush(
        serverId: serverId,
        serverCreatedAt: _epoch(resp['created_at']) ?? chat.createdAt,
        serverUpdatedAt: _epoch(resp['updated_at']) ?? chat.updatedAt,
        capturedMessageIds: [for (final m in messages) m.id],
      );

      // Keep the local-id lock while acquiring the server-id lock for remap.
      // Pull-side crash-heal claims a pending createChat before trying localId;
      // once this push worker owns the op as inFlight, crash-heal exits before
      // taking localId and cannot form an opposite-order cycle.
      await _chatLocks.runExclusive(pushed.serverId, () async {
        await _remapper.remapChat(
          localId: localId,
          serverId: pushed.serverId,
          serverCreatedAt: pushed.serverCreatedAt,
          serverUpdatedAt: pushed.serverUpdatedAt,
        );
        // Dirty-clear (§7.2): the whole reconstruct+POST happened under one
        // local-id lock span, and remap+clear share this server-id lock span.
        // Clear only the captured message snapshot (now living under serverId)
        // and the chat row.
        await _clearDirty(
          chatId: pushed.serverId,
          messageIds: pushed.capturedMessageIds,
          serverUpdatedAt: pushed.serverUpdatedAt,
        );
      });

      return pushed.serverId;
    });
  }

  // ---- updateChat (§3.iii + §7.2) ----

  /// Pushes the FULL reconstructed blob for [chatId] and applies the
  /// dirty/serverUpdatedAt rule. The entire reconstruct -> POST -> clear runs
  /// under one lock span, so no stream-echo can interleave: "rows dirtied
  /// mid-flight stay dirty" holds because only the captured snapshot's dirty
  /// is cleared.
  ///
  /// CONFLICT GATE (§7.2, Phase 2 stub per §11): pushUpdateChat does NOT
  /// re-pull, and it refuses to push envelope-only stubs. Once a full body pull
  /// has set `bodySynced=true`, the current rows are the merged result; this
  /// reconstructs from those rows (which already overlay local dirty edits) and
  /// pushes the complete blob.
  Future<void> pushUpdateChat(String chatId) async {
    await _chatLocks.runExclusive(chatId, () async {
      final chat = await _db.chatsDao.getChat(chatId);
      if (chat == null || chat.deleted) {
        // A deleteChat op will handle a tombstoned/absent chat.
        return;
      }
      if (!chat.bodySynced) {
        throw _OutboxDeferred(
          'updateChat deferred until body sync completes: $chatId',
        );
      }
      if (chat.folderId != null && chat.folderId!.startsWith('local:')) {
        DebugLogger.log(
          'update-defer-local-folder',
          scope: 'sync/push',
          data: {'chatId': chatId, 'folderId': chat.folderId},
        );
        throw _OutboxDeferred(
          'updateChat deferred until folder remap completes: $chatId',
        );
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

      // folder-move delta runs BEFORE the pin/archive reconcile: the server's
      // update_chat_folder_id forces pinned=false on every move (vendored
      // models/chats.py), so a pin reconcile must run AFTER the move to re-
      // assert the desired pinned state — otherwise a pinned chat that is moved
      // in the same coalesced update silently loses its pin.
      //
      // update_chat IGNORES folder_id, so a changed folder must go through the
      // dedicated /folder endpoint.
      //
      // FOLDER-BEFORE-CHAT ORDERING (§7.6, non-negotiable 6): never send a
      // `local:`-prefixed folder id — the folder's createChat hasn't been
      // drained+remapped yet, so the server would 400/404 the move. The
      // pre-flight guard above throws before updateChat so the drainer backs
      // off this same op until IdRemapper rewrites chats.folderId to the real
      // server id.
      final serverFolderId = resp['folder_id'] is String
          ? resp['folder_id'] as String
          : null;
      final movedFolder = chat.folderId != serverFolderId;
      if (movedFolder) {
        await _client.moveChatToFolder(chatId, chat.folderId);
      }

      // pin/archive toggle-delta (B1): the server only exposes stateless toggle
      // endpoints for these axes, so the sync path always drives them through
      // desired-state reconcilers that probe before toggling and confirm after.
      // A retry after a post-toggle timeout re-probes and therefore cannot
      // double-flip. After a folder move the server pin is known to be false,
      // so treat it as such (the pre-move ChatResponse copy is stale).
      final serverPinned = movedFolder ? false : resp['pinned'] == true;
      final serverArchived = resp['archived'] == true;
      final needsPinCheck = chat.pinned != serverPinned;
      final needsArchiveCheck = chat.archived != serverArchived;

      if (needsPinCheck && !needsArchiveCheck) {
        // Pin lives in a join table; confirm against /pinned (authoritative)
        // rather than the ChatResponse copy. This path intentionally skips
        // getChatRaw; no archive liveness check is needed for a pin-only delta.
        await _setChatPinned(chatId, desired: chat.pinned);
      } else if (needsArchiveCheck) {
        // A liveness fetch is needed only for archive reconciliation: the
        // archive flag rides the ChatResponse, while pin has a dedicated
        // authoritative endpoint below.
        final liveRaw = await _client.getChatRaw(chatId);
        if (liveRaw != null) {
          if (needsPinCheck) {
            await _setChatPinned(chatId, desired: chat.pinned);
          }
          await _setChatArchived(
            chatId,
            desired: chat.archived,
            initialRaw: liveRaw,
          );
        }
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

  Future<void> _setChatPinned(String chatId, {required bool desired}) async {
    var livePinned = await _client.getChatPinned(chatId);
    if (livePinned != desired) {
      await _client.togglePin(chatId);
      livePinned = await _client.getChatPinned(chatId);
    }
    if (livePinned != desired) {
      DebugLogger.warning(
        'pin-confirm-mismatch',
        scope: 'sync/push',
        data: {'chatId': chatId, 'desired': desired, 'actual': livePinned},
      );
      await _storeChatPinMirror(chatId, livePinned);
    }
  }

  Future<void> _setChatArchived(
    String chatId, {
    required bool desired,
    Map<String, dynamic>? initialRaw,
  }) async {
    var liveRaw = initialRaw ?? await _client.getChatRaw(chatId);
    if (liveRaw == null) {
      DebugLogger.warning(
        'archive-confirm-404',
        scope: 'sync/push',
        data: {'chatId': chatId},
      );
      return;
    }

    var liveArchived = liveRaw['archived'] == true;
    if (liveArchived != desired) {
      await _client.toggleArchive(chatId);
      liveRaw = await _client.getChatRaw(chatId);
      if (liveRaw == null) {
        DebugLogger.warning(
          'archive-post-toggle-404',
          scope: 'sync/push',
          data: {'chatId': chatId},
        );
        return;
      }
      liveArchived = liveRaw['archived'] == true;
    }

    if (liveArchived != desired) {
      DebugLogger.warning(
        'archive-confirm-mismatch',
        scope: 'sync/push',
        data: {'chatId': chatId, 'desired': desired, 'actual': liveArchived},
      );
      await _storeChatArchiveMirror(chatId, liveArchived);
    }
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
      await _db.chatsDao.purgeReconciledChat(chatId);
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
      final parentId = payload['parentId'] is String
          ? payload['parentId'] as String
          : null;
      final data = _asMap(payload['data']);
      final meta = _asMap(payload['meta']);

      if (createIfAbsent && folderId.startsWith('local:')) {
        final resolvedName = name;
        if (resolvedName == null || resolvedName.trim().isEmpty) {
          throw SyncTerminalException(
            statusCode: 400,
            message: 'malformed folderUpsert op: missing folder name',
          );
        }
        if (parentId != null && parentId.startsWith('local:')) {
          DebugLogger.log(
            'folder-create-defer-local-parent',
            scope: 'sync/push',
            data: {'folderId': folderId, 'parentId': parentId},
          );
          throw _OutboxDeferred(
            'createFolder deferred until parent remap completes: $folderId',
          );
        }
        final resp = await _client.createFolder(
          name: resolvedName,
          parentId: parentId,
          data: data,
          meta: meta,
        );
        final serverId = resp['id'];
        if (serverId is! String || serverId.isEmpty) {
          throw StateError('createFolder response without a string id');
        }
        final serverUpdatedAt = _epoch(resp['updated_at']) ?? 0;
        // Remap under the SERVER folder lock (we already hold the local one),
        // committing the §7.3 transaction before the op is marked done.
        await _folderLocks.runExclusive(serverId, () async {
          await _remapper.remapFolder(
            localId: folderId,
            serverId: serverId,
            serverUpdatedAt: serverUpdatedAt,
          );
          await _clearFolderDirty(serverId);
        });
        return;
      }

      final hasFolderPatch = name != null || data != null || meta != null;
      if (hasFolderPatch) {
        final folderResp = await _client.updateFolder(
          folderId,
          name: name,
          data: data,
          meta: meta,
        );
        if (folderResp == null) {
          DebugLogger.warning(
            'folder-update-404',
            scope: 'sync/push',
            data: {'folderId': folderId},
          );
          await _db.foldersDao.purgeReconciledFolder(folderId);
          return;
        }
      }
      if (parentId != null || payload.containsKey('parentId')) {
        if (parentId != null && parentId.startsWith('local:')) {
          DebugLogger.log(
            'folder-parent-defer-local-parent',
            scope: 'sync/push',
            data: {'folderId': folderId, 'parentId': parentId},
          );
          throw _OutboxDeferred(
            'updateFolderParent deferred until parent remap completes: '
            '$folderId',
          );
        }
        final parentUpdated = await _client.updateFolderParent(
          folderId,
          parentId,
        );
        if (!parentUpdated) {
          DebugLogger.warning(
            'folder-update-404',
            scope: 'sync/push',
            data: {'folderId': folderId},
          );
          await _db.foldersDao.purgeReconciledFolder(folderId);
          return;
        }
      }
      await _clearFolderDirty(folderId);
    });
  }

  /// Deletes the folder server-side with `delete_contents=false` (BINDING: the
  /// server default `true` would also delete contained chats), then purges the
  /// local folder row. A 404 already-gone response is still a successful delete.
  Future<void> pushFolderDelete(String folderId) async {
    await _folderLocks.runExclusive(folderId, () async {
      await _client.deleteFolder(folderId, deleteContents: false);
      await _db.foldersDao.purgeReconciledFolder(folderId);
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
      for (
        var start = 0;
        start < messageIds.length;
        start += _sqliteVariableBatchSize
      ) {
        final end = start + _sqliteVariableBatchSize;
        final batch = messageIds.sublist(
          start,
          end > messageIds.length ? messageIds.length : end,
        );
        await (_db.update(_db.messages)
              ..where((t) => t.chatId.equals(chatId) & t.id.isIn(batch)))
            .write(const MessagesCompanion(dirty: Value(false)));
      }
    });
  }

  Future<void> _clearFolderDirty(String folderId) {
    return (_db.update(_db.folders)..where((t) => t.id.equals(folderId))).write(
      const FoldersCompanion(dirty: Value(false)),
    );
  }

  Future<void> _storeChatArchiveMirror(String chatId, bool archived) {
    return (_db.update(_db.chats)..where((t) => t.id.equals(chatId))).write(
      ChatsCompanion(archived: Value(archived)),
    );
  }

  Future<void> _storeChatPinMirror(String chatId, bool pinned) {
    return (_db.update(_db.chats)..where((t) => t.id.equals(chatId))).write(
      ChatsCompanion(pinned: Value(pinned)),
    );
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static List<String> _messageIdsIfSnapshotMatches(
    ChatRow chat,
    List<MessageRow> messages,
    String? contentHash,
  ) {
    if (contentHash == null || contentHash.isEmpty) {
      return const [];
    }
    final currentHash = createChatContentHash(chatRowsFromDb(chat, messages));
    if (currentHash != contentHash) {
      DebugLogger.log(
        'create-already-satisfied-hash-changed',
        scope: 'sync/push',
        data: {'chatId': chat.id},
      );
      return const [];
    }
    return [for (final message in messages) message.id];
  }

  static int? _epoch(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

class _OutboxDeferred implements OutboxDeferralException {
  const _OutboxDeferred(this.message);

  final String message;

  @override
  String toString() => message;
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
