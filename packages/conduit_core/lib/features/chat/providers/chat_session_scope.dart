part of 'chat_providers.dart';

/// One chat's own copy of the chat library, for a host that keeps several
/// chats live at once.
///
/// The chat library was written for one open chat: the transcript, the
/// active conversation and the composer's choices (model, tools, web search,
/// reasoning, terminal) are app-wide providers, and a turn reads them where
/// it runs. A host that answers in two chats at the same time -- one where a
/// user starts a turn, opens another chat and starts another -- gives each
/// chat a scope instead: a child [ProviderContainer] in which those providers
/// are made afresh, from the same notifiers and create functions the root
/// uses. A turn is then started through the ordinary entry points
/// ([durableSend], [regenerateHistoricalMessageById],
/// [resendEditedUserMessage], [stopGenerationSettledProvider]) with the
/// scope's container as its `ref`, and streams into that scope's own
/// [ChatMessagesNotifier], exactly as a phone streams into the one on screen.
///
/// Everything not in [chatSessionScopeOverrides] is shared with the root: the
/// account, its database, API client and socket, the sync engine and outbox,
/// the model and conversation lists, the Direct and Hermes run registries and
/// the saved preferences. Those belong to every chat at once.
///
/// Mobile never opens one; it is additive.
///
/// Two things a scope cannot learn from the root, because the root only
/// updates its own copies:
///
/// * a chat's `local:` id replaced by the server's. The scope follows those
///   itself (see [applyChatRemapToActiveConversation]);
/// * an account change or sign-out, which the root answers by clearing its
///   own open chat. The host disposes its scopes then: a chat is another
///   account's once the account changes.
final class ChatSessionScope {
  ChatSessionScope._(this._parent, this.container);

  /// Opens a scope under [parent], the host's root container.
  factory ChatSessionScope.open(ProviderContainer parent) {
    final container = ProviderContainer(
      parent: parent,
      overrides: chatSessionScopeOverrides(),
    );
    final scope = ChatSessionScope._(parent, container);
    parent.read(chatSessionRegistryProvider)._add(scope);
    // Held for the scope's life: the remap follower; the one scoped provider
    // that would otherwise dispose between a write and a read; and the
    // transcript and the selected model, which follow the account, its API
    // client and socket, and its sign-in through listeners of their own.
    // Riverpod keeps a provider's own listeners awake only while something
    // listens to it, a read alone not counting, so a host that only read
    // them would see an account change only at its next read.
    container
      ..listen<void>(_chatSessionRemapFollowerProvider, (_, _) {})
      ..listen<bool>(temporaryChatEnabledProvider, (_, _) {})
      ..listen<List<ChatMessage>>(chatMessagesProvider, (_, _) {})
      ..listen<Model?>(selectedModelProvider, (_, _) {});
    return scope;
  }

  final ProviderContainer _parent;

  /// The scope's container. Pass it as the `ref` of the chat library's entry
  /// points, and read the scope's state from it.
  final ProviderContainer container;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  /// The conversation this scope has open, or null for a new chat that has
  /// not been sent yet.
  Conversation? get conversation => container.read(activeConversationProvider);

  /// The scope's transcript.
  List<ChatMessage> get messages => container.read(chatMessagesProvider);

  /// Whether an answer is streaming in this scope.
  bool get isStreaming => container.read(isChatStreamingProvider);

  /// Disposes the container, and with it every stream, socket handler and
  /// database watch the scope's transcript held. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _parent.read(chatSessionRegistryProvider)._remove(this);
    } catch (_) {
      // The root may already be gone at shutdown.
    }
    container.dispose();
  }
}

/// The chat session scopes open under a root container.
///
/// Read by the outbox's completion runner, which runs in the root: a queued
/// Open WebUI completion for a chat a scope has open streams live into that
/// scope, as one for the root's own open chat streams into the root, instead
/// of running headless. Empty on mobile.
final class ChatSessionRegistry {
  final List<ChatSessionScope> _scopes = <ChatSessionScope>[];

  /// The open scopes, oldest first.
  List<ChatSessionScope> get scopes =>
      List<ChatSessionScope>.unmodifiable(_scopes);

  void _add(ChatSessionScope scope) => _scopes.add(scope);

  void _remove(ChatSessionScope scope) => _scopes.remove(scope);
}

final chatSessionRegistryProvider = Provider<ChatSessionRegistry>(
  (_) => ChatSessionRegistry(),
);

