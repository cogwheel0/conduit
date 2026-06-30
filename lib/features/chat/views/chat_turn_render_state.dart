import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';

enum ChatTurnPhase { none, running, completed, failed }

@immutable
class ChatTurnFooterHost {
  const ChatTurnFooterHost({required this.message});

  final ChatMessage message;

  String get messageId => message.id;
}

ChatTurnPhase chatTurnPhaseForMessage(
  ChatMessage? message, {
  bool? isStreaming,
}) {
  if (message == null || message.role != 'assistant') {
    return ChatTurnPhase.none;
  }
  if (message.error != null) {
    return ChatTurnPhase.failed;
  }
  final effectiveStreaming = isStreaming ?? message.isStreaming;
  // `responseDone` is a settled UI state: the response is finalized even though
  // the transport `isStreaming` flag may not have flipped yet (the "responseDone
  // gap"). Treat it as completed so the typing footer hides and the action row
  // appears without waiting for the trailing `done` event.
  if (effectiveStreaming && message.metadata?['responseDone'] != true) {
    return ChatTurnPhase.running;
  }
  return ChatTurnPhase.completed;
}

bool chatTurnPhaseShowsRunningFooter(ChatTurnPhase phase) {
  return phase == ChatTurnPhase.running;
}

bool chatTurnPhaseShowsCompletedFooter(ChatTurnPhase phase) {
  return phase == ChatTurnPhase.completed || phase == ChatTurnPhase.failed;
}
