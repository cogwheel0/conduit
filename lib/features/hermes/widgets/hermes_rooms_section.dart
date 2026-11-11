import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../navigation/widgets/chats_drawer.dart'
    show sidebarSectionDisclosureIcon;
import '../../navigation/widgets/conversation_tile.dart';
import 'hermes_room_avatars.dart';
import 'hermes_room_create_sheet.dart';

/// Opens [roomId] in the main pane, like a chat.
void openHermesRoom(BuildContext context, String roomId) {
  closeSidebarDrawerIfOverlay(context);
  NavigationService.router.go(Routes.hermesRoomPath(roomId));
}

/// The bots a new room may seat: the roster, narrowed to the profiles
/// Hermes says it can seat when it says.
List<HermesBot> hermesSeatableBots(
  List<HermesBot> bots,
  HermesRoomCapabilities capabilities,
) {
  final seatable = capabilities.seatableProfiles;
  return [
    for (final bot in bots)
      if (seatable == null || seatable.contains(bot.name)) bot,
  ];
}

/// The Hermes tab's Rooms section: the gateway's Group Chats, and "+" to
/// seat bots in a new one. Absent where Hermes has no rooms to offer.
class HermesRoomsSection extends ConsumerWidget {
  const HermesRoomsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capabilities = ref.watch(hermesRoomCapabilitiesProvider).value;
    if (capabilities == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final rooms = ref.watch(hermesRoomsProvider).value ?? const [];
    final bots = ref.watch(hermesBotsProvider).value ?? const [];
    final canCreate =
        capabilities.driver &&
        capabilities.offers('groups.create') &&
        hermesSeatableBots(bots, capabilities).length >= kMinHermesRoomSeats;
    if (rooms.isEmpty && !canCreate) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final expanded = ref.watch(hermesShowRoomsProvider);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _RoomsHeader(
            count: rooms.length,
            expanded: expanded,
            onToggle: () {
              ConduitHaptics.selectionClick();
              ref.read(hermesShowRoomsProvider.notifier).toggle();
            },
            onCreate: canCreate
                ? () => showHermesRoomCreateSheet(context)
                : null,
          ),
        ),
        if (expanded)
          SliverPadding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
            sliver: SliverList.builder(
              itemCount: rooms.length,
              itemBuilder: (context, index) =>
                  HermesRoomTile(room: rooms[index]),
            ),
          ),
      ],
    );
  }
}

class _RoomsHeader extends StatelessWidget {
  const _RoomsHeader({
    required this.count,
    required this.expanded,
    required this.onToggle,
    this.onCreate,
  });

  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.md,
        Spacing.sm,
        Spacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              key: const ValueKey<String>('hermes-rooms-header'),
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Row(
                children: [
                  Icon(
                    sidebarSectionDisclosureIcon(expanded),
                    color: theme.iconSecondary,
                    size: IconSize.listItem,
                  ),
                  const SizedBox(width: Spacing.xxs),
                  Text(
                    l10n.hermesRoomsTitle,
                    style: AppTypography.labelStyle.copyWith(
                      color: theme.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: Spacing.sm),
                    Text(
                      '$count',
                      style: AppTypography.labelMediumStyle.copyWith(
                        color: theme.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (onCreate != null)
            ConduitIconButton(
              key: const ValueKey<String>('hermes-rooms-create'),
              icon: Icons.add_rounded,
              tooltip: l10n.hermesRoomNew,
              iconColor: theme.iconSecondary,
              isCompact: true,
              onPressed: onCreate,
            ),
        ],
      ),
    );
  }
}

/// One room in the sidebar: its bots' faces, name, and when it was last
/// active.
class HermesRoomTile extends ConsumerWidget {
  const HermesRoomTile({super.key, required this.room});

  final HermesRoom room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selected = ref.watch(hermesOpenRoomProvider) == room.id;
    final updated = room.updatedAt;
    final subtitle = [
      l10n.hermesRoomBotCount(room.members.length),
      if (updated != null)
        hermesRoomActivityLabel(updated, context: context),
    ].join(' · ');
    return ChatStyleSidebarTile(
      key: ValueKey<String>('hermes-room-tile-${room.id}'),
      selected: selected,
      semanticLabel: room.name,
      onTap: () => openHermesRoom(context, room.id),
      child: SidebarListTileContent(
        title: room.name,
        subtitle: subtitle,
        selected: selected,
        leading: HermesRoomAvatarStack(members: room.members),
      ),
    );
  }
}

/// When a room was last active: the time today, the weekday this week,
/// else the date, in [locale] (the app's language, from [context] when
/// not given).
String hermesRoomActivityLabel(
  DateTime at, {
  BuildContext? context,
  String? locale,
  DateTime? now,
}) {
  final language =
      locale ??
      (context == null
          ? null
          : Localizations.localeOf(context).toLanguageTag());
  final current = now ?? DateTime.now();
  final local = at.toLocal();
  final today = DateTime(current.year, current.month, current.day);
  if (!local.isBefore(today)) return DateFormat.jm(language).format(local);
  if (today.difference(local).inDays < 6) {
    return DateFormat.E(language).format(local);
  }
  return DateFormat.MMMd(language).format(local);
}
