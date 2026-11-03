import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider, isChatStreamingProvider;
import 'package:conduit_core/services/api_service.dart';
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
  @override
  ChatModelPick? build() => null;

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
/// since. Conduit does the same: the list is stored with the local chat and
/// sent as the chat's only changed key, which every supported server merges
/// without touching the chat's date. Only a saved Open WebUI chat this account
/// owns is changed, and only to a model of that server; a new or temporary
/// chat, someone else's chat, and a Direct or Hermes model are left alone.
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

  // Everything is read now: [ref] may belong to a sheet that closes while
  // the chat lock is awaited.
  final AppDatabase? db = ref.read(appDatabaseProvider);
  final ChatLocks locks = ref.read(chatLocksProvider);
  final ApiService? api = ref.read(apiServiceProvider);
  // A server before 0.12 rewrites the whole chat to merge the change, without
  // a lock, so a reply streaming meanwhile could be overwritten. The list is
  // stored here, and the chat's next sync carries it.
  final bool streaming = ref.read(isChatStreamingProvider);

  Future<void> store() async {
    if (db == null) return;
    await locks.runExclusive(
      chatId,
      () => db.chatsDao.setChatModels(chatId, models),
    );
  }

  try {
    await store();
    if (api == null || streaming) return;
    await api.updateConversation(chatId, models: models);
    // A pull read before the pick, and written since, may have put the old
    // list back; the server's copy keeps its date, so no later pull would.
    await store();
  } catch (error) {
    DebugLogger.warning(
      'chat-model-choice-not-saved',
      scope: 'chat/model',
      data: {'chatId': chatId, 'error': error.runtimeType.toString()},
    );
  }
}
