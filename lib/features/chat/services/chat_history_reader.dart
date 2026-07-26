import 'package:flutter/foundation.dart';

import '../../../core/database/chat_database_repository.dart';
import '../../../core/database/mappers/conversation_assembler.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';

@immutable
final class CompleteChatHistory {
  const CompleteChatHistory({
    required this.conversation,
    required this.messages,
    required this.storage,
  });

  final Conversation conversation;
  final List<ChatMessage> messages;
  final ChatStorageKind? storage;
}

/// Explicit full-history read boundary.
///
/// The active conversation may carry only a presentation window. Durable
/// operations call this service and merge the newest in-memory rows over the
/// database snapshot so a not-yet-flushed streaming tail is never lost.
final class ChatHistoryReader {
  const ChatHistoryReader({
    required ChatDatabaseRepository repository,
    required ConversationParseOffload offload,
  }) : _repository = repository,
       _offload = offload;

  final ChatDatabaseRepository _repository;
  final ConversationParseOffload _offload;

  Future<CompleteChatHistory> readCompleteActiveBranch({
    required Conversation conversation,
    required List<ChatMessage> visibleOverlay,
    required bool Function() ownerIsCurrent,
  }) async {
    final storage = chatStorageFromConversation(conversation);
    final located = await _repository.loadConversation(
      conversation.id,
      preferred: storage,
      offload: _offload,
      locationIsCurrent: (_) => ownerIsCurrent(),
    );
    if (!ownerIsCurrent()) {
      throw StateError('Conversation owner changed while reading history.');
    }

    final durable = located?.conversation.messages ?? conversation.messages;
    final merged = _mergeOverlay(durable, visibleOverlay);
    return CompleteChatHistory(
      conversation: conversation.copyWith(messages: merged),
      messages: merged,
      storage: located?.location.storage ?? storage,
    );
  }

  List<ChatMessage> _mergeOverlay(
    List<ChatMessage> durable,
    List<ChatMessage> overlay,
  ) {
    final overlayById = {for (final message in overlay) message.id: message};
    final seen = <String>{};
    final result = <ChatMessage>[
      for (final message in durable)
        if (seen.add(message.id)) overlayById[message.id] ?? message,
    ];
    for (final message in overlay) {
      if (seen.add(message.id)) result.add(message);
    }
    return List.unmodifiable(result);
  }
}
