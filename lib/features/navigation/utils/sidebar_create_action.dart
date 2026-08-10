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
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../channels/providers/channel_providers.dart';
import '../../channels/utils/channel_request_owner.dart';
import '../../channels/widgets/channel_form_dialog.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../../hermes/providers/hermes_providers.dart';
import '../../notes/providers/notes_providers.dart';
import '../../terminal/providers/terminal_providers.dart';
import '../providers/sidebar_providers.dart';
import '../providers/sidebar_tab_scroll_registry.dart';

enum _SidebarCreateActionKind { chat, hermesChat, note, channel }

class SidebarCreateActionSpec {
  const SidebarCreateActionSpec({required this.icon, required this.sfSymbol});

  final IconData icon;
  final String sfSymbol;
}

SidebarCreateActionSpec? sidebarCreateActionForActiveTab(WidgetRef ref) {
  final kind = _resolveSidebarCreateActionKind(
    tabId: ref.watch(sidebarActiveTabProvider),
    hermesOnly: ref.watch(hermesOnlyModeProvider),
    hermesOn: ref.watch(hermesEnabledProvider),
    notesOn: ref.watch(notesFeatureEnabledProvider),
    terminalOn: _watchTerminalTabVisible(ref),
    channelsOn: ref.watch(channelsFeatureEnabledProvider),
  );
  if (kind == null) {
    return null;
  }
  return switch (kind) {
    _SidebarCreateActionKind.chat ||
    _SidebarCreateActionKind.hermesChat => SidebarCreateActionSpec(
      icon: UiUtils.newChatIcon,
      sfSymbol: 'square.and.pencil',
    ),
    _SidebarCreateActionKind.note => SidebarCreateActionSpec(
      icon: UiUtils.newNoteIcon,
      sfSymbol: 'doc.badge.plus',
    ),
    _SidebarCreateActionKind.channel => SidebarCreateActionSpec(
      icon: UiUtils.newChannelIcon,
      sfSymbol: 'number',
    ),
  };
}

Future<void> runSidebarCreateAction(BuildContext context, WidgetRef ref) async {
  final kind = _resolveSidebarCreateActionKind(
    tabId: ref.read(sidebarActiveTabProvider),
    hermesOnly: ref.read(hermesOnlyModeProvider),
    hermesOn: ref.read(hermesEnabledProvider),
    notesOn: ref.read(notesFeatureEnabledProvider),
    terminalOn: _readTerminalTabVisible(ref),
    channelsOn: ref.read(channelsFeatureEnabledProvider),
  );
  switch (kind) {
    case null:
      return;
    case _SidebarCreateActionKind.chat:
      await _startNewChat(context, ref);
      break;
    case _SidebarCreateActionKind.hermesChat:
      await _startNewHermesChat(context, ref);
      break;
    case _SidebarCreateActionKind.note:
      await _createNote(context, ref);
      break;
    case _SidebarCreateActionKind.channel:
      await _createChannel(context, ref);
      break;
  }
}

_SidebarCreateActionKind? _resolveSidebarCreateActionKind({
  required SidebarTabId tabId,
  required bool hermesOnly,
  required bool hermesOn,
  required bool notesOn,
  required bool terminalOn,
  required bool channelsOn,
}) {
  // Hermes-only: the Hermes tab is the only tab, so "+" always starts a new
  // Hermes chat.
  if (hermesOnly) {
    return _SidebarCreateActionKind.hermesChat;
  }

  return switch (tabId) {
    SidebarTabId.chats => _SidebarCreateActionKind.chat,
    SidebarTabId.hermes when hermesOn => _SidebarCreateActionKind.hermesChat,
    SidebarTabId.notes when notesOn => _SidebarCreateActionKind.note,
    SidebarTabId.terminal when terminalOn => null,
    SidebarTabId.channels when channelsOn => _SidebarCreateActionKind.channel,
    _ => _SidebarCreateActionKind.chat,
  };
}

// Single source of truth for terminal-tab visibility (shared with the sidebar).
// Must match `sidebar_page.dart`'s `showTerminalTab` exactly, or the create
// action's tab-index mapping drifts from the rendered tabs and the wrong (or no)
// create action is shown — e.g. hiding the Channels create action while terminal
// availability is still loading.
bool _watchTerminalTabVisible(WidgetRef ref) {
  return ref.watch(terminalTabVisibleProvider);
}

bool _readTerminalTabVisible(WidgetRef ref) {
  return ref.read(terminalTabVisibleProvider);
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
  final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
  if (!isTablet) {
    ResponsiveDrawerLayout.of(context)?.close();
  }
}
