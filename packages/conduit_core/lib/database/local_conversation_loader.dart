import 'dart:async';

import 'package:conduit_core/models/conversation.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/services/worker_manager.dart';

import 'package:conduit_core/sync/sync_engine.dart';

import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:dio/dio.dart' show DioException;

// kLocalConversationWorkerThreshold is defined in
// mappers/conversation_assembler.dart and re-exported here for callers that
// already import local_conversation_loader.dart. Do NOT redeclare it.
export 'package:conduit_core/database/mappers/conversation_assembler.dart'
    show kLocalConversationWorkerThreshold;

/// Fire-and-forget background pull for one chat. Best-effort freshening:
/// swallows every failure (engine unavailable, network down) so DB-first
/// opens never degrade to network-first.
void schedulePullChatNow(
  dynamic ref,
  String id, {
  OpenWebUiConversationReadSnapshot? ownership,
}) {
  final effectiveOwnership = ownership ?? captureOpenWebUiConversationRead(ref);
  if (effectiveOwnership == null ||
      !openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
    return;
  }
  try {
    final future =
        ref.read(syncEngineProvider.notifier).pullChatNow(id)
            as Future<Object?>;
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'background-pull-failed',
          scope: 'db/conversation',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
        return null;
      }),
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'background-pull-unavailable',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
  }
}

/// Stored message JSON longer than this is checked for server changes with a
/// pull cycle instead of being downloaded again on every open. A cycle reads
/// the recent, archived, folder and note lists (about 12 KB compressed on a
/// typical account); a chat this size costs more than that to download, while
/// smaller chats are cheaper to fetch directly.
const int kOpenRefreshDirectPullMaxPayloadLength = 64 * 1024;

/// Background freshening for a stored OpenWebUI chat that was just opened.
///
/// A large, clean, fully stored chat joins a pull cycle: the cycle lists what
/// changed since the last one and fetches this chat only if the server's copy
/// moved, and the open chat's message watch shows the result. Anything else
/// takes the single-chat pull. Either way a change made before the open is
/// seen, because the list is read after it. Awaiting this only sizes the chat.
Future<void> scheduleOpenedChatRefresh(
  dynamic ref,
  String id, {
  OpenWebUiConversationReadSnapshot? ownership,
}) async {
  final effectiveOwnership = ownership ?? captureOpenWebUiConversationRead(ref);
  if (effectiveOwnership == null ||
      !openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
    return;
  }
  final db = effectiveOwnership.database;
  var checkWithCycle = false;
  if (db != null) {
    try {
      final chat = await db.chatsDao.getChat(id);
      checkWithCycle =
          chat != null &&
          chat.bodySynced &&
          !chat.dirty &&
          !chat.deleted &&
          await db.messagesDao.payloadLengthForChat(id) >
              kOpenRefreshDirectPullMaxPayloadLength;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'open-refresh-size-failed',
        scope: 'db/conversation',
        error: error,
        stackTrace: stackTrace,
        data: {'id': id},
      );
    }
  }
  if (!checkWithCycle) {
    schedulePullChatNow(ref, id, ownership: effectiveOwnership);
    return;
  }
  if (!openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) return;
  DebugLogger.log(
    'open-refresh-cycle',
    scope: 'db/conversation',
    data: {'id': id},
  );
  try {
    final future =
        ref
                .read(syncEngineProvider.notifier)
                .requestPull(reason: 'open-large-chat')
            as Future<Object?>;
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'background-pull-failed',
          scope: 'db/conversation',
          error: error,
          stackTrace: stackTrace,
          data: {'id': id},
        );
        return null;
      }),
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'background-pull-unavailable',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
  }
}

/// First open of an OpenWebUI chat with no stored body: one download through
/// the sync engine, which stores the chat when [storeIf] accepts the raw
/// response, so the next open is DB-first without fetching it a second time.
///
/// Returns null when the engine yields nothing (inert or unavailable, a 404,
/// a read outdated by a bulk change) or fails for a reason other than the
/// network, so the caller can fall back to its direct fetch. Network failures
/// propagate, as they would from that fetch.
Future<Conversation?> fetchChatNowForOpen(
  dynamic ref,
  String id, {
  required bool Function(Map<String, dynamic> response) storeIf,
}) async {
  try {
    final future =
        ref.read(syncEngineProvider.notifier).fetchChatNow(id, storeIf: storeIf)
            as Future<Conversation?>;
    return await future;
  } on DioException {
    rethrow;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'open-fetch-failed',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
    return null;
  }
}

/// Freshen one chat through the sync engine, falling back to a direct API
/// fetch when the engine is inert/unavailable (no database, reviewer mode).
///
/// Returns the assembled [Conversation], or `null` when the engine yielded
/// nothing AND no API service is available. Shared by the passive/resume
/// refresh paths (CDT-RFC-001 Phase 1).
Future<Conversation?> pullChatOrFetch(dynamic ref, String id) async {
  final ownership = captureOpenWebUiConversationRead(ref);
  if (ownership == null) return null;
  final api = ownership.api;
  final syncEngine = ref.read(syncEngineProvider.notifier);

  Conversation? refreshed;
  try {
    refreshed = await syncEngine.pullChatNow(id);
  } catch (_) {
    refreshed = null;
  }
  if (!openWebUiConversationReadIsCurrent(ref, ownership)) return null;
  if (refreshed == null) {
    if (api == null) return null;
    try {
      refreshed = await api.getConversation(id);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'fallback-fetch-failed',
        scope: 'db/conversation',
        error: error,
        stackTrace: stackTrace,
        data: {'id': id},
      );
      return null;
    }
    if (!openWebUiConversationReadIsCurrent(ref, ownership)) return null;
  }
  return refreshed;
}

/// DB-first conversation open (CDT-RFC-001 Phase 1, acceptance 1).
///
/// Returns the assembled [Conversation] when the local row exists and its
/// body is synced; `null` otherwise so the caller can fall back to the
/// network path. Accepts any Riverpod ref/container via dynamic dispatch
/// (mirrors `refreshConversationsCache`).
Future<Conversation?> loadLocalConversation(
  dynamic ref,
  String id, {
  OpenWebUiConversationReadSnapshot? ownership,
}) async {
  final effectiveOwnership = ownership ?? captureOpenWebUiConversationRead(ref);
  final db = effectiveOwnership?.database;
  if (effectiveOwnership == null ||
      db == null ||
      !openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
    return null;
  }
  try {
    final chat = await db.chatsDao.getChat(id);
    if (!openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
      return null;
    }
    if (chat == null || !chat.bodySynced) return null;
    final messages = await db.messagesDao.getForChat(id);
    if (!openWebUiConversationReadIsCurrent(ref, effectiveOwnership)) {
      return null;
    }
    late final Conversation conversation;
    if (messages.length > kLocalConversationWorkerThreshold) {
      final envelope = buildChatResponseEnvelope(chat, messages);
      final workerManager = ref.read(workerManagerProvider);
      conversation = await workerManager.schedule(
        parseFullConversationModelWorker,
        envelope,
        debugLabel: 'db.assembleConversation',
      );
    } else {
      conversation = assembleConversation(chat, messages);
    }
    return openWebUiConversationReadIsCurrent(ref, effectiveOwnership)
        ? conversation
        : null;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'local-load-failed',
      scope: 'db/conversation',
      error: error,
      stackTrace: stackTrace,
      data: {'id': id},
    );
    return null;
  }
}
