// Generate Title for a saved Open WebUI chat, as the Generate button of Open
// WebUI 0.13's chat title does. The phone's chat menu and the desktop daemon
// call it; the rules live here, tested without Flutter.
import 'dart:async';

import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/services/chat_title_generation.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';

/// How [generateConversationTitle] ended, when it did not fail.
enum ConversationTitleOutcome {
  /// A new title was saved on the server.
  saved,

  /// The model wrote the title the chat already had.
  unchanged,

  /// The model wrote no title (or the chat has nothing to title).
  none,

  /// The chat was renamed while the model wrote one, and keeps that name.
  kept,
}

/// What [generateConversationTitle] did: the [outcome], the [title] the
/// model wrote (all but [ConversationTitleOutcome.none]), and whether the account that asked
/// is still the signed-in one ([current]), so the caller confirms it only
/// then.
typedef GeneratedConversationTitle = ({
  ConversationTitleOutcome outcome,
  String? title,
  bool current,
});

/// Asks the server for a title made from the Open WebUI chat
/// [conversationId] and saves it straight away.
///
/// Every request goes out as the account that asked, and the title is saved
/// only while the chat still has the title it had then: a rename made while
/// the model wrote one is kept. The model asked is [selectedModelId], or, when
/// that is null and [conversationId] is the open chat, the model picked there,
/// then the chat's own (see [chatTitleRequest]); only the server's own models
/// can title a chat. Throws when the request cannot be made or fails.
Future<GeneratedConversationTitle> generateConversationTitle(
  dynamic ref,
  String conversationId, {
  String? selectedModelId,
}) async {
  final rawConversationId = ChatStorageIdentity.parse(conversationId).rawId;
  final api = ref.read(apiServiceProvider);
  if (api == null) throw StateError('No API service');
  final authSnapshot = api.captureAuthSnapshot();
  var modelId = selectedModelId;
  if (modelId == null) {
    final active = ref.read(activeConversationProvider) as Conversation?;
    if (active != null && conversationMatchesScopedId(active, conversationId)) {
      modelId = (ref.read(selectedModelProvider) as Model?)?.id;
    }
  }
  // Only the server's own models can title a chat: not a Direct or Hermes
  // model, which turns of an Open WebUI chat may have used. The model list
  // leaves out models hidden from the picker, which are still the server's,
  // so only a model it lists as Direct or Hermes is passed over.
  final directModels = ref.read(directModelRegistryProvider);
  List<Model>? knownModels;
  try {
    knownModels = await (ref.read(modelsProvider.future) as Future<List<Model>>)
        .timeout(const Duration(seconds: 5));
  } catch (_) {}
  bool isServerModel(String id) {
    for (final model in knownModels ?? const <Model>[]) {
      if (model.id != id) continue;
      return !isHermesModel(model) && directModels.resolve(model) == null;
    }
    return true;
  }

  final chatJson = await api.getChatRaw(
    rawConversationId,
    authSnapshot: authSnapshot,
  );
  // A chat the server does not hold has nothing to title there.
  if (chatJson == null) throw StateError('Chat not found');
  final titleAsked = chatJson['title'];
  final request = chatTitleRequest(
    chatJson,
    selectedModelId: modelId,
    isServerModel: isServerModel,
  );
  final title = request == null
      ? null
      : (await api.generateChatTitle(
          model: request.model,
          messages: request.messages,
          authSnapshot: authSnapshot,
        ) as String?)?.trim();
  bool stillCurrent() => identical(ref.read(apiServiceProvider), api);
  if (title == null || title.isEmpty) {
    return (
      outcome: ConversationTitleOutcome.none,
      title: null,
      current: stillCurrent(),
    );
  }
  if (title == titleAsked) {
    return (
      outcome: ConversationTitleOutcome.unchanged,
      title: title,
      current: stillCurrent(),
    );
  }
  // Told apart from the title the server stored, not the chat list's copy,
  // which can lag it or show an empty title as "Chat".
  var saved = false;
  final database = ref.read(appDatabaseProvider);
  final ChatLocks titleLocks = ref.read(chatTitleLocksProvider);
  final ChatLocks chatLocks = ref.read(chatLocksProvider);
  await titleLocks.runExclusive(
    rawConversationId,
    // In the chat's own lock too: a full save of the chat sends the title it
    // read, so one under way finishes before this one is written, and one
    // after it reads the new title from the database.
    () => chatLocks.runExclusive(rawConversationId, () async {
      // Compared as the server stores it, as it was when the title was asked
      // for: a rename made meanwhile is kept.
      final stored = await api.getChatRaw(
        rawConversationId,
        authSnapshot: authSnapshot,
      );
      if (stored == null || stored['title'] != titleAsked) return;
      await api.updateConversation(
        rawConversationId,
        title: title,
        authSnapshot: authSnapshot,
      );
      saved = true;
      await database?.chatsDao.updateServerGeneratedTitle(
        rawConversationId,
        title,
      );
    }),
  );
  final current = stillCurrent();
  if (saved && current) {
    // Stored as a server-made title, so a later save of the chat does not
    // send the old one back.
    ref
        .read(conversationsProvider.notifier)
        .applyServerGeneratedTitle(rawConversationId, title);
    final open = ref.read(activeConversationProvider) as Conversation?;
    if (open != null && conversationMatchesScopedId(open, conversationId)) {
      ref
          .read(activeConversationProvider.notifier)
          .set(open.copyWith(title: title));
    }
  }
  return (
    outcome: saved
        ? ConversationTitleOutcome.saved
        : ConversationTitleOutcome.kept,
    title: title,
    current: current,
  );
}
