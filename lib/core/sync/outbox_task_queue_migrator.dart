import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import '../database/mappers/chat_blob_mapper.dart';
import '../persistence/hive_boxes.dart';
import '../utils/debug_logger.dart';
import 'chat_locks.dart';
import 'clock.dart';
import 'id_remapper.dart';

/// One-time migration of the legacy Hive outbound task queue
/// (`caches['outbound_task_queue_v1']`) into local chats/messages + outbox ops
/// (CDT-RFC-001 §9 step 2, Contract D).
///
/// Runs BEFORE the first pull, gated to run exactly once per server via the
/// per-server `sync_meta['outbox_task_queue_migrated']` flag (the outbox is
/// per-server, so the flag lives in the active server DB, not Hive metadata).
/// Idempotent across partial failures: each task's rows+ops are written in its
/// own `ChatLocks`-serialized transaction, createChat ops carry a
/// `contentHash` so a re-run dedupes, and the flag + Hive key deletion happen
/// ONLY after every eligible task converted (R7).
///
/// Pure-Dart-ish: takes its collaborators by injection (no Riverpod) so it is
/// unit-testable against an in-memory [AppDatabase]. Only chat-op + completion
/// task variants are ported; `uploadMedia` stays on AttachmentUploadQueue and
/// the dead task variants are dropped with a logged count.
class OutboxTaskQueueMigrator {
  OutboxTaskQueueMigrator({
    required AppDatabase db,
    required HiveBoxes hiveBoxes,
    required ChatLocks chatLocks,
    required SyncClock clock,
    String Function() resolveDefaultModel = _emptyModel,
    Uuid uuid = const Uuid(),
  })  : _db = db,
        _boxes = hiveBoxes,
        _chatLocks = chatLocks,
        _clock = clock,
        _resolveDefaultModel = resolveDefaultModel,
        _uuid = uuid;

  /// Per-server `sync_meta` flag set to `'1'` once migration completes (D3).
  static const String migratedFlagKey = 'outbox_task_queue_migrated';

  static String _emptyModel() => '';

  final AppDatabase _db;
  final HiveBoxes _boxes;
  final ChatLocks _chatLocks;
  final SyncClock _clock;
  final String Function() _resolveDefaultModel;
  final Uuid _uuid;

  /// Migrates eligible queued/running tasks into the outbox, exactly once.
  ///
  /// Returns a [TaskQueueMigrationReport] summarizing what happened (also used
  /// by tests). A no-op (flag already set, or no key present) returns a report
  /// with `alreadyMigrated`/`converted == 0`.
  Future<TaskQueueMigrationReport> migrateIfNeeded() async {
    final flag = await _db.syncMetaDao.getValue(migratedFlagKey);
    if (flag == '1') {
      return const TaskQueueMigrationReport(alreadyMigrated: true);
    }

    final raw = _readRawTasks();
    if (raw == null) {
      // No persisted queue at all: nothing to migrate, but DO NOT set the flag
      // yet — a later SharedPrefs→Hive migration on a future startup could
      // still land tasks before this migrator runs. The flag is set only after
      // an actual conversion pass over a present key.
      return const TaskQueueMigrationReport();
    }

    var converted = 0;
    var droppedUpload = 0;
    var droppedDead = 0;
    var skippedDuplicate = 0;

    for (final json in raw) {
      final type = json['runtimeType'] ?? json['type'];
      try {
        if (type == 'sendTextMessage') {
          final status = json['status'] as String?;
          if (status != 'queued' && status != 'running') {
            continue; // succeeded/failed/cancelled are not re-sent.
          }
          final result = await _convertSendText(json);
          if (result == _ConvertOutcome.converted) {
            converted++;
          } else {
            skippedDuplicate++;
          }
        } else if (type == 'uploadMedia') {
          // Media uploads stay on AttachmentUploadQueue (NOT the Phase 2
          // outbox). Drop here; the user can re-trigger an unsent upload.
          droppedUpload++;
        } else {
          // executeToolCall / generateImage / imageToDataUrl: dead paths.
          droppedDead++;
        }
      } catch (error, stack) {
        DebugLogger.error(
          'task-queue migration aborted mid-pass',
          scope: 'outbox/migrate',
          error: error,
          stackTrace: stack,
          data: {'type': type},
        );
        // Abort WITHOUT setting the flag or deleting the key: next startup
        // retries, and contentHash dedupe prevents duplicate chats (R7).
        return TaskQueueMigrationReport(
          converted: converted,
          droppedUpload: droppedUpload,
          droppedDead: droppedDead,
          skippedDuplicate: skippedDuplicate,
          aborted: true,
        );
      }
    }

    // All eligible tasks converted: commit the flag, then purge the Hive key.
    await _db.syncMetaDao.setValue(migratedFlagKey, '1');
    await _boxes.caches.delete(HiveStoreKeys.taskQueue);

    DebugLogger.log(
      'task-queue migration complete',
      scope: 'outbox/migrate',
      data: {
        'converted': converted,
        'droppedUpload': droppedUpload,
        'droppedDead': droppedDead,
        'skippedDuplicate': skippedDuplicate,
      },
    );

    return TaskQueueMigrationReport(
      converted: converted,
      droppedUpload: droppedUpload,
      droppedDead: droppedDead,
      skippedDuplicate: skippedDuplicate,
    );
  }

