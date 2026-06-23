import 'dart:math' as math;

import '../database/app_database.dart';
import '../database/mappers/chat_blob_mapper.dart';
import '../database/mappers/conversation_assembler.dart';
import '../models/conversation.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'id_remapper.dart';
import 'sync_api_client.dart';
import 'sync_entity_adapter.dart';

/// Overlap window in server epoch seconds: same-second edits + clock skew
/// between server processes (CDT-RFC-001 §7.1). Re-merges are idempotent,
/// never a correctness cost.
const int kPullOverlapSeconds = 5;

/// Worker pool size for changed-chat fetches (CDT-RFC-001 §10 REQ 4). Derived
/// from the generic [kAdapterPullFetchConcurrency] (single source of truth) so
/// chat and note pull concurrency can never silently diverge.
const int kPullFetchConcurrency = kAdapterPullFetchConcurrency;

/// Server page size for `/api/v1/chats/?page=N` and `/api/v1/chats/archived`
/// (verified: `routers/chats.py` `get_session_user_chat_list` /
/// `get_archived_session_user_chat_list`, `limit = 60` — NOT 50).
const int kOpenWebUiChatListPageSize = 60;

/// Outcome of one pull cycle.
class PullResult {
  const PullResult({
    required this.success,
    this.changedChats = 0,
    this.failedFetches = 0,
    required this.watermarkAdvanced,
    this.foldersFeatureEnabled,
  });

  /// No fetch failures anywhere in the cycle.
  final bool success;
  final int changedChats;
  final int failedFetches;
  final bool watermarkAdvanced;

  /// Null when the folders fetch errored (feature state unknown).
  final bool? foldersFeatureEnabled;
}

/// One changed list item (raw `ChatTitleIdResponse` projection) plus the
/// envelope fields the archived stub upsert needs.
class _ChangedItem {
  const _ChangedItem({
    required this.id,
    required this.updatedAt,
    this.lastReadAt,
    this.title,
    this.createdAt,
  });

  final String id;
  final int updatedAt;
  final int? lastReadAt;
  final String? title;
  final int? createdAt;
}

/// Watermark-delta pull (CDT-RFC-001 §7.1 + Q-03 archived sub-loop).
///
/// All timestamp comparisons are int-vs-int server epoch seconds;
/// `DateTime.now()` never participates in watermark or merge logic (REQ 5).
class PullSync {
  /// Constructor injection ONLY — no Riverpod here.
  ///
  /// [remapper] enables the §7.3 createChat crash-heal: when a pulled server
  /// chat matches the content hash of a still-pending local createChat op, the
  /// pull completes the remap (folding the `local:` row into the server row)
  /// instead of inserting a duplicate. When null (read-path-only tests) the
  /// heal is skipped and merges proceed verbatim.
  PullSync({
    required SyncApiClient client,
    required AppDatabase db,
    required ConversationLocks locks,
    IdRemapper? remapper,
  }) : _client = client,
       _db = db,
       _locks = locks,
       _remapper = remapper;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ConversationLocks _locks;
  final IdRemapper? _remapper;

