import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider, isChatStreamingProvider;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// The model the user last picked in an open chat, with the last message at
/// that moment. Open WebUI 0.12.5 regenerates an answer with the model picked
/// now; Conduit's comparisons are per turn, so an answer of a multi-model turn
/// keeps its own model unless a model was picked after that turn was sent.
typedef ChatModelPick = ({
  String chatId,
  String modelId,
  String? afterMessageId,
});

final chatModelPickProvider =
    NotifierProvider<ChatModelPickNotifier, ChatModelPick?>(
      ChatModelPickNotifier.new,
    );

class ChatModelPickNotifier extends Notifier<ChatModelPick?> {
  /// A pick belongs to the account that made it: another account, or the
  /// same one signed in again, starts without one.
  @override
  ChatModelPick? build() {
    ref
      ..watch(currentUserProvider2.select((user) => user?.id))
      ..watch(openWebUiAuthSessionEpochProvider);
    return null;
  }

  void record({
    required String chatId,
    required String modelId,
    String? afterMessageId,
  }) {
    state = (chatId: chatId, modelId: modelId, afterMessageId: afterMessageId);
  }
}

/// Saves [model], which the user just picked (from the model picker or with
/// an @-mention), as the open chat's model.
///
/// Open WebUI 0.12.5's web client saves the chat's model list as soon as the
/// model is changed, so the chat reopens on it even when nothing was sent
/// since. Conduit does the same, through [chatModelSaveQueueProvider]: the
/// list is stored with the local chat and sent as the chat's only changed
/// key, which every supported server merges without touching the chat's
/// date. Only a saved Open WebUI chat this account owns is changed, and only
/// to a model of that server; a new or temporary chat, someone else's chat,
/// and a Direct or Hermes model are left alone.
///
/// [ref] is a `Ref` or `WidgetRef`, read only before the first await.
/// Failures are logged and otherwise ignored: the pick still applies to what
/// is sent next.
Future<void> saveChatModelChoice(dynamic ref, Model model) async {
  final conversation = ref.read(activeConversationProvider);
  if (conversation == null ||
      isTemporaryChat(conversation.id) ||
      !conversationUsesOpenWebUiStorage(conversation)) {
    return;
  }
  if (isLocallyMintedDirectModel(model) || isHermesModel(model)) return;
  final String? userId = ref.read(currentUserProvider2)?.id;
  final String? owner = conversation.userId;
  if (owner != null && userId != null && owner != userId) return;
  final String chatId = conversation.id;
  final models = <String>[model.id];

  // Regenerating an answer of a turn sent before now uses this model.
  final List<ChatMessage> messages = ref.read(chatMessagesProvider);
  ref
      .read(chatModelPickProvider.notifier)
      .record(
        chatId: chatId,
        modelId: model.id,
        afterMessageId: messages.isEmpty ? null : messages.last.id,
      );

  // The queue outlives [ref], which may belong to a sheet closing now.
  return ref.read(chatModelSaveQueueProvider.notifier).save(chatId, models);
}

/// Saves chats' model lists, one save at a time.
///
/// Only the newest list asked for each chat is saved, so an earlier pick can
/// never land after a later one. The list is stored with the local chat at
/// once. It is sent to the server once no reply is streaming in the chat: a
/// server before 0.12 merges the change by rewriting the whole chat without
/// a lock, which could overwrite the reply. After the server takes it, the
/// list is stored again, since a pull read before the pick may have put the
/// old one back, and the server's copy keeps its date, so no later pull
/// would correct it. A list belongs to the account that picked it: once
/// another account is signed in, or the same one again, it is neither sent
/// nor stored.
final chatModelSaveQueueProvider = NotifierProvider<ChatModelSaveQueue, void>(
  ChatModelSaveQueue.new,
);

class ChatModelSaveQueue extends Notifier<void> {
  final Map<String, ({List<String> models, Object account})> _pending =
      <String, ({List<String> models, Object account})>{};
  Future<void>? _running;

  @override
  void build() {}

  /// The account signed in now. Read, not watched: this queue is only ever
  /// read, so it would not rebuild while a save is under way.
  Object _account() => (
    ref.read(currentUserProvider2)?.id,
    ref.read(openWebUiAuthSessionEpochProvider),
  );

  /// Saves [models] as chat [chatId]'s list; completes once the queue has
  /// nothing left to send.
  Future<void> save(String chatId, List<String> models) {
    _pending[chatId] = (models: models, account: _account());
    unawaited(_store(chatId, models));
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _store(String chatId, List<String> models) async {
    final db = ref.read(appDatabaseProvider);
    if (db == null) return;
    try {
      await ref
          .read(chatLocksProvider)
          .runExclusive(
            chatId,
            () => db.chatsDao.setChatModels(chatId, models),
          );
    } catch (error) {
      _logFailure(chatId, error);
    }
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final chatId = _pending.keys.first;
      final (:models, :account) = _pending[chatId]!;
      if (account != _account()) {
        _pending.remove(chatId);
        continue;
      }
      if (_streamingIn(chatId)) {
        await _untilNotStreamingIn(chatId);
        if (!ref.mounted) return;
        continue; // A newer list may have come in meanwhile.
      }
      _pending.remove(chatId);
      final api = ref.read(apiServiceProvider);
      if (api == null) continue;
      try {
        await api.updateConversation(chatId, models: models);
      } catch (error) {
        _logFailure(chatId, error);
        continue;
      }
      // A newer list for the chat is stored and sent in its own turn.
      if (ref.mounted &&
          account == _account() &&
          !_pending.containsKey(chatId)) {
        await _store(chatId, models);
      }
    }
  }

  bool _streamingIn(String chatId) =>
      ref.read(activeConversationProvider)?.id == chatId &&
      ref.read(isChatStreamingProvider);

  /// Waits until no reply streams in chat [chatId]. The streaming state is
  /// read again every moment: this queue is only ever read, and Riverpod
  /// pauses the listeners of a provider nothing listens to.
  Future<void> _untilNotStreamingIn(String chatId) async {
    while (ref.mounted && _streamingIn(chatId)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _logFailure(String chatId, Object error) {
    DebugLogger.warning(
      'chat-model-choice-not-saved',
      scope: 'chat/model',
      data: {'chatId': chatId, 'error': error.runtimeType.toString()},
    );
  }
}