  /// Reads `caches[taskQueue]`, tolerating both the raw-List and JSON-String
  /// forms EXACTLY as `task_queue._load` does. Returns null when the key is
  /// absent (so the caller does NOT set the migrated flag). The String form is
  /// not merely "theoretically possible" — `task_queue._load` decodes it
  /// (`jsonDecode(stored) as List` when `stored is String`), so any on-disk
  /// queue an app build persisted as a JSON-encoded string MUST be parsed here;
  /// returning an empty list for it would silently DROP every queued send
  /// (§9.2 / D-09 data loss).
  List<Map<String, dynamic>>? _readRawTasks() {
    final stored = _boxes.caches.get(HiveStoreKeys.taskQueue);
    if (stored == null) return null;
    List? rawList;
    if (stored is List) {
      rawList = stored;
    } else if (stored is String && stored.isNotEmpty) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is List) rawList = decoded;
      } catch (error, stack) {
        // Unparseable string: log and treat as absent so the flag is NOT set
        // and a future startup can retry once the value is repaired/replaced,
        // rather than declaring the (non-empty) queue empty and deleting it.
        DebugLogger.error(
          'task-queue migration: unparseable string queue',
          scope: 'outbox/migrate',
          error: error,
          stackTrace: stack,
        );
        return null;
      }
    }
    if (rawList == null) {
      // Present but neither a List nor a non-empty String (e.g. empty string):
      // nothing to migrate, but do NOT claim the queue was processed.
      return null;
    }
    return [
      for (final entry in rawList)
        if (entry is Map) Map<String, dynamic>.from(entry),
    ];
  }

  Future<_ConvertOutcome> _convertSendText(Map<String, dynamic> json) async {
    final conversationId = (json['conversationId'] as String?)?.trim();
    final text = json['text'] as String? ?? '';
    final attachments = _stringList(json['attachments']);
    final toolIds = _stringList(json['toolIds']);
    final pendingFolderId = json['pendingFolderId'] as String?;
    final taskId = json['id'] as String? ?? '';
    final now = _clock.nowEpochSeconds();

    if (conversationId == null || conversationId.isEmpty) {
      // --- NEW local chat (threadKey 'new') ---
      // The local id is random (it gets remapped on create and never enters
      // the contentHash). The message ids are derived DETERMINISTICALLY from
      // the stable legacy task id so a re-run of the same task rebuilds an
      // identical blob -> identical createChatContentHash -> dedupe (R7).
      final localId = 'local:${_uuid.v4()}';
      final userMsgId = _uuid.v5(Namespace.url.value, '$taskId/user');
      final asstId = _uuid.v5(Namespace.url.value, '$taskId/assistant');
      final blob = _buildNewChatBlob(
        userMsgId: userMsgId,
        asstId: asstId,
        text: text,
        attachments: attachments,
        now: now,
      );
      final rows = ChatBlobMapper.blobToRows(
        chatId: localId,
        blob: blob,
        title: _titleFromText(text),
        folderId: pendingFolderId,
        createdAt: now,
        updatedAt: now,
      );
      final contentHash = createChatContentHash(rows);

      // Dedupe across partial-failure re-runs: skip if a createChat op already
      // carries this hash (R7).
      if (await _createOpExistsForHash(contentHash)) {
        return _ConvertOutcome.skippedDuplicate;
      }

      await _chatLocks.runExclusive(localId, () async {
        await _db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: contentHash,
          completion: RequestCompletionPayload(
            assistantMessageId: asstId,
            model: _resolveDefaultModel(),
            toolIds: toolIds,
          ),
        );
      });
      return _ConvertOutcome.converted;
    }

    // --- EXISTING server chat (or an unmaterialized server id) ---
    // The legacy send NEVER pushed updateChat — it relied on the completion
    // endpoint to persist the turn. Mirror that: append the rows + enqueue
    // requestCompletion ONLY (no createChat — the chat exists server-side).
    //
    // Message ids are derived DETERMINISTICALLY from the stable legacy task id
    // (same v5 scheme as the new-chat branch) so a partial-failure re-run over
    // the same task rebuilds the SAME ids instead of new random rows. Combined
    // with the dedupe guard below this makes the existing-chat path idempotent
    // (§9.2 "running twice == once"): without it a re-run would append a SECOND
    // user/assistant pair AND a SECOND (never-coalesced) requestCompletion.
    final userMsgId = _uuid.v5(Namespace.url.value, '$taskId/user');
    final asstId = _uuid.v5(Namespace.url.value, '$taskId/assistant');

    // Idempotency guard: if this task already converted (its deterministic
    // assistant row exists), skip — do not re-append or re-enqueue completion.
    if (await _messageExists(conversationId, asstId)) {
      return _ConvertOutcome.skippedDuplicate;
    }

    // Server-completed guard: a legacy "running" task's completion may have
    // finished SERVER-SIDE before the crash, and `_runOnce` pulls BEFORE this
    // migration runs — so the chat may already hold that turn under the
    // server's OWN message ids (which never match our v5-derived [asstId]).
    // Re-appending here would duplicate the turn AND fire an unwanted second
    // generation. Detect it by content: if the chat's LATEST user message
    // matches this task's text and already has a non-empty assistant reply,
    // the turn is done — skip. (Matching the latest turn, not any historical
    // message, avoids false-skipping legitimately-repeated text.)
    if (await _latestTurnAlreadyCompleted(conversationId, text)) {
      return _ConvertOutcome.skippedDuplicate;
    }

    final existing = await _db.chatsDao.getChat(conversationId);

    await _chatLocks.runExclusive(conversationId, () async {
      if (existing == null) {
        // No local row yet (not pulled). Insert a bodySynced=false stub keyed
        // by the server id so the append has a parent row; the subsequent pull
        // fills the body.
        await _db.chatsDao.upsertEnvelopeStub(
          id: conversationId,
          title: _titleFromText(text),
          createdAt: now,
          updatedAt: now,
          folderId: pendingFolderId,
        );
      }
      await _db.chatsDao.appendMessagesWithUpdateOp(
        chatId: conversationId,
        messages: _messageRowsForExistingChat(
          chatId: conversationId,
          userMsgId: userMsgId,
          asstId: asstId,
          text: text,
          attachments: attachments,
          now: now,
          // Link into the prior conversation tip so the migrated turn isn't an
          // orphaned root (existing == null → a fresh stub → null root).
          parentId: existing?.currentMessageId,
        ),
        currentMessageId: asstId,
        updatedAt: now,
        enqueueCompletion: true,
        completion: RequestCompletionPayload(
          assistantMessageId: asstId,
          model: _resolveDefaultModel(),
          toolIds: toolIds,
        ),
      );
    });
    return _ConvertOutcome.converted;
  }

  /// Whether the message [messageId] already exists for [chatId] — the
  /// idempotency guard for the existing-chat branch (a deterministic assistant
  /// row present means this legacy task already converted on a prior run).
  Future<bool> _messageExists(String chatId, String messageId) async {
    final rows = await (_db.select(_db.messages)
          ..where((t) => t.chatId.equals(chatId) & t.id.equals(messageId))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  /// True when the chat's ACTIVE-BRANCH latest turn is a completed assistant
  /// reply whose user message has content == [userText] — i.e. this legacy
  /// send's turn already completed server-side (and was pulled in before
  /// migration). Follows `currentMessageId` (the active-branch tip) rather than
  /// `orderIndex`, which a regeneration branch could lead, so an off-branch
  /// message with coincidentally-matching text can never trigger a false-skip.
  /// Returns false for empty [userText].
  Future<bool> _latestTurnAlreadyCompleted(
    String chatId,
    String userText,
  ) async {
    if (userText.isEmpty) return false;
    final chat = await _db.chatsDao.getChat(chatId);
    final currentId = chat?.currentMessageId;
    if (currentId == null) return false;
    final rows = await (_db.select(_db.messages)
          ..where((t) => t.chatId.equals(chatId)))
        .get();
    final byId = {for (final r in rows) r.id: r};
    // The active-branch tip must be a COMPLETED assistant reply.
    final tip = byId[currentId];
    if (tip == null ||
        tip.role != 'assistant' ||
        tip.content.trim().isEmpty) {
      return false;
    }
    // Its parent is the active turn's user message.
    final parent = tip.parentId == null ? null : byId[tip.parentId];
    return parent != null &&
        parent.role == 'user' &&
        parent.content == userText;
  }

  /// Whether any outbox op (pending or otherwise) carries [contentHash] —
  /// the createChat fingerprint used for partial-failure dedupe (R7).
  Future<bool> _createOpExistsForHash(String contentHash) async {
    final rows = await (_db.select(_db.outboxOps)
          ..where((t) => t.contentHash.equals(contentHash))
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  // ---- blob/row construction (mirrors the live compose) -------------------

  Map<String, dynamic> _buildNewChatBlob({
    required String userMsgId,
    required String asstId,
    required String text,
    required List<String> attachments,
    required int now,
  }) {
    return <String, dynamic>{
      'title': _titleFromText(text),
      'models': <String>[],
      'history': <String, dynamic>{
        'currentId': asstId,
        'messages': <String, dynamic>{
          userMsgId: <String, dynamic>{
            'id': userMsgId,
            'parentId': null,
            'childrenIds': <String>[asstId],
            'role': 'user',
            'content': text,
            'files': _filesFor(attachments),
            'timestamp': now,
          },
          asstId: <String, dynamic>{
            'id': asstId,
            'parentId': userMsgId,
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': '',
            'model': null,
            'timestamp': now,
          },
        },
      },
    };
  }

  List<MessageRowData> _messageRowsForExistingChat({
    required String chatId,
    required String userMsgId,
    required String asstId,
    required String text,
    required List<String> attachments,
    required int now,
    // The prior active-branch tip (existing.currentMessageId) so the migrated
    // turn LINKS into the conversation tree. Null only for a fresh stub (no
    // prior messages), where the user message is correctly a root.
    required String? parentId,
  }) {
    return <MessageRowData>[
      MessageRowData(
        id: userMsgId,
        chatId: chatId,
        parentId: parentId,
        role: 'user',
        content: text,
        createdAt: now,
        orderIndex: 0,
        payload: <String, dynamic>{
          'id': userMsgId,
          'parentId': parentId,
          'childrenIds': <String>[asstId],
          'role': 'user',
          'content': text,
          'files': _filesFor(attachments),
          'timestamp': now,
        },
      ),
      MessageRowData(
        id: asstId,
        chatId: chatId,
        parentId: userMsgId,
        role: 'assistant',
        content: '',
        createdAt: now,
        orderIndex: 1,
        payload: <String, dynamic>{
          'id': asstId,
          'parentId': userMsgId,
          'childrenIds': <String>[],
          'role': 'assistant',
          'content': '',
          'model': null,
          'timestamp': now,
        },
      ),
    ];
  }

  List<Map<String, dynamic>> _filesFor(List<String> attachments) {
    return [
      for (final id in attachments)
        <String, dynamic>{'type': 'file', 'id': id},
    ];
  }

  static String _titleFromText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'New Chat';
    return trimmed.length <= 50 ? trimmed : trimmed.substring(0, 50);
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return [for (final e in value) if (e is String) e];
    }
    return const <String>[];
  }
}

enum _ConvertOutcome { converted, skippedDuplicate }

/// Outcome summary for [OutboxTaskQueueMigrator.migrateIfNeeded] (tests + logs).
class TaskQueueMigrationReport {
  const TaskQueueMigrationReport({
    this.converted = 0,
    this.droppedUpload = 0,
    this.droppedDead = 0,
    this.skippedDuplicate = 0,
    this.alreadyMigrated = false,
    this.aborted = false,
  });

  final int converted;
  final int droppedUpload;
  final int droppedDead;
  final int skippedDuplicate;
  final bool alreadyMigrated;
  final bool aborted;
}
