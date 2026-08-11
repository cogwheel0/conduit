import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/models/channel.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/haptic_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../channels/providers/channel_providers.dart';
import '../../channels/utils/channel_request_owner.dart';
import '../../channels/widgets/channel_form_dialog.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../../notes/providers/notes_providers.dart';
import '../providers/sidebar_providers.dart';
import '../widgets/sidebar_tab_registry.dart';

class SidebarCreateActionSpec {
  const SidebarCreateActionSpec({required this.icon, required this.sfSymbol});

  final IconData icon;
  final String sfSymbol;
}

SidebarCreateActionSpec? sidebarCreateActionForActiveTab(WidgetRef ref) {
  final selectedTab = ref.watch(sidebarNavigationSnapshotProvider).selectedTab;
  final kind = sidebarTabDescriptor(selectedTab).createAction;
  if (kind == null) {
    return null;
  }
  return switch (kind) {
    SidebarCreateActionKind.chat ||
    SidebarCreateActionKind.hermesChat => SidebarCreateActionSpec(
      icon: UiUtils.newChatIcon,
      sfSymbol: 'square.and.pencil',
    ),
    SidebarCreateActionKind.note => SidebarCreateActionSpec(
      icon: UiUtils.newNoteIcon,
      sfSymbol: 'doc.badge.plus',
    ),
    SidebarCreateActionKind.channel => SidebarCreateActionSpec(
      icon: UiUtils.newChannelIcon,
      sfSymbol: 'number',
    ),
  };
}

Future<void> runSidebarCreateAction(BuildContext context, WidgetRef ref) async {
  final selectedTab = ref.read(sidebarNavigationSnapshotProvider).selectedTab;
  final kind = sidebarTabDescriptor(selectedTab).createAction;
  switch (kind) {
    case null:
      return;
    case SidebarCreateActionKind.chat:
      await _startNewChat(context, ref);
      break;
    case SidebarCreateActionKind.hermesChat:
      await _startNewHermesChat(context, ref);
      break;
    case SidebarCreateActionKind.note:
      await _createNote(context, ref);
      break;
    case SidebarCreateActionKind.channel:
      await _createChannel(context, ref);
      break;
  }
}

Future<void> _startNewChat(BuildContext context, WidgetRef ref) async {
  ConduitHaptics.selectionClick();
  chat.startNewChat(ref);
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
