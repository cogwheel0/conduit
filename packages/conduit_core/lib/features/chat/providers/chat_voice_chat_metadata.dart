part of 'chat_providers.dart';

/// How long a chat a realtime call created waits for its server id before it
/// is titled; offline any longer, it keeps the title from its first words.
const _voiceChatServerIdWait = Duration(minutes: 2);

/// Titles and tags the chat a realtime call's first exchange created.
///
/// The voice answered that exchange itself, so no chat completion ran to
/// generate them. Mirrors Open WebUI 0.12.1's web client
/// (`generateVoiceChatMetadata` in `Chat.svelte`): a generated title replaces
/// the one from the first words unless the chat was renamed meanwhile, and
/// generated tags are added, each as the user's settings allow. Every request
/// carries [authSnapshot], the session that sent, so a sign-in change on the
/// way cancels the rest instead of sending the words with another account's
/// credentials. Stops quietly when anything fails.
Future<void> _generateVoiceChatMetadata(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required ApiAuthSnapshot? authSnapshot,
  required SyncEngine syncEngine,
  required String localChatId,
  required String userMessageId,
  required String modelId,
  required String content,
  required String initialTitle,
}) async {
  final api = owner.api;
  final db = owner.database;
  if (api is! ApiService || db == null) return;
  final titleLocks = ref.read(chatTitleLocksProvider) as ChatTitleLocks;
  try {
    final chatId = await _createdChatServerId(
      db,
      syncEngine,
      localChatId: localChatId,
      userMessageId: userMessageId,
    );
    if (chatId == null) return;
    Map<String, dynamic>? userSettings;
    try {
      userSettings = await api.getUserSettings(authSnapshot: authSnapshot);
    } catch (_) {}
    final tasks = _buildOpenWebUiBackgroundTasks(
      userSettings: userSettings,
      shouldGenerateTitle: true,
    );
    final messages = [
      <String, dynamic>{'role': 'user', 'content': content},
    ];
    if (tasks['title_generation'] == true) {
      final title = (await api.generateChatTitle(
        model: modelId,
        messages: messages,
        chatId: chatId,
        authSnapshot: authSnapshot,
      ))?.trim();
      if (title != null && title.isNotEmpty) {
        // A rename the user started meanwhile finishes first. The server's
        // title shows it, and one made elsewhere, so it is kept.
        await titleLocks.runExclusive(chatId, () async {
          final saved = await api.getConversation(
            chatId,
            authSnapshot: authSnapshot,
          );
          if (saved.title != initialTitle) return;
          await api.updateConversation(
            chatId,
            title: title,
            authSnapshot: authSnapshot,
          );
          if (openWebUiCompletionContextIsCurrent(ref, owner)) {
            ref
                .read(conversationsProvider.notifier)
                .applyServerGeneratedTitle(chatId, title);
          }
        });
      }
    }
    if (tasks['tags_generation'] == true) {
      final tags = await api.generateChatTags(
        model: modelId,
        messages: messages,
        chatId: chatId,
        authSnapshot: authSnapshot,
      );
      for (final tag in tags) {
        await api.addChatTag(chatId, tag, authSnapshot: authSnapshot);
      }
      if (tags.isNotEmpty && openWebUiCompletionContextIsCurrent(ref, owner)) {
        refreshConversationsCache(ref);
      }
    }
  } catch (error, stackTrace) {
    DebugLogger.error(
      'voice-chat-metadata-failed',
      scope: 'chat/voice',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// The server id of the chat created as [localChatId], once its creation
/// has synced; null when it is gone, or still unsynced after
/// [_voiceChatServerIdWait].
Future<String?> _createdChatServerId(
  AppDatabase db,
  SyncEngine syncEngine, {
  required String localChatId,
  required String userMessageId,
}) async {
  // Listen before looking, so a remap committing in between is not missed.
  final remapped = syncEngine.remapEvents
      .where(
        (event) => event.entityKind == 'chat' && event.fromId == localChatId,
      )
      .map((event) => event.toId)
      .first
      .timeout(_voiceChatServerIdWait);
  final owner = await resolveDurableChatMessageOwner(
    db,
    recordedChatId: localChatId,
    messageId: userMessageId,
    expectedRole: 'user',
  );
  if (owner == null || owner != localChatId) {
    remapped.ignore();
    return owner;
  }
  try {
    return await remapped;
  } on Object {
    return null;
  }
}
