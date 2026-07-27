import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/utils/debug_logger.dart';
import 'chat_turn_render_state.dart';

@immutable
class ChatTimelineRenderModel {
  static const int _maxReportedDuplicateMessageIds = 256;
  static final LinkedHashSet<({String scope, String messageId})>
  _reportedDuplicateMessageIds =
      LinkedHashSet<({String scope, String messageId})>();

  @visibleForTesting
  static void debugResetDuplicateReportCache() {
    _reportedDuplicateMessageIds.clear();
  }

  const ChatTimelineRenderModel._({
    required this.historyMessages,
    required this.tailAssistant,
    required this.tailAssistantSourceIndex,
    required this.tailAssistantPhase,
    required this.runningFooterHost,
    required this.listIndexByMessageId,
    required this.messageIds,
    required this.sourceIndexByRenderIndex,
  });

  factory ChatTimelineRenderModel.fromMessages(
    List<ChatMessage> messages, {
    String duplicateReportScope = 'unscoped',
  }) {
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
        : ChatTurnFooterHost(messageId: tailAssistant.id);
    final listIndexByMessageId = <String, int>{};
    final messageIds = <String>[];
    final sourceIndexByRenderIndex = <int>[];
    var duplicateCount = 0;
    final duplicateMessageIds = <String>{};

    for (var index = 0; index < historyMessages.length; index += 1) {
      final messageId = historyMessages[index].id;
      if (listIndexByMessageId.containsKey(messageId)) {
        duplicateCount += 1;
        duplicateMessageIds.add(messageId);
        continue;
      }
      listIndexByMessageId[messageId] = messageIds.length;
      messageIds.add(messageId);
      sourceIndexByRenderIndex.add(index);
    }
    if (tailAssistant != null &&
        !listIndexByMessageId.containsKey(tailAssistant.id)) {
      listIndexByMessageId[tailAssistant.id] = messageIds.length;
      messageIds.add(tailAssistant.id);
      sourceIndexByRenderIndex.add(historyLength);
    } else if (tailAssistant != null) {
      duplicateCount += 1;
      duplicateMessageIds.add(tailAssistant.id);
    }
    if (duplicateCount > 0) {
      final newlyObservedIds = <String>[];
      for (final messageId in duplicateMessageIds) {
        final reportKey = (
          scope: duplicateReportScope,
          messageId: messageId,
        );
        if (_reportedDuplicateMessageIds.remove(reportKey)) {
          _reportedDuplicateMessageIds.add(reportKey);
          continue;
        }
        _reportedDuplicateMessageIds.add(reportKey);
        newlyObservedIds.add(messageId);
      }
      while (_reportedDuplicateMessageIds.length >
          _maxReportedDuplicateMessageIds) {
        _reportedDuplicateMessageIds.remove(_reportedDuplicateMessageIds.first);
      }
      if (newlyObservedIds.isNotEmpty) {
        DebugLogger.log(
          'timeline-duplicate-message-ids',
          scope: 'chat/layout',
          data: {
            'duplicateCount': duplicateCount,
            'messageIds': newlyObservedIds,
          },
        );
      }
    }

    return ChatTimelineRenderModel._(
      historyMessages: historyMessages,
      tailAssistant: tailAssistant,
      tailAssistantSourceIndex: tailAssistantSourceIndex,
      tailAssistantPhase: tailAssistantPhase,
      runningFooterHost: chatTurnPhaseShowsRunningFooter(tailAssistantPhase)
          ? footerHost
          : null,
      listIndexByMessageId: Map<String, int>.unmodifiable(listIndexByMessageId),
      messageIds: List<String>.unmodifiable(messageIds),
      sourceIndexByRenderIndex: List<int>.unmodifiable(
        sourceIndexByRenderIndex,
      ),
    );
  }

  final List<ChatMessage> historyMessages;
  final ChatMessage? tailAssistant;
  final int? tailAssistantSourceIndex;
  final ChatTurnPhase tailAssistantPhase;
  final ChatTurnFooterHost? runningFooterHost;

  /// Stable chronological indices for every rendered timeline row.
  ///
  /// The live assistant remains outside [historyMessages] so streamed chunks
  /// do not rebuild stable history, but it occupies the next list slot.
  final Map<String, int> listIndexByMessageId;

  /// Unique source message IDs in stable chronological order.
  ///
  /// Malformed duplicate IDs retain their first render row in
  /// [listIndexByMessageId]. [historyMessages] remains complete for explicit
  /// source-index access, while the live assistant is appended only when its
  /// ID is not already present.
  final List<String> messageIds;

  /// Original message-list index for each row in [messageIds].
  final List<int> sourceIndexByRenderIndex;

  bool get hasTailAssistant => tailAssistant != null;
  bool get hasRunningTurn => runningFooterHost != null;
  int get listItemCount => messageIds.length;

  /// Physical index in the deduplicated viewport, not the original source.
  /// Use [sourceIndexAtRenderIndex] when resolving layout metadata.
  int? get tailAssistantRenderIndex {
    final tail = tailAssistant;
    if (tail == null) {
      return null;
    }
    final renderIndex = listIndexByMessageId[tail.id];
    if (renderIndex == null ||
        sourceIndexAtRenderIndex(renderIndex) != tailAssistantSourceIndex) {
      return null;
    }
    return renderIndex;
  }

  ChatMessage? messageAtListIndex(int listIndex) {
    if (listIndex < 0 || listIndex >= listItemCount) return null;
    final sourceIndex = sourceIndexByRenderIndex[listIndex];
    if (sourceIndex == tailAssistantSourceIndex) {
      return tailAssistant;
    }
    return historyMessages[sourceIndex];
  }

  int? sourceIndexAtRenderIndex(int renderIndex) {
    if (renderIndex < 0 || renderIndex >= sourceIndexByRenderIndex.length) {
      return null;
    }
    return sourceIndexByRenderIndex[renderIndex];
  }

  int? indexForMessageId(String messageId) => listIndexByMessageId[messageId];
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
