// Saving a temporary chat to Open WebUI: the local-only transcript becomes a
// server conversation and the chat leaves temporary mode. The chat page
// calls it; the rules are tested here without Flutter.
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// What [saveTemporaryChat] did.
enum TemporaryChatSaveOutcome {
  /// The chat is now a server conversation.
  saved,

  /// Nothing to do, or the chat on screen changed while saving.
  skipped,

  /// The server refused or the transcript could not be read.
  failed,
}

/// The saved chat's title: the first user message, cut at 50 characters,
/// or "New Chat" for an empty one.
String temporaryChatTitle(List<ChatMessage> messages) {
  if (messages.isEmpty) return 'New Chat';
  final first = messages.firstWhere(
    (message) => message.role == 'user',
    orElse: () => messages.first,
  );
  final content = first.content;
  if (content.isEmpty) return 'New Chat';
  return content.length > 50 ? '${content.substring(0, 50)}...' : content;
}

/// Saves the active temporary chat to the server and switches the chat to
/// it. [isCurrentOwner] is the page's check that the chat it started saving
/// is still the one on screen (the Flutter page's conversation generation).
///
/// The save is dropped ([TemporaryChatSaveOutcome.skipped]) if the chat,
/// the API client or the Open WebUI session changes on the way.
Future<TemporaryChatSaveOutcome> saveTemporaryChat(
  dynamic ref, {
  bool Function()? isCurrentOwner,
}) async {
  if (ref.read(isChatStreamingProvider) == true) {
    return TemporaryChatSaveOutcome.skipped;
  }
  // Typed: `ref` is dynamic, and an untyped Conversation would take
  // `const []` below as a List<dynamic>.
  final Conversation? source = ref.read(activeConversationProvider);
  final ApiService? api = ref.read(apiServiceProvider);
  if (source == null || api == null) return TemporaryChatSaveOutcome.skipped;
  final sourceId = conversationScopedId(source);
  final authEpoch = ref.read(openWebUiAuthSessionEpochProvider);

  bool owns() {
    if (!(isCurrentOwner?.call() ?? true)) return false;
    final active = ref.read(activeConversationProvider);
    return active != null &&
        conversationScopedId(active) == sourceId &&
        identical(ref.read(apiServiceProvider), api) &&
        identical(ref.read(openWebUiAuthSessionEpochProvider), authEpoch);
  }

  try {
    final List<ChatMessage> messages = (await readCompleteActiveChatHistory(
      ref,
    )).messages;
    if (messages.isEmpty || !owns()) return TemporaryChatSaveOutcome.skipped;

    final Model? selectedModel = ref.read(selectedModelProvider);
    final Conversation created = await api.createConversation(
      title: temporaryChatTitle(messages),
      messages: messages,
      model: selectedModel?.id ?? '',
      systemPrompt: source.systemPrompt,
      folderId: source.folderId,
      chatParams: source.chatParams.isEmpty ? null : source.chatParams,
    );
    if (!owns()) return TemporaryChatSaveOutcome.skipped;

    // The created chat carries what it was created with, which is what the
    // temporary chat had been sent with.
    final Conversation saved = created.copyWith(
      messages: messages,
      chatParams: created.chatParams.isEmpty
          ? source.chatParams
          : created.chatParams,
    );
    ref.read(activeConversationProvider.notifier).set(saved);
    ref
        .read(conversationsProvider.notifier)
        .upsertConversation(
          saved.copyWith(
            messages: const <ChatMessage>[],
            updatedAt: DateTime.now(),
          ),
          trustFolderConversation:
              saved.folderId != null && saved.folderId!.isNotEmpty,
        );
    ref.read(temporaryChatEnabledProvider.notifier).set(false);
    refreshConversationsCache(ref);
    return TemporaryChatSaveOutcome.saved;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'temporary-chat-save-failed',
      scope: 'chat/page',
      error: error,
      stackTrace: stackTrace,
    );
    return owns()
        ? TemporaryChatSaveOutcome.failed
        : TemporaryChatSaveOutcome.skipped;
  }
}
