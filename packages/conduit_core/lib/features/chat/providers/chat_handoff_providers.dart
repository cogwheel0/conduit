import 'dart:collection';
import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/chat_handoff.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// Asks the user whether to carry on in a new chat with the model named
/// [modelName]. Resolves false when declined or when nobody can be asked.
typedef ChatHandoffPrompt = Future<bool> Function(String modelName);

/// Asked before a server's `chat:handoff` opens a new chat. The core cannot
/// localize the question, so the host binds it; without one, every handoff
/// is refused as unsupported, since nobody could agree to it.
final chatHandoffPromptProvider = Provider<ChatHandoffPrompt?>((ref) => null);

/// Answers the `chat:handoff` events of the signed-in account's socket. Kept
/// alive so a repeat is still recognised after the socket is replaced.
final chatHandoffCoordinatorProvider = Provider<ChatHandoffCoordinator>(
  (ref) => ChatHandoffCoordinator(
    isActiveChat: (chatId) =>
        activeOpenWebUiChatIdForMutation(
          ref,
          captureOpenWebUiCompletionOwner(ref, chatId: chatId),
        ) !=
        null,
    findModel: (modelId) => openWebUiHandoffModel(
      ref.read(modelsProvider).value ?? const <Model>[],
      modelId,
    ),
    confirm: ref.watch(chatHandoffPromptProvider),
    open: (model, prompt) => openChatHandoff(ref, model, prompt),
  ),
);

/// The model a handoff to [modelId] may open: one of the account's Open WebUI
/// models, hidden ones included as in the browser client, but never a Direct
/// or Hermes model, which belong to this device rather than the server.
Model? openWebUiHandoffModel(Iterable<Model> models, String modelId) {
  for (final model in models) {
    if (model.id == modelId &&
        !isLocallyMintedDirectModel(model) &&
        !isHermesModel(model)) {
      return model;
    }
  }
  return null;
}

/// Opens a new chat on [model] with [prompt] in the composer, unsent.
void openChatHandoff(dynamic ref, Model model, String prompt) {
  startNewChat(ref, modelForNewConversation: model);
  if (prompt.isNotEmpty) {
    ref.read(prefilledInputTextProvider.notifier).set(prompt);
  }
}

/// Decides what a server's `chat:handoff` may do, which is never more than
/// this: once the user agrees, open a new chat on one of their own models
/// with the suggested prompt in the composer. It never sends a message, runs
/// code, or changes a chat on the server.
class ChatHandoffCoordinator {
  ChatHandoffCoordinator({
    required bool Function(String chatId) isActiveChat,
    required Model? Function(String modelId) findModel,
    required ChatHandoffPrompt? confirm,
    required void Function(Model model, String prompt) open,
  }) : _isActiveChat = isActiveChat,
       _findModel = findModel,
       _confirm = confirm,
       _open = open;

  /// Handoffs remembered to refuse a repeat, oldest dropped first.
  static const int maxRememberedHandoffs = 32;

  final bool Function(String chatId) _isActiveChat;
  final Model? Function(String modelId) _findModel;
  final ChatHandoffPrompt? _confirm;
  final void Function(Model model, String prompt) _open;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  bool _asking = false;

  /// Returns the reply to a `chat:handoff` event that arrived for [chatId]
  /// and [messageId] carrying [data].
  Future<Map<String, dynamic>> handle({
    required String? chatId,
    required String? messageId,
    required Object? data,
  }) async {
    final confirm = _confirm;
    if (confirm == null) return ChatHandoffRefusal.unsupported.reply;
    final request = ChatHandoffRequest.tryParse(data);
    if (request == null) return ChatHandoffRefusal.invalid.reply;
    final key = jsonEncode([
      chatId,
      messageId,
      request.modelId,
      request.prompt,
    ]);
    if (_seen.contains(key)) return ChatHandoffRefusal.duplicate.reply;
    if (chatId == null || chatId.isEmpty || !_isActiveChat(chatId)) {
      return ChatHandoffRefusal.notActiveChat.reply;
    }
    if (_asking) return ChatHandoffRefusal.busy.reply;
    _seen.add(key);
    if (_seen.length > maxRememberedHandoffs) _seen.remove(_seen.first);

    final model = _findModel(request.modelId);
    if (model == null) return ChatHandoffRefusal.modelUnavailable.reply;
    _asking = true;
    try {
      final name = model.name.isEmpty ? model.id : model.name;
      if (!await confirm(name)) return ChatHandoffRefusal.declined.reply;
    } finally {
      _asking = false;
    }
    _open(model, request.prompt);
    return chatHandoffHandledReply;
  }
}
