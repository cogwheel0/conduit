import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/outbox_dao.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/database/mappers/conversation_assembler.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/sync/outbox_drainer.dart';
import '../../../core/utils/debug_logger.dart';
import '../providers/chat_providers.dart';

part 'request_completion_runner.g.dart';

/// Transient error thrown when a queued completion cannot run RIGHT NOW because
/// a live interactive stream already owns the chat (R5). The drainer's default
/// terminal classifier treats it as transient, so the op stays pending and is
/// re-attempted on a later drain (after the live stream finishes) instead of
/// burning toward the N=5 park budget unfairly. Accepting the +1 attempt is the
/// minimal correct behavior.
class CompletionBusyException implements Exception {
  const CompletionBusyException(this.chatId);

  final String chatId;

  @override
  String toString() => 'CompletionBusyException(chat: $chatId)';
}

/// Concrete [RequestCompletionRunner] (Wiring D). Re-enters the EXISTING
/// streaming pipeline ([runQueuedCompletion]) for a drained `requestCompletion`
/// op — it never forks a second streaming implementation, and it is no-op-safe
/// on re-entry (idempotent if the turn already completed).
///
/// Option A (minimal): the streaming pipeline is single-active-conversation
/// scoped, so the runner makes the target chat the active conversation before
/// driving the stream. The D-07 echo (`upsertLocalEcho` keyed on the PK
/// `{chatId, assistantMessageId}`) then updates the SAME placeholder row the
/// `*WithOutbox` DAO wrote at enqueue, guaranteeing one row per turn (R8).
class ChatRequestCompletionRunner implements RequestCompletionRunner {
  ChatRequestCompletionRunner(this._ref);

  final Ref _ref;

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    final decoded = RequestCompletionPayload.fromJson(payload);
    final assistantMessageId = decoded.assistantMessageId;

    final db = _ref.read(appDatabaseProvider);
    if (db == null) {
      // No active db: cannot drive. Throw so the op stays pending and retries
      // once a db is attached.
      throw StateError('requestCompletion: no active database');
    }

    // 1. Streaming-conflict guard (R5): if a LIVE interactive stream owns this
    //    exact chat, defer (throw-transient) so we never clobber it.
    final isStreaming = _ref.read(isChatStreamingProvider);
    final activeId = _ref.read(activeConversationProvider)?.id;
    if (isStreaming && activeId == chatId) {
      DebugLogger.log(
        'completion-deferred-busy',
        scope: 'chat/completion',
        data: {'chatId': chatId},
      );
      throw CompletionBusyException(chatId);
    }

    // 2. Idempotency / already-completed guard (R3): a completed turn leaves the
    //    placeholder row present with non-empty content. The common path is
    //    "row present, empty content" (the drainer enqueues ONE requestCompletion
    //    per turn and markDone deletes it).
    final rows = await db.messagesDao.getForChat(chatId);
    MessageRow? placeholder;
    for (final row in rows) {
      if (row.id == assistantMessageId) {
        placeholder = row;
        break;
      }
    }
    if (placeholder == null) {
      DebugLogger.log(
        'completion-placeholder-absent',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
      );
      return;
    }
    if (placeholder.content.trim().isNotEmpty) {
      DebugLogger.log(
        'completion-already-done',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
      );
      return;
    }

    // 3. Path choice (Option B):
    //    - The target chat IS the one the user is viewing → drive the LIVE
    //      streaming pipeline so they watch their reply stream in (Option A).
    //    - Otherwise (a different chat is foregrounded, or none is) → run
    //      HEADLESS: fire the completion, let the server persist it, pull it
    //      into the local DB — WITHOUT switching the user's active conversation.
    final chatRow = await db.chatsDao.getChat(chatId);
    if (chatRow == null) {
      // Chat row vanished (e.g. a delete won the race): nothing to complete.
      DebugLogger.log(
        'completion-chat-absent',
        scope: 'chat/completion',
        data: {'chatId': chatId},
      );
      return;
    }

    if (activeId == chatId) {
      // Live drive — the placeholder is loaded + marked streaming inside
      // runQueuedCompletion; the stream final + D-07 echo land on the SAME
      // assistantMessageId row (R8 one-row-per-turn).
      await runQueuedCompletion(
        _ref,
        chatId: chatId,
        assistantMessageId: assistantMessageId,
        model: decoded.model,
        toolIds: decoded.toolIds,
        filterIds: decoded.filterIds,
        sessionIdOverride: decoded.sessionIdOverride,
      );
      return;
    }

    // Headless drive — no active-conversation switch, no chatMessagesProvider
    // mutation. Builds the request from this chat's DB rows.
    final conversation = assembleConversation(chatRow, rows);
    await runHeadlessCompletion(
      _ref,
      chatId: chatId,
      assistantMessageId: assistantMessageId,
      messages: conversation.messages,
      conversation: conversation,
      model: decoded.model,
      toolIds: decoded.toolIds,
      filterIds: decoded.filterIds,
      sessionIdOverride: decoded.sessionIdOverride,
    );
  }
}

/// Concrete runner provider; overrides the core/sync seam at startup.
/// `keepAlive` so its `ref` survives for the engine's lifetime.
@Riverpod(keepAlive: true)
RequestCompletionRunner chatRequestCompletionRunner(Ref ref) =>
    ChatRequestCompletionRunner(ref);
