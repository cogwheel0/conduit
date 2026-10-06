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

/// Toggle filters and the code interpreter are composer state, not defaults
/// that should cross a conversation boundary when the same model remains
/// selected.
void clearSelectedFiltersForConversationBoundary(dynamic ref) {
  ref.read(selectedFilterIdsProvider.notifier).clear();
  ref.read(codeInterpreterEnabledProvider.notifier).clear();
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

/// The models a folder may save as its defaults, and a new draft may start on:
/// plain Open WebUI server models that are not hidden. Direct, Apple and Hermes
/// models belong to this device, not to the server's folder data, so a saved
/// list never names them and never resolves to them.
List<Model> folderDefaultModelCandidates(Iterable<Model> models) => [
  for (final model in models)
    if (!model.isHidden &&
        !isLocallyMintedDirectModel(model) &&
        !isHermesModel(model))
      model,
];

/// The two models a project draft is about to compare, or null for any other
/// draft. What the folder saved is honored only while the draft is still the one
/// it was saved for: same account, still this folder's unopened draft, the first
/// model still selected, and a comparison still possible. A pick made in the
/// model picker, an opened chat, another folder or another account therefore
/// ends it without anything having to clear it.
final folderDraftComparisonModelsProvider = Provider<List<Model>?>((ref) {
  final selection = ref.watch(folderDraftComparisonProvider);
  if (selection == null) return null;
  // Read by the ownership check below, watched here so a sign-in change
  // recomputes this.
  ref.watch(openWebUiAuthSessionEpochProvider);
  ref.watch(authTokenProvider3);
  ref.watch(currentUserProvider2);
  if (ref.watch(activeConversationProvider) != null ||
      ref.watch(pendingFolderIdProvider) != selection.folderId ||
      ref.watch(selectedModelProvider)?.id != selection.models.first.id ||
      !ref.watch(comparisonRuntimeAvailableProvider) ||
      !openWebUiConversationSelectionOwnerIsCurrent(ref, selection.owner)) {
    return null;
  }
  return selection.models;
});

/// A project that saves exactly two usable models starts its draft comparing
/// them, with no Compare command, whatever Advanced says. Any other list of
/// several models cannot be one comparison, so the draft keeps the first and
/// says so; the saved list itself is never touched.
void _startFolderDraftComparison(
  dynamic ref, {
  required String folderId,
  required OpenWebUiConversationSelectionOwner owner,
  required List<String> saved,
  required List<Model> usable,
}) {
  if (saved.length < 2) return;
  final comparing =
      usable.length == kComparisonSlotCount &&
      (ref.read(comparisonRuntimeAvailableProvider) as bool);
  if (comparing) {
    ref
        .read(folderDraftComparisonProvider.notifier)
        .set(
          FolderDraftComparisonSelection(
            folderId: folderId,
            owner: owner,
            models: List<Model>.unmodifiable(usable),
          ),
        );
  }
  if (!comparing || usable.length != saved.length) {
    ref.read(folderDraftComparisonNoticeProvider.notifier).set(folderId);
  }
}

/// How long a new folder draft waits for the folder's own project data before it
/// starts from what is cached.
const _folderDetailWait = Duration(seconds: 4);

/// Picks the model for a fresh draft inside [folderId]: the first of the
/// folder's saved default models (`data.model_ids`, in slot order) that this
/// server still offers. Otherwise the user's own default applies as for any new
/// chat, and when the folder had saved models but none is available the draft
/// says so through [folderDraftModelNoticeProvider].
///
/// A folder that saves exactly two models this server offers also starts the
/// draft comparing them, through [folderDraftComparisonModelsProvider]. The
/// first one is the selected model either way.
///
/// The saved list is read from the folder itself as the captured account (the
/// folder list is lean and has no project data), kept on the cached row, and
/// used from the cache alone when the folder cannot answer.
///
/// Runs with Advanced off: applying a saved default is not an editor. Only
/// plain Open WebUI server models qualify, so Direct, Apple and Hermes
/// identities are never chosen from a saved list.
///
/// This is the draft's single model resolution, started by the folder page when
/// it primes the draft. Everything it reads is captured first, and it applies
/// the result only if the draft is still the one it started for: same account
/// and server, still this folder's unopened draft, and the selection still the
/// object it saw. A pick the user made meanwhile, another folder's draft, an
/// opened chat or a new account therefore keeps what it has.
Future<void> restoreFolderDraftModel(dynamic ref, String folderId) async {
  final owner = captureOpenWebUiConversationSelectionOwner(ref);
  final api = ref.read(apiServiceProvider) as ApiService?;
  if (owner == null || api == null) {
    await restoreDefaultModel(ref);
    return;
  }

  final folders = ref.read(foldersProvider.notifier) as Folders;
  final projectOwner = folders.captureProjectOwner();
  ref.read(isManualModelSelectionProvider.notifier).set(false);
  // A comparison belongs to the restore that started it; this draft has none
  // until its own restore decides.
  ref.read(folderDraftComparisonProvider.notifier).clear();
  final selectedAtStart = ref.read(selectedModelProvider) as Model?;

  bool sameDraft() =>
      openWebUiConversationSelectionOwnerIsCurrent(ref, owner) &&
      identical(ref.read(apiServiceProvider), api) &&
      ref.read(pendingFolderIdProvider) == folderId &&
      ref.read(activeConversationProvider) == null;
  bool untouched() =>
      sameDraft() &&
      !(ref.read(isManualModelSelectionProvider) as bool) &&
      identical(ref.read(selectedModelProvider), selectedAtStart);

  var saved = const <String>[];
  try {
    final listed = await ref.read(foldersProvider.future) as List<Folder>;
    final cached = listed.where((folder) => folder.id == folderId).firstOrNull;
    saved = cached?.projectModelIds ?? saved;
    if (cached != null && projectOwner != null && untouched()) {
      // The server's folder list carries no project data, so the cached copy
      // can predate an edit made elsewhere. The folder itself is the
      // authority; when it cannot answer in good time the cache stands.
      final current = await folders
          .refreshProjectData(projectOwner, folderId)
          .timeout(_folderDetailWait);
      saved = current?.projectModelIds ?? saved;
    }
  } catch (_) {
    // An unreadable folder list leaves the draft on the user's default.
  }
  if (!untouched()) return;
  if (saved.isEmpty) {
    await restoreDefaultModel(ref, isCurrent: untouched);
    return;
  }

  var models = const <Model>[];
  try {
    models = await ref.read(modelsProvider.future) as List<Model>;
  } catch (_) {
    // No model list: nothing can be matched, and nothing is claimed missing.
  }
  if (!untouched()) return;

  final available = <String, Model>{
    for (final model in folderDefaultModelCandidates(models)) model.id: model,
  };
  // One entry per saved slot the server still offers, in slot order. The same
  // model saved twice is two slots.
  final usable = saved.map((id) => available[id]).nonNulls.toList();
  final chosen = usable.firstOrNull;
  if (chosen != null) {
    ref.read(selectedModelProvider.notifier).set(chosen);
    _startFolderDraftComparison(
      ref,
      folderId: folderId,
      owner: owner,
      saved: saved,
      usable: usable,
    );
    return;
  }

  await restoreDefaultModel(ref, isCurrent: untouched);
  if (models.isNotEmpty &&
      sameDraft() &&
      !(ref.read(isManualModelSelectionProvider) as bool)) {
    ref.read(folderDraftModelNoticeProvider.notifier).set(folderId);
  }
}

/// Restores the selected model to the user's configured default model.
/// Call this when starting a new conversation or when settings change.
///
/// [isCurrent], when given, says whether the draft this restore belongs to is
/// still the one to receive the default. It is checked after the storage await
/// and handed to the resolution through [defaultModelRestoreGuardProvider], so
/// the late global default is dropped, not applied, once the draft has moved on.
Future<void> restoreDefaultModel(
  dynamic ref, {
  bool Function()? isCurrent,
}) async {
  bool mounted() => ref is! Ref || ref.mounted;
  bool owned() => mounted() && (isCurrent?.call() ?? true);
  if (!owned()) return;

  // Mark that this is not a manual selection
  ref.read(isManualModelSelectionProvider.notifier).set(false);

  // If auto-select (no explicit default), clear the cached default model
  // so defaultModelProvider will fetch from server
  final settingsDefault = ref.read(appSettingsProvider).defaultModel;
  if (settingsDefault == null || settingsDefault.isEmpty) {
    final storage = ref.read(optimizedStorageServiceProvider);
    await storage.saveLocalDefaultModel(null);
    if (!owned()) return;
    DebugLogger.log('cleared-cached-default', scope: 'chat/model');
  }

  // Invalidate and re-read to force defaultModelProvider to use settings priority
  final guard = ref.read(defaultModelRestoreGuardProvider.notifier);
  guard.set(isCurrent);
  ref.invalidate(defaultModelProvider);

  try {
    await ref.read(defaultModelProvider.future);
  } catch (e) {
    DebugLogger.error('restore-default-failed', scope: 'chat/model', error: e);
  } finally {
    // The resolution read the guard as it began; drop ours unless a newer
    // restore has already replaced it.
    if (mounted() &&
        identical(ref.read(defaultModelRestoreGuardProvider), isCurrent)) {
      guard.set(null);
    }
  }
}