/// The overrides that make a [ChatSessionScope]: every provider holding one
/// conversation's state, or derived from it, built again from its own
/// notifier or create function.
///
/// Composed from each library's share so the private create functions stay
/// private. Mobile never reads it. Kept as one list so the audit of what a
/// chat owns is in one place:
///
/// * the conversation and its transcript: [activeConversationProvider],
///   [activeConversationInPlaceRemapProvider], [chatMessagesProvider],
///   [isLoadingConversationProvider], [streamingContentProvider] and the
///   streaming flags derived from them;
/// * the composer: [selectedModelProvider] and whether it was chosen by hand,
///   the model last picked in the chat ([chatModelPickProvider]),
///   web search, image generation and the code interpreter (with what makes
///   them available), tools, filters, terminal, attachments, the chat's
///   pending settings and folder, temporary chat;
/// * reasoning effort, derived from the selected model;
/// * the selected model's controls and the option each applies (the picks
///   themselves are the account's settings on the server, and stay shared);
/// * the chat's terminal session and the terminals the server offers it,
///   the coding agents its terminal offers, whether the chat talks to one,
///   and the guard that drops an agent whose terminal is gone (a host that
///   offers agents keeps the guard alive in each scope, as the app does in
///   its root);
/// * the Hermes session the chat is bound to and its navigation epoch, which
///   the root bumps on every chat switch and a running Hermes turn checks;
/// * the providers that capture their `ref` to act on "the open chat" later:
///   stop, regenerate, and the Hermes busy-turn controller;
/// * the Open WebUI prompt waiting in the chat (a confirmation, a question).
List<Override> chatSessionScopeOverrides() => <Override>[
  ...chatSessionScopedAppOverrides(),
  chatMessagesProvider.overrideWith(ChatMessagesNotifier.new),
  isLoadingConversationProvider.overrideWith(IsLoadingConversation.new),
  streamingContentProvider.overrideWith(StreamingContent.new),
  isChatStreamingProvider.overrideWith(_isChatStreaming),
  isOwnChatStreamingProvider.overrideWith(_isOwnChatStreaming),
  shouldProtectLocalStreamingStateProvider.overrideWith(
    _shouldProtectLocalStreamingState,
  ),
  chatPicksSessionProvider.overrideWith(ChatPicksSession.new),
  // The model last picked in the chat, which regenerating an answer of an
  // earlier multi-model turn uses.
  chatModelPickProvider.overrideWith(ChatModelPickNotifier.new),
  prefilledInputTextProvider.overrideWith(PrefilledInputText.new),
  availableToolsProvider.overrideWith(AvailableToolsNotifier.new),
  webSearchEnabledProvider.overrideWith(WebSearchEnabledNotifier.new),
  imageGenerationEnabledProvider.overrideWith(
    ImageGenerationEnabledNotifier.new,
  ),
  codeInterpreterEnabledProvider.overrideWith(
    CodeInterpreterEnabledNotifier.new,
  ),
  codeInterpreterBlockProvider.overrideWith(_codeInterpreterBlock),
  codeInterpreterOfferProvider.overrideWith(_codeInterpreterOffer),
  _chatFeatureDefaultsProvider.overrideWith(_chatFeatureDefaults),
  pendingOpenWebUiChatSettingsProvider.overrideWith(
    PendingOpenWebUiChatSettings.new,
  ),
  selectedToolIdsProvider.overrideWith(SelectedToolIds.new),
  selectedFilterIdsProvider.overrideWith(SelectedFilterIds.new),
  selectedTerminalIdProvider.overrideWith(SelectedTerminalId.new),
  contextAttachmentsProvider.overrideWith(ContextAttachmentsNotifier.new),
  attachedFilesProvider.overrideWith(AttachedFilesNotifier.new),
  queuedDraftAttachmentsProvider.overrideWith(
    QueuedDraftAttachmentsNotifier.new,
  ),
  chatBranchControlsProvider.overrideWith(_chatBranchControls),
  regenerateLastMessageProvider.overrideWith(_regenerateLastMessage),
  stopGenerationProvider.overrideWith(_stopGenerationAction),
  stopGenerationSettledProvider.overrideWith(_stopGenerationSettledAction),
  hermesBusyTurnControllerProvider.overrideWith(HermesBusyTurnController.new),
  // One Open WebUI prompt at a time per chat: a confirmation or question
  // raised in one chat must not replace another chat's.
  openWebUiLivePromptProvider.overrideWith(OpenWebUiLivePromptNotifier.new),
  selectedModelControlStatesProvider.overrideWith(_selectedModelControlStates),
  terminalAgentScopeProvider.overrideWith(_terminalAgentScope),
  terminalAgentModelsProvider.overrideWith(_terminalAgentModels),
  activeChatUsesTerminalAgentProvider.overrideWith(
    _activeChatUsesTerminalAgent,
  ),
  terminalAgentSelectionGuardProvider.overrideWith(
    _terminalAgentSelectionGuard,
  ),
  ...chatSessionScopedReasoningOverrides(),
  ...chatSessionScopedTerminalOverrides(),
  ...chatSessionScopedHermesOverrides(),
  _chatSessionRemapFollowerProvider.overrideWith(_followChatSessionRemaps),
];

/// Swaps [ref]'s open chat from a `local:` id to the server's, in place, when
/// the sync engine reports that remap.
///
/// The root does this through `remapRouteSyncProvider`; a scope through
/// [_chatSessionRemapFollowerProvider]. Shared so the two cannot drift.
void applyChatRemapToActiveConversation(dynamic ref, RemapEvent event) {
  if (event.entityKind != 'chat') return;
  final active = ref.read(activeConversationProvider) as Conversation?;
  if (active == null ||
      active.id != event.fromId ||
      !conversationUsesOpenWebUiStorage(active)) {
    return;
  }
  DebugLogger.log(
    'remap-active-chat',
    scope: 'chat/remap',
    data: {'from': event.fromId, 'to': event.toId},
  );
  (ref.read(activeConversationProvider.notifier) as ActiveConversationNotifier)
      .remapIdInPlace(fromId: event.fromId, toId: event.toId);
}

/// In the root it does nothing; each scope overrides it with
/// [_followChatSessionRemaps].
final _chatSessionRemapFollowerProvider = Provider<void>((_) {});

void _followChatSessionRemaps(Ref ref) {
  final subscription = ref.read(syncEngineProvider.notifier).remapEvents.listen(
    (event) {
      if (event.entityKind == 'chat') {
        applyChatRemapToActiveConversation(ref, event);
      } else if (event.entityKind == 'folder' &&
          ref.read(pendingFolderIdProvider) == event.fromId) {
        ref.read(pendingFolderIdProvider.notifier).set(event.toId);
      }
    },
  );
  ref.onDispose(subscription.cancel);
}
