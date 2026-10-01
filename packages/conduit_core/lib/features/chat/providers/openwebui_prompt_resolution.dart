// Answering an Open WebUI tool prompt persisted on a message (ask-user,
// tool approval, confirmation): the server resolves the tool call, then the
// chat resumes the paused turn.
import 'package:conduit_core/features/chat/composer/openwebui_prompt_answers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';

/// The Open WebUI action for a decision on [prompt]: an ask-user prompt's
/// Cancel rejects; an approval or confirmation approves or rejects.
OpenWebUiToolCallAction openWebUiDecisionAction(
  OpenWebUiComposerPrompt prompt,
  bool approved,
) {
  if (prompt.kind == OpenWebUiComposerPromptKind.askUser) {
    return OpenWebUiToolCallAction.reject;
  }
  return approved
      ? OpenWebUiToolCallAction.approve
      : OpenWebUiToolCallAction.reject;
}

/// Resolves [pending] on the server with [action] (and [answers] for an
/// ask-user prompt), then resumes the turn, if the chat that owns it is
/// still on screen with the same API client and session.
///
/// Throws when the chat cannot take the answer (no Open WebUI storage, a
/// temporary chat, another chat loaded): the overlay shows its error.
/// [isMounted] is the caller's liveness check after the server call.
Future<void> resolvePersistedOpenWebUiPrompt(
  dynamic ref, {
  required String ownerConversationId,
  required OpenWebUiPendingToolPrompt pending,
  required OpenWebUiToolCallAction action,
  Map<String, dynamic>? answers,
  bool Function()? isMounted,
}) async {
  // Typed: `ref` is dynamic.
  final ApiService? api = ref.read(apiServiceProvider);
  final Conversation? conversation = ref.read(activeConversationProvider);
  if (api == null ||
      conversation == null ||
      !canUsePersistedOpenWebUiPrompt(
        isLoadingConversation: ref.read(isLoadingConversationProvider),
        ownerConversationId: ownerConversationId,
        activeConversationId: conversation.id,
      ) ||
      !conversationUsesOpenWebUiStorage(conversation) ||
      isTemporaryChat(conversation.id)) {
    throw StateError('Open WebUI chat is unavailable.');
  }
  final authEpoch = ref.read(openWebUiAuthSessionEpochProvider);
  final taskIds = await api.resolveChatMessageToolCall(
    chatId: ownerConversationId,
    messageId: pending.messageId,
    callId: pending.callId,
    action: action,
    answers: answers,
  );
  if (!(isMounted?.call() ?? true) ||
      !identical(api, ref.read(apiServiceProvider)) ||
      !identical(authEpoch, ref.read(openWebUiAuthSessionEpochProvider)) ||
      ref.read(activeConversationProvider)?.id != ownerConversationId) {
    return;
  }
  await ref
      .read(chatMessagesProvider.notifier)
      .resumeAfterOpenWebUiToolCall(
        messageId: pending.messageId,
        callId: pending.callId,
        action: action,
        taskIds: taskIds,
        answers: answers,
      );
}
