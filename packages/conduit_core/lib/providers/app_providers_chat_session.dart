part of 'app_providers.dart';

/// This library's share of a chat session scope (`ChatSessionScope` in the
/// chat library): every app-level provider that holds one conversation's own
/// state, or is derived from it, made afresh in the scope's container.
///
/// Each override builds the provider exactly as the root does, from the same
/// notifier or create function, so a scope behaves like the app with one chat
/// open. What is left out is shared on purpose: the account, its database,
/// API client and socket, the model list and the conversation list belong to
/// every chat at once.
List<Override> chatSessionScopedAppOverrides() => <Override>[
  activeConversationProvider.overrideWith(ActiveConversationNotifier.new),
  activeConversationInPlaceRemapProvider.overrideWith(
    ActiveConversationInPlaceRemapNotifier.new,
  ),
  // The composer's model, and whether the user chose it: a turn in one chat
  // runs with its own model, whatever another chat or the root has picked.
  selectedModelProvider.overrideWith(SelectedModel.new),
  isManualModelSelectionProvider.overrideWith(IsManualModelSelection.new),
  defaultModelRestoreGuardProvider.overrideWith(DefaultModelRestoreGuard.new),
  pendingFolderIdProvider.overrideWith(PendingFolderId.new),
  temporaryChatEnabledProvider.overrideWith(TemporaryChatEnabled.new),
  // Derived from the selected model, so they follow the scope's own.
  imageGenerationAvailableProvider.overrideWith(_imageGenerationAvailable),
  selectedDirectWebSearchModeProvider.overrideWith(
    _selectedDirectWebSearchMode,
  ),
  webSearchAvailableProvider.overrideWith(_webSearchAvailable),
];
