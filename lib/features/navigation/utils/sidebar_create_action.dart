import 'package:conduit/l10n/app_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart'
    show isLocallyMintedDirectModel;
import 'package:conduit_core/features/hermes/models/hermes_model.dart'
    show isHermesModel;
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../providers/sidebar_providers.dart';
import '../providers/conversation_selection_provider.dart';

import 'package:conduit_core/features/channels/providers/channel_providers.dart';

import '../../channels/utils/channel_request_owner.dart';
import '../../channels/widgets/channel_form_dialog.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as chat;
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../../notes/providers/notes_providers.dart';

typedef SidebarCreateActionHandler = Future<void> Function(
  BuildContext context,
  WidgetRef ref,
);
typedef SidebarCreateActionIconBuilder = IconData Function();

final class SidebarCreateAction {
  const SidebarCreateAction({
    required SidebarCreateActionIconBuilder iconBuilder,
    required this.sfSymbol,
    required this.label,
    required SidebarCreateActionHandler handler,
  }) : _iconBuilder = iconBuilder,
       _handler = handler;

  final String sfSymbol;
  final String Function(AppLocalizations l10n) label;
  final SidebarCreateActionIconBuilder _iconBuilder;
  final SidebarCreateActionHandler _handler;

  IconData get icon => _iconBuilder();

  Future<void> run(BuildContext context, WidgetRef ref) =>
      _handler(context, ref);
}

String _newChatLabel(AppLocalizations l10n) => l10n.newChat;
String _newNoteLabel(AppLocalizations l10n) => l10n.createNote;
String _newChannelLabel(AppLocalizations l10n) => l10n.channelCreateTitle;

IconData _newChatIcon() => UiUtils.newChatIcon;
IconData _newNoteIcon() => UiUtils.newNoteIcon;
IconData _newChannelIcon() => UiUtils.newChannelIcon;

const chatSidebarCreateAction = SidebarCreateAction(
  iconBuilder: _newChatIcon,
  sfSymbol: 'square.and.pencil',
  label: _newChatLabel,
  handler: _startNewChat,
);

const hermesChatSidebarCreateAction = SidebarCreateAction(
  iconBuilder: _newChatIcon,
  sfSymbol: 'square.and.pencil',
  label: _newChatLabel,
  handler: _startNewHermesChat,
);

const noteSidebarCreateAction = SidebarCreateAction(
  iconBuilder: _newNoteIcon,
  sfSymbol: 'doc.badge.plus',
  label: _newNoteLabel,
  handler: _createNote,
);

const channelSidebarCreateAction = SidebarCreateAction(
  iconBuilder: _newChannelIcon,
  sfSymbol: 'number',
  label: _newChannelLabel,
  handler: _createChannel,
);

Future<void> _startNewChat(BuildContext context, WidgetRef ref) async {
  ConduitHaptics.selectionClick();
  final sliding = ref.read(appSettingsProvider).slidingSidebarEnabled;
  if (sliding) {
    ref.read(conversationSelectionProvider.notifier).cancel();
  }
  if (sliding && ref.read(openWebUiAccountAvailableProvider)) {
    final epoch = ref.read(openWebUiAuthSessionEpochProvider);
    final api = ref.read(apiServiceProvider);
    final routeRevision = NavigationService.currentRouteRevision;
    final selectionGeneration = ref
        .read(conversationSelectionProvider)
        .generation;
    final selected = ref.read(selectedModelProvider);
    final manual = ref.read(isManualModelSelectionProvider);
    // A message sent while the model is looked up starts or continues a
    // conversation the late New Chat must not clear. Streaming replies change
    // neither.
    final conversationId = ref.read(activeConversationProvider)?.id;
    final sentMessages = _userMessageCount(ref);
    bool isCurrent() =>
        ref.read(activeConversationProvider)?.id == conversationId &&
        _userMessageCount(ref) == sentMessages &&
        ref.read(appSettingsProvider).slidingSidebarEnabled &&
        ref.read(openWebUiAuthSessionEpochProvider) == epoch &&
        identical(ref.read(apiServiceProvider), api) &&
        NavigationService.currentRouteRevision == routeRevision &&
        ref.read(conversationSelectionProvider).generation ==
            selectionGeneration &&
        (!ref.read(isManualModelSelectionProvider) ||
            (manual && identical(ref.read(selectedModelProvider), selected))) &&
        ref.read(sidebarSelectedHistoryTabProvider) == SidebarTabId.chats;
    var modelsFailed = false;
    final models = await ref.read(modelsProvider.future).catchError((Object _) {
      modelsFailed = true;
      return <Model>[];
    });
    if (!context.mounted || !isCurrent()) return;
    // This history starts chats on every backend but Hermes, which has its
    // own. Otherwise the choice follows the default a new chat restores.
    final usable = [
      for (final model in models)
        if (!model.isHidden && !isHermesModel(model)) model,
    ];
    final candidates = chat.folderDefaultModelCandidates(models);
    final defaultId = ref.read(appSettingsProvider).defaultModel;
    final hasDefault = defaultId != null && defaultId.isNotEmpty;
    var model = usable.where((model) => model.id == defaultId).firstOrNull;
    if (model == null &&
        ref.read(preferredBackendProvider) == PreferredBackend.direct) {
      model = usable.where(isLocallyMintedDirectModel).firstOrNull;
    }
    // With no default chosen, the cached one is cleared and the server asked
    // again, as it may have changed its default since.
    if (model == null && hasDefault && candidates.isNotEmpty) {
      final cached = await ref
          .read(optimizedStorageServiceProvider)
          .getLocalDefaultModel()
          .catchError((Object _) => null);
      if (!context.mounted || !isCurrent()) return;
      model = candidates.where((model) => model.id == cached?.id).firstOrNull;
    }
    if (model == null && candidates.isNotEmpty) {
      final serverDefault = await api?.getDefaultModel().catchError(
        (Object _) => null,
      );
      if (!context.mounted || !isCurrent()) return;
      model =
          candidates.where((model) => model.id == serverDefault).firstOrNull ??
          candidates.where((model) => model.name == serverDefault).singleOrNull;
    }
    final current = ref.read(selectedModelProvider);
    model ??=
        candidates
            .where((candidate) => candidate.id == current?.id)
            .firstOrNull ??
        candidates.firstOrNull;
    if (model == null) {
      final l10n = AppLocalizations.of(context)!;
      AdaptiveSnackBar.show(
        context,
        message: modelsFailed
            ? l10n.failedToLoadModels
            : l10n.noModelsAvailable,
      );
      return;
    }
    chat.startNewChat(ref, modelForNewConversation: model);
  } else {
    chat.startNewChat(ref);
  }
  NavigationService.router.go(Routes.chat);
  _closeSidebarIfNeeded(context);
}

