import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/providers/knowledge_cache_provider.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart'
    show activeNoteProvider;
import 'package:conduit_core/features/prompts/providers/prompts_providers.dart'
    show activePromptCommandProvider;
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/account_change_chats.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/misc.dart' show ProviderOrFamily;

/// Drops the keep-alive state that holds the previous Open WebUI account's
/// data or selections, when the active account changes. An open on-device
/// or Hermes chat survives, and so does a Direct or Hermes model picked
/// before the change: they belong to no account.
///
/// [ref] is the host's reader: a `Ref` in the app, the container in
/// `conduitd`. Providers only a host has (its sockets' listeners, a screen's
/// selection) stay that host's to reset.
void resetOpenWebUiAccountState(dynamic ref) {
  final active = ref.read(activeConversationProvider) as Conversation?;
  final selectedModel = ref.read(selectedModelProvider) as Model?;
  final keepModel =
      selectedModel != null &&
      (isLocallyMintedDirectModel(selectedModel) ||
          isHermesModel(selectedModel));
  for (final ProviderOrFamily provider in <ProviderOrFamily>[
    conversationsProvider,
    if (active == null ||
        accountChangeEndsChat(
          AccountChange.openWebUiSession,
          chatOwnerOf(active),
        ))
      activeConversationProvider,
    foldersProvider,
    modelsProvider,
    if (!keepModel) selectedModelProvider,
    // Kept with the model: the account's default, restored as the account
    // changes, leaves a model chosen by hand alone.
    if (!keepModel) isManualModelSelectionProvider,
    defaultModelProvider,
    imageModelsProvider,
    currentUserProvider,
    userSettingsProvider,
    rawUserSettingsProvider,
    personalizationSettingsProvider,
    userMemoriesProvider,
    accountProfileProvider,
    serverAboutInfoProvider,
    userPermissionsProvider,
    availableVoicesProvider,
    backendConfigProvider,
    socketServiceManagerProvider,
    toolsListProvider,
    selectedToolIdsProvider,
    selectedTerminalIdProvider,
    selectedFilterIdsProvider,
    contextAttachmentsProvider,
    knowledgeBasesProvider,
    channelsListProvider,
    activeChannelProvider,
    channelMessagesProvider,
    threadMessagesProvider,
    channelTypingUsersProvider,
    // Selections that name the previous account's folders, prompts, notes
    // or chats.
    pendingFolderIdProvider,
    folderDraftModelNoticeProvider,
    folderDraftComparisonProvider,
    folderDraftComparisonNoticeProvider,
    searchQueryProvider,
    activePromptCommandProvider,
    activeNoteProvider,
    // A selection still loading no longer owns the reset selection state, so
    // it would never clear the loading flag it set.
    isLoadingConversationProvider,
  ]) {
    ref.invalidate(provider);
  }
  (ref.read(knowledgeCacheProvider.notifier) as KnowledgeCacheNotifier)
      .clearAllCaches();
}
