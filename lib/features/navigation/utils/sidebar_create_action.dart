import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/models/channel.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/haptic_service.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../channels/providers/channel_providers.dart';
import '../../channels/widgets/channel_form_dialog.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../../notes/providers/notes_providers.dart';
import '../providers/sidebar_providers.dart';

enum _SidebarCreateActionKind { chat, note, channel }

class SidebarCreateActionSpec {
  const SidebarCreateActionSpec({required this.icon, required this.sfSymbol});

  final IconData icon;
  final String sfSymbol;
}

SidebarCreateActionSpec sidebarCreateActionForActiveTab(
  WidgetRef ref,
  AppLocalizations l10n,
) {
  final kind = _resolveSidebarCreateActionKind(
    tabIndex: ref.watch(sidebarActiveTabProvider),
    notesOn: ref.watch(notesFeatureEnabledProvider),
    channelsOn: ref.watch(channelsFeatureEnabledProvider),
  );
  return switch (kind) {
    _SidebarCreateActionKind.chat => SidebarCreateActionSpec(
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
    tabIndex: ref.read(sidebarActiveTabProvider),
    notesOn: ref.read(notesFeatureEnabledProvider),
    channelsOn: ref.read(channelsFeatureEnabledProvider),
  );
  switch (kind) {
    case _SidebarCreateActionKind.chat:
      await _startNewChat(context, ref);
    case _SidebarCreateActionKind.note:
      await _createNote(context, ref);
    case _SidebarCreateActionKind.channel:
      await _createChannel(context, ref);
  }
}

_SidebarCreateActionKind _resolveSidebarCreateActionKind({
  required int tabIndex,
  required bool notesOn,
  required bool channelsOn,
}) {
  var currentIndex = 0;
  if (tabIndex == currentIndex) {
    return _SidebarCreateActionKind.chat;
  }
  currentIndex++;

  if (notesOn) {
    if (tabIndex == currentIndex) {
      return _SidebarCreateActionKind.note;
    }
    currentIndex++;
  }

  if (channelsOn && tabIndex == currentIndex) {
    return _SidebarCreateActionKind.channel;
  }

  return _SidebarCreateActionKind.chat;
}

Future<void> _startNewChat(BuildContext context, WidgetRef ref) async {
  ConduitHaptics.selectionClick();
  chat.startNewChat(ref);
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
  final result = await showCreateChannelFormDialog(context);
  if (result == null || !context.mounted) {
    return;
  }

  try {
    final api = ref.read(apiServiceProvider);
    if (api == null) {
      return;
    }

    final json = await api.createChannel(
      name: result.name,
      type: 'group',
      description: result.description,
      isPrivate: result.isPrivate,
    );

    if (!context.mounted) {
      return;
    }

    ref.read(channelsListProvider.notifier).addChannel(Channel.fromJson(json));
  } catch (_) {
    if (!context.mounted) {
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