/// Messages the person has sent in the open transcript. Without one there is
/// nothing a late New Chat could clear.
int _userMessageCount(WidgetRef ref) {
  if (!ref.read(chat.chatMessagesProvider.exists)) return 0;
  return ref
      .read(chat.chatMessagesProvider)
      .where((message) => message.role == 'user')
      .length;
}

Future<void> _startNewHermesChat(BuildContext context, WidgetRef ref) async {
  ConduitHaptics.selectionClick();
  if (ref.read(appSettingsProvider).slidingSidebarEnabled) {
    ref.read(conversationSelectionProvider.notifier).cancel();
  }
  await chat.startNewHermesChat(ref);
  if (!context.mounted) return;
  NavigationService.router.go(Routes.chat);
  _closeSidebarIfNeeded(context);
}

Future<void> _createNote(BuildContext context, WidgetRef ref) async {
  ConduitHaptics.lightImpact();
  final defaultTitle = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final note = await ref
      .read(noteCreatorProvider.notifier)
      .createNote(title: defaultTitle);

  if (note == null || !context.mounted) {
    return;
  }

  NavigationService.router.go('/notes/${note.id}');
  _closeSidebarIfNeeded(context);
}

Future<void> _createChannel(BuildContext context, WidgetRef ref) async {
  ConduitHaptics.lightImpact();
  final api = ref.read(apiServiceProvider);
  if (api == null) return;
  final authSessionEpoch = ref.read(openWebUiAuthSessionEpochProvider);
  final result = await showCreateChannelFormDialog(context);
  if (result == null ||
      !context.mounted ||
      !isChannelRequestOwnerCurrent(
        ref: ref,
        api: api,
        authSessionEpoch: authSessionEpoch,
      )) {
    return;
  }

  try {
    final json = await api.createChannel(
      name: result.name,
      type: 'group',
      description: result.description,
      isPrivate: result.isPrivate,
    );

    if (!context.mounted ||
        !isChannelRequestOwnerCurrent(
          ref: ref,
          api: api,
          authSessionEpoch: authSessionEpoch,
        )) {
      return;
    }

    ref.read(channelsListProvider.notifier).addChannel(Channel.fromJson(json));
  } catch (error, stackTrace) {
    DebugLogger.error(
      'create-channel-failed',
      scope: 'navigation/sidebar-create',
      error: error,
      stackTrace: stackTrace,
    );
    if (!context.mounted ||
        !isChannelRequestOwnerCurrent(
          ref: ref,
          api: api,
          authSessionEpoch: authSessionEpoch,
        )) {
      return;
    }

    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.channelCreateError,
    );
  }
}

void _closeSidebarIfNeeded(BuildContext context) {
  closeSidebarDrawerIfOverlay(context);
}
