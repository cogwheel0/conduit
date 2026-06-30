import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';

enum ChatTurnPhase { none, running, completed, failed }

@immutable
class ChatTurnFooterHost {
  const ChatTurnFooterHost({
    required this.message,
    required this.sourceIndex,
    required this.phase,
  });

  final ChatMessage message;
  final int sourceIndex;
  final ChatTurnPhase phase;

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
  if (effectiveStreaming) {
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
