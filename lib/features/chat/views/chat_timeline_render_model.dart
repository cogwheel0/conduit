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
    required this.completedFooterHost,
    required this.historyIndexByMessageId,
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
    final footerHost = tailAssistant == null || tailAssistantSourceIndex == null
        ? null
        : ChatTurnFooterHost(
            message: tailAssistant,
            sourceIndex: tailAssistantSourceIndex,
            phase: tailAssistantPhase,
          );
    final historyIndexByMessageId = <String, int>{};
    final historyIndexByMessageKey = <String, int>{};

    for (var index = 0; index < historyMessages.length; index += 1) {
      final messageId = historyMessages[index].id;
      historyIndexByMessageId[messageId] = index;
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
      completedFooterHost: chatTurnPhaseShowsCompletedFooter(tailAssistantPhase)
          ? footerHost
          : null,
      historyIndexByMessageId: Map<String, int>.unmodifiable(
        historyIndexByMessageId,
      ),
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
  final ChatTurnFooterHost? completedFooterHost;
  final Map<String, int> historyIndexByMessageId;
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
  if (lastMessage.role == 'assistant') {
    return lastIndex;
  }
  return null;
}
