import 'dart:math' as math;

import '../database/app_database.dart';
import '../database/mappers/chat_blob_mapper.dart';
import '../database/mappers/conversation_assembler.dart';
import '../models/conversation.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'sync_api_client.dart';

/// Overlap window in server epoch seconds: same-second edits + clock skew
/// between server processes (CDT-RFC-001 §7.1). Re-merges are idempotent,
/// never a correctness cost.
const int kPullOverlapSeconds = 5;

/// Worker pool size for changed-chat fetches (CDT-RFC-001 §10 REQ 4).
const int kPullFetchConcurrency = 4;

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
    required this.fromArchivedList,
    this.title,
    this.createdAt,
  });

  final String id;
  final int updatedAt;
  final int? lastReadAt;
  final bool fromArchivedList;
  final String? title;
  final int? createdAt;
}

/// Watermark-delta pull (CDT-RFC-001 §7.1 + Q-03 archived sub-loop).
///
/// All timestamp comparisons are int-vs-int server epoch seconds;
/// `DateTime.now()` never participates in watermark or merge logic (REQ 5).
class PullSync {
  /// Constructor injection ONLY — no Riverpod here.
  PullSync({
    required SyncApiClient client,
    required AppDatabase db,
    required ChatLocks locks,
  }) : _client = client,
       _db = db,
       _locks = locks;

  final SyncApiClient _client;
  final AppDatabase _db;
  final ChatLocks _locks;

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
        for (final item in items) {
          final parsed = _parseListItem(item, fromArchivedList: false);
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
    try {
      var page = 1;
      var stop = false;
      while (!stop) {
        final items = await _client.getArchivedChatListPage(page);
        for (final item in items) {
          final parsed = _parseListItem(item, fromArchivedList: true);
          if (parsed == null) continue;
          if (parsed.updatedAt > threshold) {
            if (!changed.containsKey(parsed.id)) {
              archivedChanged.add(parsed);
            }
            maxSeen = math.max(maxSeen, parsed.updatedAt);
          } else {
            stop = true;
            break;
          }
        }
        if (stop || items.length < kOpenWebUiChatListPageSize) break;
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

    // Archived items: full-fetch when a synced body would otherwise go
    // stale; envelope-only stub otherwise.
    for (final item in archivedChanged) {
      try {
        final local = await _db.chatsDao.getChat(item.id);
        if (local != null && local.bodySynced) {
          changed.putIfAbsent(item.id, () => item);
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
          await _mergeChatResponse(resp, listLastReadAt: item.lastReadAt);
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

    final changedCount = toFetch.length + archivedChanged.length;
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

  /// Single-chat pull. `getChatRaw` null (404) -> returns null, no local
  /// change (deletion reconcile is Phase 3). Otherwise lock + upsert
  /// (`listLastReadAt: null` — the max() rule preserves the local value) and
  /// return the assembled [Conversation].
  Future<Conversation?> pullChat(String chatId) async {
    final resp = await _client.getChatRaw(chatId);
    if (resp == null) return null;
    final id = resp['id'] is String ? resp['id'] as String : chatId;
    return _locks.runExclusive(id, () async {
      await _upsertServerChatUnlocked(resp, listLastReadAt: null);
      final chat = await _db.chatsDao.getChat(id);
      if (chat == null) return null;
      final messages = await _db.messagesDao.getForChat(id);
      return assembleConversation(chat, messages);
    });
  }

  /// Lock + one-transaction merge of a raw `ChatResponse` map (REQ 1/3).
  Future<void> _mergeChatResponse(
    Map<String, dynamic> resp, {
    required int? listLastReadAt,
  }) {
    final id = resp['id'] is String ? resp['id'] as String : '';
    if (id.isEmpty) {
      throw const FormatException('ChatResponse without a string id');
    }
    return _locks.runExclusive(id, () {
      return _upsertServerChatUnlocked(resp, listLastReadAt: listLastReadAt);
    });
  }

  /// Caller must hold the chat lock. ONE drift transaction per chat inside
  /// the DAO (REQ 1), so the list stream emits once per chat merge.
  Future<void> _upsertServerChatUnlocked(
    Map<String, dynamic> resp, {
    required int? listLastReadAt,
  }) {
    final id = resp['id'] as String;
    final blob = resp['chat'];
    final meta = resp['meta'];
    return _db.chatsDao.upsertServerChat(
      rows: ChatBlobMapper.blobToRows(
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
        createdAt: _asEpochSeconds(resp['created_at']) ?? 0,
        updatedAt: _asEpochSeconds(resp['updated_at']) ?? 0,
      ),
      shareId: resp['share_id'] is String ? resp['share_id'] as String : null,
      meta: meta is Map<String, dynamic>
          ? meta
          : (meta is Map ? Map<String, dynamic>.from(meta) : const {}),
      listLastReadAt: listLastReadAt,
    );
  }

  _ChangedItem? _parseListItem(
    Map<String, dynamic> item, {
    required bool fromArchivedList,
  }) {
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
      fromArchivedList: fromArchivedList,
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
