part of 'chat_providers.dart';

// Chat messages for current conversation
final chatMessagesProvider =
    NotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );

class ChatTranscriptPagingNotifier extends Notifier<ChatTranscriptPagingState> {
  @override
  ChatTranscriptPagingState build() => const ChatTranscriptPagingState();

  void reset({required int totalMessages}) {
    final loaded = math.min(kChatTranscriptPageSize, totalMessages);
    state = ChatTranscriptPagingState(
      hasOlder: totalMessages > loaded,
      loadedCount: loaded,
      generation: state.generation + 1,
    );
  }

  Future<bool> fetchOlder({required int totalMessages}) async {
    if (state.isLoadingOlder || !state.hasOlder) return false;
    state = state.copyWith(isLoadingOlder: true, clearError: true);
    try {
      final loaded = math.min(
        totalMessages,
        state.loadedCount + kChatTranscriptPageSize,
      );
      state = state.copyWith(
        isLoadingOlder: false,
        loadedCount: loaded,
        hasOlder: loaded < totalMessages,
        clearError: true,
      );
      return true;
    } catch (error) {
      state = state.copyWith(isLoadingOlder: false, error: error);
      return false;
    }
  }

  void ensureTotal(int totalMessages) {
    final loaded = math.min(state.loadedCount, totalMessages);
    final normalized = totalMessages == 0
        ? 0
        : math.max(math.min(kChatTranscriptPageSize, totalMessages), loaded);
    if (normalized == state.loadedCount &&
        state.hasOlder == (normalized < totalMessages)) {
      return;
    }
    state = state.copyWith(
      loadedCount: normalized,
      hasOlder: normalized < totalMessages,
    );
  }

  void restoreLoadedCount({
    required int totalMessages,
    required int loadedCount,
  }) {
    final normalized = math.min(
      totalMessages,
      math.max(kChatTranscriptPageSize, loadedCount),
    );
    state = ChatTranscriptPagingState(
      hasOlder: normalized < totalMessages,
      loadedCount: normalized,
      generation: state.generation + 1,
    );
  }
}

final chatTranscriptPagingProvider =
    NotifierProvider<ChatTranscriptPagingNotifier, ChatTranscriptPagingState>(
      ChatTranscriptPagingNotifier.new,
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
