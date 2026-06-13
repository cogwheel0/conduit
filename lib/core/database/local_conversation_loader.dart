import 'dart:async';

import '../models/conversation.dart';
import '../services/conversation_parsing.dart';
import '../services/worker_manager.dart';
import '../sync/sync_engine.dart';
import '../utils/debug_logger.dart';
import 'database_provider.dart';
import 'mappers/conversation_assembler.dart';

/// Message count above which assembly is offloaded to the worker isolate
/// (mirrors `ApiService._shouldUseWorkerForConversationPayload`).
const int kLocalConversationWorkerThreshold = 100;

/// DB-first conversation open (CDT-RFC-001 Phase 1, acceptance 1).
///
/// Returns the assembled [Conversation] when the local row exists and its
/// body is synced; `null` otherwise so the caller can fall back to the
/// network path. Accepts any Riverpod ref/container via dynamic dispatch
/// (mirrors `refreshConversationsCache`).
/// Fire-and-forget background pull for one chat. Best-effort freshening:
/// swallows every failure (engine unavailable, network down) so DB-first
/// opens never degrade to network-first.
void schedulePullChatNow(dynamic ref, String id) {
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

Future<Conversation?> loadLocalConversation(dynamic ref, String id) async {
  try {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return null;
    final chat = await db.chatsDao.getChat(id);
    if (chat == null || !chat.bodySynced) return null;
    final messages = await db.messagesDao.getForChat(id);
    if (messages.length > kLocalConversationWorkerThreshold) {
      final envelope = buildChatResponseEnvelope(chat, messages);
      final workerManager = ref.read(workerManagerProvider);
      return await workerManager.schedule(
        parseFullConversationModelWorker,
        envelope,
        debugLabel: 'db.assembleConversation',
      ) as Conversation;
    }
    return assembleConversation(chat, messages);
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
