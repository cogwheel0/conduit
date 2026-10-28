import 'package:conduit/l10n/app_localizations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../providers/sidebar_providers.dart';

import 'package:conduit_core/features/channels/providers/channel_providers.dart';

import '../../channels/utils/channel_request_owner.dart';
import '../../channels/widgets/channel_form_dialog.dart';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    as chat;

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
  if (ref.read(appSettingsProvider).slidingSidebarEnabled) {
    final epoch = ref.read(openWebUiAuthSessionEpochProvider);
    final routeRevision = NavigationService.currentRouteRevision;
    final selected = ref.read(selectedModelProvider);
    final models = await ref
        .read(modelsProvider.future)
        .catchError((Object _) => <Model>[]);
    if (!context.mounted ||
        !ref.read(appSettingsProvider).slidingSidebarEnabled ||
        ref.read(openWebUiAuthSessionEpochProvider) != epoch ||
        NavigationService.currentRouteRevision != routeRevision ||
        !identical(ref.read(selectedModelProvider), selected) ||
        ref.read(sidebarSelectedHistoryTabProvider) != SidebarTabId.chats) {
      return;
    }
    final candidates = chat.folderDefaultModelCandidates(models);
    final defaultId = ref.read(appSettingsProvider).defaultModel;
    final model =
        candidates.where((model) => model.id == defaultId).firstOrNull ??
        candidates.firstOrNull;
    chat.startNewChat(
      ref,
      modelForNewConversation: model,
      restoreDefault: false,
    );
  } else {
    chat.startNewChat(ref);
  }
  NavigationService.router.go(Routes.chat);
  _closeSidebarIfNeeded(context);
}

Future<void> _startNewHermesChat(BuildContext context, WidgetRef ref) async {
  ConduitHaptics.selectionClick();
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

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.channelCreateError)),
    );
  }
}

void _closeSidebarIfNeeded(BuildContext context) {
  closeSidebarDrawerIfOverlay(context);
}
