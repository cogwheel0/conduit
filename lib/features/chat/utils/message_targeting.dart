import '../../../core/models/chat_message.dart';

typedef AssistantRegenerationTarget = ({
  int assistantIndex,
  ChatMessage assistantMessage,
  ChatMessage userMessage,
});

int indexOfMessageId(List<ChatMessage> messages, String messageId) {
  return messages.indexWhere((message) => message.id == messageId);
}

AssistantRegenerationTarget? resolveAssistantRegenerationTarget(
  List<ChatMessage> messages,
  String assistantMessageId,
) {
  final assistantIndex = indexOfMessageId(messages, assistantMessageId);
  if (assistantIndex <= 0) {
    return null;
  }

  final assistantMessage = messages[assistantIndex];
  if (assistantMessage.role != 'assistant') {
    return null;
  }

  for (var index = assistantIndex - 1; index >= 0; index--) {
    final candidate = messages[index];
    if (candidate.role == 'user') {
      return (
        assistantIndex: assistantIndex,
        assistantMessage: assistantMessage,
        userMessage: candidate,
      );
    }
  }

  return null;
}

List<ChatMessage> truncateMessagesAfterId(
  List<ChatMessage> messages,
  String messageId, {
  required bool includeTarget,
}) {
  final targetIndex = indexOfMessageId(messages, messageId);
  if (targetIndex == -1) {
    return List<ChatMessage>.from(messages, growable: false);
  }

  final end = includeTarget ? targetIndex + 1 : targetIndex;
  return List<ChatMessage>.from(messages.take(end), growable: false);
}
