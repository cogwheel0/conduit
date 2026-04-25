import '../../../../core/models/chat_message.dart';

/// Outcome of matching an incoming transport event to the active assistant turn.
typedef AssistantTransportDecision = ({
  bool shouldProcess,
  bool boundRemoteAssistantMessage,
  String? activeAssistantMessageId,
  String? boundRemoteAssistantMessageId,
});

/// Assistant reply chosen during watchdog recovery.
typedef AssistantRecoveryCandidate = ({
  ChatMessage? message,
  bool authoritative,
});

/// Resolves whether a transport event belongs to the current assistant turn.
///
/// The voice-call controller starts with a local placeholder ID. Some backend
/// transports later rebind the response to a server-side message ID, so the
/// first foreign ID is accepted while the turn is still anchored to the local
/// placeholder.
AssistantTransportDecision resolveAssistantTransportDecision({
  required String? incomingMessageId,
  required String? activeAssistantMessageId,
  required String? localAssistantMessageId,
  required String? boundRemoteAssistantMessageId,
  required bool assistantResponseFinalized,
  required Set<String> ignoredAssistantMessageIds,
}) {
  final normalizedIncoming = _normalizeId(incomingMessageId);
  final normalizedActive = _normalizeId(activeAssistantMessageId);
  final normalizedLocal = _normalizeId(localAssistantMessageId);
  final normalizedRemote = _normalizeId(boundRemoteAssistantMessageId);

  if (assistantResponseFinalized) {
    return (
      shouldProcess: false,
      boundRemoteAssistantMessage: false,
      activeAssistantMessageId: normalizedActive,
      boundRemoteAssistantMessageId: normalizedRemote,
    );
  }

  if (normalizedIncoming == null) {
    final hasLiveTurnAnchor =
        _isLiveAssistantTurnId(
          normalizedActive,
          ignoredAssistantMessageIds: ignoredAssistantMessageIds,
        ) ||
        _isLiveAssistantTurnId(
          normalizedLocal,
          ignoredAssistantMessageIds: ignoredAssistantMessageIds,
        ) ||
        _isLiveAssistantTurnId(
          normalizedRemote,
          ignoredAssistantMessageIds: ignoredAssistantMessageIds,
        );
    return (
      shouldProcess: hasLiveTurnAnchor,
      boundRemoteAssistantMessage: false,
      activeAssistantMessageId: normalizedActive,
      boundRemoteAssistantMessageId: normalizedRemote,
    );
  }

  if (ignoredAssistantMessageIds.contains(normalizedIncoming)) {
    return (
      shouldProcess: false,
      boundRemoteAssistantMessage: false,
      activeAssistantMessageId: activeAssistantMessageId,
      boundRemoteAssistantMessageId: boundRemoteAssistantMessageId,
    );
  }

  if (normalizedActive == null) {
    return (
      shouldProcess: true,
      boundRemoteAssistantMessage: false,
      activeAssistantMessageId: normalizedIncoming,
      boundRemoteAssistantMessageId: normalizedRemote,
    );
  }

  if (normalizedIncoming == normalizedActive ||
      normalizedIncoming == normalizedLocal ||
      normalizedIncoming == normalizedRemote) {
    return (
      shouldProcess: true,
      boundRemoteAssistantMessage: false,
      activeAssistantMessageId: normalizedActive,
      boundRemoteAssistantMessageId: normalizedRemote,
    );
  }

  final canBindRemoteMessage =
      normalizedRemote == null &&
      normalizedLocal != null &&
      normalizedActive == normalizedLocal;

  if (canBindRemoteMessage) {
    return (
      shouldProcess: true,
      boundRemoteAssistantMessage: true,
      activeAssistantMessageId: normalizedIncoming,
      boundRemoteAssistantMessageId: normalizedIncoming,
    );
  }

  return (
    shouldProcess: false,
    boundRemoteAssistantMessage: false,
    activeAssistantMessageId: normalizedActive,
    boundRemoteAssistantMessageId: normalizedRemote,
  );
}

