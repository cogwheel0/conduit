part of 'chat_providers.dart';

void resetHermesForNewChat(dynamic ref) {
  final registry = ref.read(hermesRunRegistryProvider) as HermesRunRegistry;
  for (final stop in registry.cancelAll()) {
    _observeDetachedCancellation(stop, scope: 'hermes/cancel');
  }
  ref.read(hermesActiveSessionProvider.notifier).set(null);
}

void resetDirectRunsForNewChat(dynamic ref) {
  final DirectRunRegistry registry = ref.read(directRunRegistryProvider);
  for (final stop in registry.cancelAll()) {
    _observeDetachedCancellation(stop, scope: 'direct-connections/cancel');
  }
}

/// Toggle filters are composer state, not a default that should cross a
/// conversation boundary when the same model remains selected.
void clearSelectedFiltersForConversationBoundary(dynamic ref) {
  ref.read(selectedFilterIdsProvider.notifier).clear();
}

/// Returns only selected toggle filters exposed by [model].
///
/// Conversation-boundary clears remain the primary lifecycle rule. This
/// request-time intersection is defense in depth for stale state after model
/// changes or an unanticipated navigation path.
List<String> selectedFilterIdsForModel(dynamic ref, Model model) {
  final allowedIds = <String>{
    for (final filter in model.filters ?? const []) filter.id,
  };
  if (allowedIds.isEmpty) return const <String>[];

  return ref
      .read(selectedFilterIdsProvider)
      .where(allowedIds.contains)
      .toList(growable: false);
}

// Start a new chat (unified function for both "New Chat" button and home screen)
void startNewChat(dynamic ref, {Model? modelForNewConversation}) {
  resetHermesForNewChat(ref);
  resetDirectRunsForNewChat(ref);
  clearSelectedFiltersForConversationBoundary(ref);

  // Clear active conversation
  ref.read(activeConversationProvider.notifier).clear();

  // Clear messages
  ref.read(chatMessagesProvider.notifier).clearMessages();

  // Clear context attachments (web pages, YouTube, knowledge base docs)
  ref.read(contextAttachmentsProvider.notifier).clear();

  // Clear any pending folder selection
  ref.read(pendingFolderIdProvider.notifier).clear();

  if (modelForNewConversation != null) {
    // Voice startup admits a concrete transport before this reset. Keep that
    // exact model pinned so the asynchronous default restore cannot switch the
    // first voice turn to a different, potentially unauthenticated backend.
    ref.read(isManualModelSelectionProvider.notifier).set(true);
    ref
        .read(selectedModelProvider.notifier)
        .set(modelForNewConversation, allowHidden: true);
  } else {
    // Reset to default model for new conversations (fixes #296)
    restoreDefaultModel(ref);
  }

  final settings = ref.read(appSettingsProvider);
  ref
      .read(temporaryChatEnabledProvider.notifier)
      .set(settings.temporaryChatByDefault);
}

/// Starts a new chat pinned to the Hermes agent model. Unlike [startNewChat],
/// this does NOT reset to the default model (which would race past and clobber
/// the Hermes selection); it resolves and selects the Hermes model explicitly.
Future<void> startNewHermesChat(dynamic ref) async {
  resetHermesForNewChat(ref);
  resetDirectRunsForNewChat(ref);
  clearSelectedFiltersForConversationBoundary(ref);

  ref.read(activeConversationProvider.notifier).clear();
  ref.read(chatMessagesProvider.notifier).clearMessages();
  ref.read(contextAttachmentsProvider.notifier).clear();
  ref.read(pendingFolderIdProvider.notifier).clear();

  final settings = ref.read(appSettingsProvider);
  ref
      .read(temporaryChatEnabledProvider.notifier)
      .set(settings.temporaryChatByDefault);

  // Hermes is app-owned runtime state; starting it must never wait on an
  // unrelated OpenWebUI model request in mixed-backend setups.
  ref.read(isManualModelSelectionProvider.notifier).set(true);
  ref.read(selectedModelProvider.notifier).set(hermesSyntheticModel());
}

/// Restores the selected model to the user's configured default model.
/// Call this when starting a new conversation or when settings change.
Future<void> restoreDefaultModel(dynamic ref) async {
  // Mark that this is not a manual selection
  ref.read(isManualModelSelectionProvider.notifier).set(false);

  // If auto-select (no explicit default), clear the cached default model
  // so defaultModelProvider will fetch from server
  final settingsDefault = ref.read(appSettingsProvider).defaultModel;
  if (settingsDefault == null || settingsDefault.isEmpty) {
    final storage = ref.read(optimizedStorageServiceProvider);
    if (ref is Ref && !ref.mounted) return;
    await storage.saveLocalDefaultModel(null);
    if (ref is Ref && !ref.mounted) return;
    DebugLogger.log('cleared-cached-default', scope: 'chat/model');
  }

  // Invalidate and re-read to force defaultModelProvider to use settings priority
  ref.invalidate(defaultModelProvider);

  try {
    await ref.read(defaultModelProvider.future);
  } catch (e) {
    DebugLogger.error('restore-default-failed', scope: 'chat/model', error: e);
  }
}
