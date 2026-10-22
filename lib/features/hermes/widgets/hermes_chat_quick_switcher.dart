import 'dart:async';

import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../providers/hermes_messages.dart';
import '../providers/hermes_mobile_navigation.dart';
import 'hermes_mobile_shell.dart' show startHermesMobileConversation;
import 'hermes_session_tile.dart' show openHermesSession;

/// Uses the same server-backed Chats list as the custom Hermes home.
List<HermesSessionSummary> hermesQuickSwitcherSessions(
  Iterable<HermesSessionSummary> sessions,
  Iterable<HermesBot> bots, {
  required String profile,
}) {
  final recent = hermesRegularConversations(
    sessions,
    bots,
    profile: profile,
  ).where((session) => !session.archived).toList();
  recent.sort((a, b) {
    final order = (b.updatedAt ?? DateTime(1970)).compareTo(
      a.updatedAt ?? DateTime(1970),
    );
    return order != 0 ? order : a.id.compareTo(b.id);
  });
  return recent.take(6).toList(growable: false);
}

class HermesChatQuickSwitcher extends ConsumerStatefulWidget {
  const HermesChatQuickSwitcher({
    super.key,
    required this.bottomOffset,
    this.enabled = true,
  });

  final double bottomOffset;
  final bool enabled;

  @override
  ConsumerState<HermesChatQuickSwitcher> createState() =>
      _HermesChatQuickSwitcherState();
}

class _HermesChatQuickSwitcherState
    extends ConsumerState<HermesChatQuickSwitcher> {
  final _key = GlobalKey<ChatQuickSwitcherState>();
  HermesMobileChatSwitcher? _back;

  @override
  void dispose() {
    _back?.clear(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(hermesApiServiceProvider);
    final back = ref.watch(hermesMobileChatSwitcherProvider);
    final enabled =
        widget.enabled &&
        service != null &&
        ref.watch(hermesSessionOpeningProvider) == null;
    if (!enabled) {
      _back?.clear(this);
      _back = null;
    } else if (!identical(_back, back)) {
      _back?.clear(this);
      _back = back;
      back.register(this, () => _key.currentState?.dismiss() ?? false);
    }
    final recent = hermesQuickSwitcherSessions(
      ref.watch(hermesSessionsProvider).asData?.value ??
          const <HermesSessionSummary>[],
      ref.watch(hermesMessagesBotsProvider).asData?.value ??
          const <HermesBot>[],
      profile: service?.config.desktopProfile ?? 'default',
    );
    return ChatQuickSwitcher(
      key: _key,
      scope: service,
      enabled: enabled,
      bottomOffset: widget.bottomOffset,
      chats: [
        for (final session in recent)
          ChatSwitcherChat(id: session.id, title: session.title),
      ],
      onNewChat: () => unawaited(startHermesMobileConversation(ref)),
      onSelected: (chat) {
        final session = recent.where((item) => item.id == chat.id).firstOrNull;
        if (session == null ||
            !identical(service, ref.read(hermesApiServiceProvider))) {
          return;
        }
        unawaited(openHermesSession(context, ref, session));
      },
    );
  }
}