/// Resolves the best assistant message for the active voice-call turn.
///
/// Preference order:
/// 1. exact non-empty assistant message ID match,
/// 2. assistant reply whose parent is the current user turn,
/// 3. assistant reply created after the turn began,
/// 4. latest non-empty assistant when no active turn is known.
ChatMessage? resolveAssistantMessageForTurn({
  required Iterable<ChatMessage> messages,
  required String? activeAssistantMessageId,
  required String? activeUserMessageId,
  required DateTime? assistantTurnStartedAt,
}) {
  final orderedMessages = messages.toList(growable: false);
  final normalizedAssistantId = _normalizeId(activeAssistantMessageId);
  if (normalizedAssistantId != null) {
    for (final message in orderedMessages.reversed) {
      if (message.role == 'assistant' && message.id == normalizedAssistantId) {
        if (message.content.trim().isNotEmpty) {
          return message;
        }
        break;
      }
    }
  }

  final normalizedUserId = _normalizeId(activeUserMessageId);
  if (normalizedUserId != null) {
    for (final message in orderedMessages.reversed) {
      if (message.role != 'assistant' || message.content.trim().isEmpty) {
        continue;
      }
      if (_normalizeId(message.metadata?['parentId']?.toString()) ==
          normalizedUserId) {
        return message;
      }
    }
  }

  if (assistantTurnStartedAt != null) {
    for (final message in orderedMessages.reversed) {
      if (message.role != 'assistant' || message.content.trim().isEmpty) {
        continue;
      }
      if (!message.timestamp.isBefore(assistantTurnStartedAt)) {
        return message;
      }
    }
  }

  if (normalizedAssistantId == null && normalizedUserId == null) {
    for (final message in orderedMessages.reversed) {
      if (message.role == 'assistant' && message.content.trim().isNotEmpty) {
        return message;
      }
    }
  }

  return null;
}

/// Resolves the best assistant reply to recover during watchdog polling.
///
/// Remote conversation history is authoritative when available, because local
/// chat state can still be anchored to a placeholder assistant ID while the
/// backend has already rebound the turn to a server-side message.
AssistantRecoveryCandidate resolveAssistantRecoveryCandidate({
  required Iterable<ChatMessage> localMessages,
  required Iterable<ChatMessage>? remoteMessages,
  required String? activeAssistantMessageId,
  required String? activeUserMessageId,
  required DateTime? assistantTurnStartedAt,
}) {
  if (remoteMessages != null) {
    final remoteAssistant = resolveAssistantMessageForTurn(
      messages: remoteMessages,
      activeAssistantMessageId: activeAssistantMessageId,
      activeUserMessageId: activeUserMessageId,
      assistantTurnStartedAt: assistantTurnStartedAt,
    );
    if (remoteAssistant != null) {
      return (message: remoteAssistant, authoritative: true);
    }
  }

  return (
    message: resolveAssistantMessageForTurn(
      messages: localMessages,
      activeAssistantMessageId: activeAssistantMessageId,
      activeUserMessageId: activeUserMessageId,
      assistantTurnStartedAt: assistantTurnStartedAt,
    ),
    authoritative: false,
  );
}

/// Returns whether the assistant has been inactive for at least [patience].
///
/// When no assistant activity has been observed yet, the turn start time acts
/// as the fallback baseline so completely silent turns can still time out.
bool hasExceededAssistantWaitBudget({
  required DateTime? assistantTurnStartedAt,
  required DateTime? lastAssistantActivityAt,
  required DateTime now,
  required Duration patience,
}) {
  final baseline = lastAssistantActivityAt ?? assistantTurnStartedAt;
  if (baseline == null) {
    return false;
  }
  return now.difference(baseline) >= patience;
}

String? _normalizeId(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

bool _isLiveAssistantTurnId(
  String? candidate, {
  required Set<String> ignoredAssistantMessageIds,
}) {
  return candidate != null && !ignoredAssistantMessageIds.contains(candidate);
}
