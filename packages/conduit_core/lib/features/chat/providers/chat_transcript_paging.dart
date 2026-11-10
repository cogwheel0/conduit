part of 'chat_providers.dart';

// Chat messages for current conversation
final chatMessagesProvider =
    NotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );

final chatHistoryReaderProvider = Provider<ChatHistoryReader>((ref) {
  return ChatHistoryReader(
    repository: ref.watch(chatDatabaseRepositoryProvider),
    authoritativeLoader: (conversation) => ref.read(
      loadConversationProvider(conversationScopedId(conversation)).future,
    ),
    offload: (envelope) => ref
        .read(workerManagerProvider)
        .schedule(
          parseFullConversationModelWorker,
          envelope,
          debugLabel: 'chat.historyReader',
        ),
  );
});

Future<CompleteChatHistory> readCompleteActiveChatHistory(dynamic ref) {
  final conversation = ref.read(activeConversationProvider);
  if (conversation == null) {
    throw StateError('No active conversation.');
  }
  final scopedId = conversationScopedId(conversation);
  return ref
      .read(chatHistoryReaderProvider)
      .readCompleteActiveBranch(
        conversation: conversation,
        visibleOverlay: ref.read(chatMessagesProvider),
        ownerIsCurrent: () {
          final current = ref.read(activeConversationProvider);
          return current != null && conversationScopedId(current) == scopedId;
        },
      );
}
