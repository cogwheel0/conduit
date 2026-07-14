import 'dart:async';

import '../models/conversation.dart';
import '../providers/app_providers.dart';
import '../services/conversation_parsing.dart';
import '../services/worker_manager.dart';
import '../sync/sync_engine.dart';
import '../utils/debug_logger.dart';
import 'mappers/conversation_assembler.dart';

// kLocalConversationWorkerThreshold is defined in
// mappers/conversation_assembler.dart and re-exported here for callers that
// already import local_conversation_loader.dart. Do NOT redeclare it.
export 'mappers/conversation_assembler.dart'
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
