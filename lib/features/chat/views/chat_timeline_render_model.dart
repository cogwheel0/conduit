import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';
import 'chat_turn_render_state.dart';

@immutable
class ChatTimelineRenderModel {
  const ChatTimelineRenderModel._({
    required this.historyMessages,
    required this.tailAssistant,
    required this.tailAssistantSourceIndex,
    required this.tailAssistantPhase,
    required this.runningFooterHost,
    required this.historyIndexByMessageKey,
  });

  factory ChatTimelineRenderModel.fromMessages(List<ChatMessage> messages) {
    final tailAssistantSourceIndex = _tailAssistantIndex(messages);
    final historyLength = tailAssistantSourceIndex ?? messages.length;
    final historyMessages = List<ChatMessage>.unmodifiable(
      messages.take(historyLength),
    );
    final tailAssistant = tailAssistantSourceIndex == null
        ? null
        : messages[tailAssistantSourceIndex];
    final tailAssistantPhase = chatTurnPhaseForMessage(tailAssistant);
    final footerHost = tailAssistant == null
        ? null
        : ChatTurnFooterHost(message: tailAssistant);
    final historyIndexByMessageKey = <String, int>{};

    for (var index = 0; index < historyMessages.length; index += 1) {
      final messageId = historyMessages[index].id;
      historyIndexByMessageKey['message-$messageId'] = index;
    }

    return ChatTimelineRenderModel._(
      historyMessages: historyMessages,
      tailAssistant: tailAssistant,
      tailAssistantSourceIndex: tailAssistantSourceIndex,
      tailAssistantPhase: tailAssistantPhase,
      runningFooterHost: chatTurnPhaseShowsRunningFooter(tailAssistantPhase)
          ? footerHost
          : null,
      historyIndexByMessageKey: Map<String, int>.unmodifiable(
        historyIndexByMessageKey,
      ),
    );
  }

  final List<ChatMessage> historyMessages;
  final ChatMessage? tailAssistant;
  final int? tailAssistantSourceIndex;
  final ChatTurnPhase tailAssistantPhase;
  final ChatTurnFooterHost? runningFooterHost;
  final Map<String, int> historyIndexByMessageKey;

  bool get hasTailAssistant => tailAssistant != null;
  bool get hasRunningTurn => runningFooterHost != null;
}

int? _tailAssistantIndex(List<ChatMessage> messages) {
  if (messages.isEmpty) {
    return null;
  }
  final lastIndex = messages.length - 1;
  final lastMessage = messages[lastIndex];
  // Archived variants are hidden by the history sliver. Excluding them here
  // keeps the single source of truth in the history path and prevents a stale
  // archived assistant from briefly rendering as the live tail (e.g. on the
  // intermediate regeneration frame before the new assistant is appended).
  if (lastMessage.role == 'assistant' &&
      lastMessage.metadata?['archivedVariant'] != true) {
    return lastIndex;
  }
  return null;
}
