import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_provenance.dart';
import 'package:conduit_core/features/librechat/services/librechat_sync_engine.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/services/worker_manager.dart';
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
  /// New chats a reply of this session is writing its first answer in, as
  /// the run named them.
  final Map<String, Conversation> _started = <String, Conversation>{};

  /// Per account: another LibreChat account in use starts with none, so a
  /// chat it holds under the same id never opens as one started here.
  @override
  Set<String> build() {
    ref.watch(activeLibreChatAccountProvider.select((account) => account?.id));
    _started.clear();
    return const <String>{};
  }

  void add(String conversationId) => state = {...state, conversationId};

  void remove(String conversationId) {
    _started.remove(conversationId);
    state = {...state}..remove(conversationId);
  }

  /// Notes [chat] as a new chat whose first reply is generating here.
  void noteStarted(Conversation chat) {
    if (state.contains(chat.id)) _started[chat.id] = chat;
  }

  /// The new chat [conversationId] while its first reply generates here:
  /// its saved copy has no messages yet, and is not pulled while the reply
  /// runs, so opening it starts from this. Null otherwise.
  Conversation? startedChat(String conversationId) =>
      state.contains(conversationId) ? _started[conversationId] : null;
}

/// The sends the LibreChat outbox drains, once the chat pipeline provides
/// them; null until then, and queued sends wait.
final libreChatCompletionRunnerProvider = Provider<RequestCompletionRunner?>(
  (ref) => null,
);

/// Keeps a LibreChat database open until the returned release is called,
/// so a write or pull that began under one account finishes even when the
/// account is left meanwhile; null when the database cannot be held.
final libreChatDatabaseHoldProvider =
    Provider<Future<void> Function()? Function(AppDatabase database)>(
      (ref) => (database) => ref
          .read(libreChatDatabaseManagerProvider)
          .tryAcquireLease(database)
          ?.release,
    );

/// Per-chat locks for the signed-in LibreChat account's database, shared by
/// its sync engine and every local write, so a pull and an edit never
/// interleave on one chat.
///
/// One set per database, not per account change: a quick return to an
/// account can hand back the database earlier work still holds open, and
/// that work and the new must share their locks.
final libreChatChatLocksProvider = Provider<ChatLocks>((ref) {
  final db = ref.watch(libreChatDatabaseProvider);
  if (db == null) return ChatLocks();
  return _libreChatLocksByDatabase[db] ??= ChatLocks();
});

final Expando<ChatLocks> _libreChatLocksByDatabase = Expando<ChatLocks>(
  'librechat-chat-locks',
);

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
    // Left, the account's database is no longer this provider's to hold: a
    // pull still running goes on unheld, as when no lease can be had.
    holdDatabase: () =>
        ref.mounted ? ref.read(libreChatDatabaseHoldProvider)(db) : null,
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
    if (engine == null) return null;
    // The reads after the fetch use the same database, held open meanwhile.
    final release = _ref.read(libreChatDatabaseHoldProvider)(engine.db);
    try {
      return await _pullChatNow(engine, chatId);
    } finally {
      await release?.call();
    }
  }

  Future<Conversation?> _pullChatNow(
    LibreChatSyncEngine engine,
    String chatId,
  ) async {
    if (!await engine.pullChat(chatId)) return null;
    final chat = await engine.db.chatsDao.getChat(chatId);
    if (chat == null || chat.deleted || !chat.bodySynced) return null;
    final messages = await engine.db.messagesDao.getCompleteActiveBranchRows(
      chatId,
    );
    // A long history is read on a worker, as a stored chat's is, so opening
    // it does not freeze the screen.
    final conversation = await assembleConversationGuarded(
      chat,
      messages,
      offload: (envelope) => _ref
          .read(workerManagerProvider)
          .schedule(
            parseFullConversationModelWorker,
            envelope,
            debugLabel: 'librechat.assembleConversation',
          ),
    );
    return stampLibreChatProvenance(
      annotateConversationStorage(conversation, ChatStorageKind.libreChat),
    );
  }
}
