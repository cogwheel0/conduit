import 'package:flutter/foundation.dart';

import '../../../core/database/chat_database_repository.dart';
import '../../../core/database/mappers/conversation_assembler.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';

typedef AuthoritativeConversationLoader =
    Future<Conversation> Function(Conversation conversation);

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
    AuthoritativeConversationLoader? authoritativeLoader,
  }) : _repository = repository,
       _offload = offload,
       _authoritativeLoader = authoritativeLoader;

  final ChatDatabaseRepository _repository;
  final ConversationParseOffload _offload;
  final AuthoritativeConversationLoader? _authoritativeLoader;

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

    final List<ChatMessage> durable;
    ChatStorageKind? resolvedStorage = located?.location.storage ?? storage;
    if (located != null) {
      durable = located.conversation.messages;
    } else if (storage == null) {
      // Temporary and otherwise non-durable chats own a private complete
      // in-memory ledger. They are the only conversations for which the active
      // model is canonical.
      durable = conversation.messages;
    } else {
      // A durable row can exist before its body is materialized. Falling back
      // to the active model here would reinterpret the 50-row presentation
      // window as complete history and could truncate persistence/export.
      final loader = _authoritativeLoader;
      if (loader == null) {
        throw StateError(
          'Durable conversation history is not materialized and no '
          'authoritative loader is available.',
        );
      }
      if (!ownerIsCurrent()) {
        throw StateError('Conversation owner changed while reading history.');
      }
      final authoritative = await loader(conversation);
      if (!ownerIsCurrent() || authoritative.id != conversation.id) {
        throw StateError('Conversation owner changed while reading history.');
      }
      durable = authoritative.messages;
      resolvedStorage = chatStorageFromConversation(authoritative) ?? storage;
    }
    final merged = _mergeOverlay(durable, visibleOverlay);
    return CompleteChatHistory(
      conversation: conversation.copyWith(messages: merged),
      messages: merged,
      storage: resolvedStorage,
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
