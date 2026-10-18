import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_provenance.dart';
import 'package:conduit_core/features/librechat/services/librechat_sync_engine.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/primary_sync.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Conversations with a LibreChat reply generating right now. A pull never
/// overwrites one of these; the chat pipeline adds and removes ids as its
/// turns start and end.
final libreChatActiveGenerationsProvider =
    NotifierProvider<LibreChatActiveGenerations, Set<String>>(
      LibreChatActiveGenerations.new,
    );

class LibreChatActiveGenerations extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void add(String conversationId) => state = {...state, conversationId};

  void remove(String conversationId) =>
      state = {...state}..remove(conversationId);
}

/// The sends the LibreChat outbox drains, once the chat pipeline provides
/// them; null until then, and queued sends wait.
final libreChatCompletionRunnerProvider = Provider<RequestCompletionRunner?>(
  (ref) => null,
);

/// Per-chat locks for the signed-in LibreChat account's database, shared by
/// its sync engine and every local write, so a pull and an edit never
/// interleave on one chat. A new database gets new locks.
final libreChatChatLocksProvider = Provider<ChatLocks>((ref) {
  ref.watch(libreChatDatabaseProvider);
  return ChatLocks();
});

/// The sync engine of the signed-in LibreChat account, or null when none is
/// signed in.
final libreChatSyncEngineProvider = Provider<LibreChatSyncEngine?>((ref) {
  final db = ref.watch(libreChatDatabaseProvider);
  final api = ref.watch(libreChatApiServiceProvider);
  if (db == null || api == null) return null;
  final engine = LibreChatSyncEngine(
    db: db,
    api: api,
    locks: ref.watch(libreChatChatLocksProvider),
    isOnline: () => ref.mounted && ref.read(isOnlineProvider),
    isGenerating: (conversationId) =>
        ref.mounted &&
        ref.read(libreChatActiveGenerationsProvider).contains(conversationId),
    completion: ref.watch(libreChatCompletionRunnerProvider),
  );
  ref.onDispose(engine.close);
  return engine;
});

/// The LibreChat account in use changed while one of its chats was being
/// read; the result belongs to the account that left and is dropped.
final class LibreChatAccountChangedException implements Exception {
  const LibreChatAccountChangedException();

  @override
  String toString() =>
      'LibreChatAccountChangedException: the LibreChat account changed '
      'while a chat was loading';
}

/// The [PrimarySync] of a LibreChat account that owns the Chats tab.
final libreChatPrimarySyncProvider = Provider<PrimarySync>(
  (ref) => LibreChatPrimarySync(ref),
);

/// Drives the signed-in LibreChat account's [LibreChatSyncEngine] from the
/// app-wide sync triggers and refreshes.
final class LibreChatPrimarySync implements PrimarySync {
  LibreChatPrimarySync(this._ref);

  final Ref _ref;

  LibreChatSyncEngine? get _engine => _ref.read(libreChatSyncEngineProvider);

  @override
  bool get canSync => _engine != null;

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    final engine = _engine;
    if (engine == null) return null;
    DebugLogger.log(
      'request',
      scope: 'librechat/sync',
      data: {'reason': reason},
    );
    try {
      final result = await engine.pull();
      // A sync cycle also retries changes still queued from an earlier
      // attempt, as Open WebUI's does.
      await engine.drain();
      return result;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'pull-failed',
        scope: 'librechat/sync',
        error: error,
        stackTrace: stackTrace,
      );
      return const PullResult(success: false, watermarkAdvanced: false);
    }
  }

  /// Connectivity is back: queued changes waiting out a retry delay run now.
  @override
  Future<void> drainNow() async => _engine?.drainNow();

  @override
  Future<void> drainOutbox() async => _engine?.drain();

  @override
  Future<void> reconcileNow() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.pull(forceReconcile: true);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'reconcile-failed',
        scope: 'librechat/sync',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<Conversation?> pullChatNow(String chatId) async {
    final engine = _engine;
    if (engine == null || !await engine.pullChat(chatId)) return null;
    final chat = await engine.db.chatsDao.getChat(chatId);
    if (chat == null || chat.deleted || !chat.bodySynced) return null;
    final messages = await engine.db.messagesDao.getCompleteActiveBranchRows(
      chatId,
    );
    return stampLibreChatProvenance(
      annotateConversationStorage(
        assembleConversation(chat, messages),
        ChatStorageKind.libreChat,
      ),
    );
  }
}