  /// Runs one pull cycle. The watermark advances only when every list page
  /// and every chat fetch succeeded (REQ 5); on any failure it stays frozen
  /// and the idempotent merge makes the next run safe.
  Future<PullResult> run() async {
    final watermark = await _db.syncMetaDao.getPullWatermark();
    final threshold = watermark - kPullOverlapSeconds;
    var maxSeen = watermark;

    // Keyed by chat id; first occurrence wins (list order is newest-first).
    final changed = <String, _ChangedItem>{};

    // 1+2. Main list loop. Any list-page fetch error aborts the whole cycle
    // before any chat fetch.
    try {
      var page = 1;
      var stop = false;
      while (!stop) {
        final items = await _client.getChatListPage(page);
        final changedBefore = changed.length;
        final maxSeenBefore = maxSeen;
        for (final item in items) {
          final parsed = _parseListItem(item);
          if (parsed == null) continue;
          if (parsed.updatedAt > threshold) {
            changed.putIfAbsent(parsed.id, () => parsed);
            maxSeen = math.max(maxSeen, parsed.updatedAt);
          } else {
            stop = true;
            break;
          }
        }
        if (stop || items.length < kOpenWebUiChatListPageSize) break;
        if (changed.length == changedBefore && maxSeen == maxSeenBefore) break;
        page++;
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'list-page-failed',
        scope: 'sync/pull',
        error: error,
        stackTrace: stackTrace,
      );
      return const PullResult(success: false, watermarkAdvanced: false);
    }

    // 3. Archived loop (Q-03 default: metadata only). A list-page error here
    // keeps the cycle going for already-collected chats, but success=false
    // freezes the watermark.
    var archivedListFailed = false;
    final archivedChanged = <_ChangedItem>[];
    final archivedChangedIds = <String>{};
    try {
      var page = 1;
      var stop = false;
      while (!stop) {
        final items = await _client.getArchivedChatListPage(page);
        final archivedChangedBefore = archivedChanged.length;
        final maxSeenBefore = maxSeen;
        for (final item in items) {
          final parsed = _parseListItem(item);
          if (parsed == null) continue;
          if (parsed.updatedAt > threshold) {
            if (!changed.containsKey(parsed.id) &&
                archivedChangedIds.add(parsed.id)) {
              archivedChanged.add(parsed);
            }
            maxSeen = math.max(maxSeen, parsed.updatedAt);
          } else {
            stop = true;
            break;
          }
        }
        if (stop || items.length < kOpenWebUiChatListPageSize) break;
        if (archivedChanged.length == archivedChangedBefore &&
            maxSeen == maxSeenBefore) {
          break;
        }
        page++;
      }
    } catch (error, stackTrace) {
      archivedListFailed = true;
      DebugLogger.error(
        'archived-page-failed',
        scope: 'sync/pull',
        error: error,
        stackTrace: stackTrace,
      );
    }

    var failedFetches = 0;
    var foldedArchivedCount = 0;

    // Archived items: full-fetch when a synced body would otherwise go
    // stale; envelope-only stub otherwise.
    for (final item in archivedChanged) {
      try {
        final local = await _db.chatsDao.getChat(item.id);
        if (local != null && local.bodySynced) {
          changed.putIfAbsent(item.id, () => item);
          foldedArchivedCount++;
        } else {
          await _locks.runExclusive(item.id, () {
            return _db.chatsDao.upsertEnvelopeStub(
              id: item.id,
              title: item.title ?? '',
              createdAt: item.createdAt ?? item.updatedAt,
              updatedAt: item.updatedAt,
              archived: true,
              lastReadAt: item.lastReadAt,
            );
          });
        }
      } catch (error, stackTrace) {
        failedFetches++;
        DebugLogger.error(
          'archived-stub-failed',
          scope: 'sync/pull',
          error: error,
          stackTrace: stackTrace,
          data: {'chatId': item.id},
        );
      }
    }

    // 4. Folders (RFC §7.6, fast-forward LWW). Folder failure NEVER blocks
    // the chat watermark.
    bool? foldersFeatureEnabled;
    try {
      final (rawFolders, enabled) = await _client.getFoldersRaw();
      foldersFeatureEnabled = enabled;
      if (enabled) {
        await _db.foldersDao.replaceServerFolders(rawFolders);
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'folders-failed',
        scope: 'sync/pull',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // 5. Chat fetches: newest-first (list order already is), worker pool of
    // exactly kPullFetchConcurrency sharing one queue index.
    final toFetch = changed.values.toList(growable: false);
    final hasPendingCreateHashes = _remapper == null
        ? false
        : await _db.outboxDao.hasPendingCreateContentHashes();
    var nextIndex = 0;
    Future<void> worker() async {
      while (true) {
        if (nextIndex >= toFetch.length) return;
        final item = toFetch[nextIndex++];
        try {
          final resp = await _client.getChatRaw(item.id);
          if (resp == null) {
            // Server-deleted: counts as success; no local change in Phase 1
            // (deletion reconcile is Phase 3).
            continue;
          }
          await _mergeChatResponse(
            resp,
            listLastReadAt: item.lastReadAt,
            hasPendingCreateHashes: hasPendingCreateHashes,
          );
        } catch (error, stackTrace) {
          failedFetches++;
          DebugLogger.error(
            'chat-fetch-failed',
            scope: 'sync/pull',
            error: error,
            stackTrace: stackTrace,
            data: {'chatId': item.id},
          );
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < kPullFetchConcurrency; i++) worker(),
    ]);

    // 6. Watermark advance rule (REQ 5).
    final success = !archivedListFailed && failedFetches == 0;
    final watermarkAdvanced = success && maxSeen > watermark;
    if (success) {
      await _db.syncMetaDao.setPullWatermark(maxSeen);
    }

    final changedCount =
        toFetch.length + (archivedChanged.length - foldedArchivedCount);
    DebugLogger.log(
      'cycle-done',
      scope: 'sync/pull',
      data: {
        'changed': changedCount,
        'failed': failedFetches,
        'watermark': maxSeen,
        'advanced': watermarkAdvanced,
        'folders': foldersFeatureEnabled,
      },
    );
    return PullResult(
      success: success,
      changedChats: changedCount,
      failedFetches: failedFetches,
      watermarkAdvanced: watermarkAdvanced,
      foldersFeatureEnabled: foldersFeatureEnabled,
    );
  }

  // ---- SyncEntityAdapter seam (CDT-RFC-001 Phase 5) ----
  //
  // These expose the GENUINELY-shared chat pull surface to [ChatAdapter] so the
  // drainer/seam can treat chats and notes uniformly. The chat-only axes — the
  // Q-03 archived sub-loop, §7.6 folders, and the §7.3 createChat crash-heal —
  // are NOT here: they stay in the concrete [run] orchestrator above (the
  // archived loop folds into the SAME watermark/worker-pool as the main list, a
  // coupling that the generic `runPullFor` driver deliberately does not model —
  // see the seam's anti-over-abstraction caveat). So `runPullFor` drives NOTES
  // and the chat-only [run] keeps its integrated orchestration; both share the
  // merge/list/fetch primitives below.

  /// One MAIN-list page as generic [SyncListItem]s (epoch SECONDS), newest
  /// first. Excludes the archived list (a chat-only axis kept inside [run]).
  Future<List<SyncListItem>> mainListPage(int page) async {
    final items = await _client.getChatListPage(page);
    return [
      for (final item in items)
        if (_parseListItem(item) case final p?)
          SyncListItem(id: p.id, updatedAt: p.updatedAt, envelope: item),
    ];
  }

  /// Full `ChatResponse` fetch; null on 404. Adapter seam.
  Future<Map<String, dynamic>?> fetchChatRaw(String id) =>
      _client.getChatRaw(id);

  /// Lock + one-tx merge of a raw `ChatResponse` map with `listLastReadAt: null`
  /// (the max() rule preserves the local value). Returns `mustPush`. Adapter
  /// seam — the archived path inside [run] supplies a real lastReadAt and is NOT
  /// routed here.
  Future<bool> mergeChatResponseForAdapter(Map<String, dynamic> resp) =>
      _mergeChatResponse(resp, listLastReadAt: null);

  /// Single-chat pull. `getChatRaw` null (404) -> returns null, no local
  /// change (deletion reconcile is Phase 3). Otherwise lock + upsert
  /// (`listLastReadAt: null` — the max() rule preserves the local value) and
  /// return the assembled [Conversation].
  Future<Conversation?> pullChat(String chatId) async {
    final resp = await _client.getChatRaw(chatId);
    if (resp == null) return null;
    final id = resp['id'] is String ? resp['id'] as String : chatId;
    return _locks.runExclusive(id, () async {
      await _upsertServerChatUnlockedReturningPush(resp, listLastReadAt: null);
      final chat = await _db.chatsDao.getChat(id);
      if (chat == null) return null;
      final messages = await _db.messagesDao.getForChat(id);
      return assembleConversation(chat, messages);
    });
  }

  /// Lock + one-transaction merge of a raw `ChatResponse` map (REQ 1/3).
  /// Returns `mustPush` from the upsert (REQ 4); pull-path callers ignore it.
  Future<bool> _mergeChatResponse(
    Map<String, dynamic> resp, {
    required int? listLastReadAt,
    bool? hasPendingCreateHashes,
  }) {
    final id = resp['id'] is String ? resp['id'] as String : '';
    if (id.isEmpty) {
      throw const FormatException('ChatResponse without a string id');
    }
    return _locks.runExclusive(id, () {
      return _upsertServerChatUnlockedReturningPush(
        resp,
        listLastReadAt: listLastReadAt,
        hasPendingCreateHashes: hasPendingCreateHashes,
      );
    });
  }

  /// Caller must hold the chat lock. ONE drift transaction per chat inside the
  /// DAO (REQ 1), so the list stream emits once per chat merge. Returns whether
  /// the merge owed a push (REQ 4) — used by the [ChatAdapter] seam's
  /// `mergeServer`; the pull paths ignore the result.
  Future<bool> _upsertServerChatUnlockedReturningPush(
    Map<String, dynamic> resp, {
    required int? listLastReadAt,
    bool? hasPendingCreateHashes,
  }) async {
    final id = resp['id'] as String;
    final createdAt = _asEpochSeconds(resp['created_at']) ?? 0;
    final updatedAt = _asEpochSeconds(resp['updated_at']) ?? 0;
    final blob = resp['chat'];
    final meta = resp['meta'];
    final rows = ChatBlobMapper.blobToRows(
      chatId: id,
      blob: blob is Map<String, dynamic>
          ? blob
          : (blob is Map
                ? Map<String, dynamic>.from(blob)
                : <String, dynamic>{}),
      title: resp['title'] is String ? resp['title'] as String : '',
      folderId: resp['folder_id'] is String
          ? resp['folder_id'] as String
          : null,
      pinned: resp['pinned'] == true,
      archived: resp['archived'] == true,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

    // §7.3 createChat crash-heal: if this server chat is the materialization of
    // a local createChat that crashed between server-create and remap-commit,
    // its content hash matches a still-pending createChat op carrying a DIFFERENT
    // (local:) chat id. Complete the remap (folding the local row into this
    // server id) and drop the op instead of inserting a duplicate row that would
    // then be re-POSTed on the next drain.
    if (await _tryHealCreate(
      rows: rows,
      serverId: id,
      serverCreatedAt: createdAt,
      serverUpdatedAt: updatedAt,
      hasPendingCreateHashes: hasPendingCreateHashes,
    )) {
      return false;
    }

    // §7.4 three-way merge runs inside ONE drift transaction in the DAO
    // (REQ §10.1); the dirty read + decision + write are atomic under the chat
    // lock we already hold.
    final write = await _db.chatsDao.mergeServerChat(
      server: rows,
      shareId: resp['share_id'] is String ? resp['share_id'] as String : null,
      meta: meta is Map<String, dynamic>
          ? meta
          : (meta is Map ? Map<String, dynamic>.from(meta) : const {}),
      listLastReadAt: listLastReadAt,
    );

    // REQ 4: a merge that retained local-dirty content diverges from the
    // server, so it must be pushed. ChatsDao reasserts the updateChat op inside
    // the merge transaction so dirty rows and outbox state stay atomic.
    return write.mustPush;
  }

  /// Attempts the §7.3 content-hash crash-heal. Returns true when it ran the
  /// remap (caller must NOT then upsert a separate row). No-op (false) when no
  /// remapper is wired, the server id already matches the op's chat id (the row
  /// is already at the server id), or no pending createChat op fingerprint
  /// matches this server blob.
  Future<bool> _tryHealCreate({
    required ChatRows rows,
    required String serverId,
    required int serverCreatedAt,
    required int serverUpdatedAt,
    bool? hasPendingCreateHashes,
  }) async {
    final remapper = _remapper;
    if (remapper == null) return false;

    final hasPendingCreate =
        hasPendingCreateHashes ??
        await _db.outboxDao.hasPendingCreateContentHashes();
    if (!hasPendingCreate) return false;

    // Hash the server-arrived rows under the SERVER id; createChatContentHash
    // excludes the volatile id/timestamp, so this equals the digest recorded on
    // the local op (the server preserves the client's history/message ids on
    // create — only the top-level chat id is reminted).
    final hash = createChatContentHash(rows);
    final op = await _db.outboxDao.claimPendingCreateForHash(hash);
    if (op == null) return false;
    final localId = op.chatId;
    if (localId == null) {
      await _db.outboxDao.markDeferred(
        op.seq,
        error: 'malformed create crash-heal op',
        nextAttemptAt: 0,
      );
      return false;
    }
    if (localId == serverId) {
      // The op was already repointed to this server id by a prior heal/remap.
      // The server chat exists, so satisfy the create and let the normal upsert
      // refresh the row.
      await _db.outboxDao.markDone(op.seq);
      return false;
    }

    DebugLogger.log(
      'create-crash-heal',
      scope: 'sync/pull',
      data: {'from': localId, 'to': serverId, 'seq': op.seq},
    );
    try {
      // We already hold the SERVER id lock (this merge runs under it). The
      // create op was claimed before this LOCAL lock, so a drain worker cannot
      // concurrently claim it and enter pushCreateChat with the opposite lock
      // order.
      await _locks.runExclusive(localId, () async {
        await remapper.remapChat(
          localId: localId,
          serverId: serverId,
          serverCreatedAt: serverCreatedAt,
          serverUpdatedAt: serverUpdatedAt,
        );
        // The remap repointed the claimed createChat op's chat_id to the server
        // id (§7.3). The chat now exists server-side, so the create is
        // satisfied: drop the op so the drainer never re-POSTs it.
        await _db.outboxDao.markDone(op.seq);
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'create-crash-heal-failed',
        scope: 'sync/pull',
        error: error,
        stackTrace: stackTrace,
        data: {'from': localId, 'to': serverId, 'seq': op.seq},
      );
      await _db.outboxDao.markDeferred(
        op.seq,
        error: 'create crash-heal failed: $error',
        nextAttemptAt: 0,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
    return true;
  }

  _ChangedItem? _parseListItem(Map<String, dynamic> item) {
    final id = item['id'];
    final updatedAt = _asEpochSeconds(item['updated_at']);
    if (id is! String || id.isEmpty || updatedAt == null) {
      DebugLogger.warning(
        'malformed-list-item',
        scope: 'sync/pull',
        data: {'item': item.toString()},
      );
      return null;
    }
    return _ChangedItem(
      id: id,
      updatedAt: updatedAt,
      lastReadAt: _asEpochSeconds(item['last_read_at']),
      title: item['title'] is String ? item['title'] as String : null,
      createdAt: _asEpochSeconds(item['created_at']),
    );
  }

  /// Server epoch seconds; never derived from the device clock (REQ 5).
  static int? _asEpochSeconds(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}
