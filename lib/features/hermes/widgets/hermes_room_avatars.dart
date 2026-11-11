import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import 'hermes_bot_avatar.dart';

/// Shape colors for a member that is not a Bot Mode bot of this
/// connection, picked by its profile so it keeps one color.
const _fallbackColors = [
  '#8b5cf6',
  '#0ea5e9',
  '#f97316',
  '#10b981',
  '#ec4899',
  '#eab308',
];

/// The roster bot a room member is, when it is one.
HermesBot? hermesRoomMemberBot(List<HermesBot>? bots, String profile) {
  for (final bot in bots ?? const <HermesBot>[]) {
    if (bot.name == profile) return bot;
  }
  return null;
}

/// One room member's face: its Bot Mode avatar when the roster has it,
/// else a shape face in a color of its own.
class HermesRoomMemberAvatar extends ConsumerWidget {
  const HermesRoomMemberAvatar({
    super.key,
    required this.member,
    this.size = 28,
    this.active = false,
  });

  final HermesRoomMember member;
  final double size;

  /// Whether the member is answering right now (its face bobs).
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bots = ref.watch(hermesBotsProvider).asData?.value;
    final bot = hermesRoomMemberBot(bots, member.profile);
    if (bot == null) {
      final color =
          _fallbackColors[member.profile.codeUnits.fold<int>(
                0,
                (sum, unit) => sum + unit,
              ) %
              _fallbackColors.length];
      return HermesBotAvatar(
        size: size,
        label: member.name,
        shape: 'squircle',
        color: color,
        active: active,
      );
    }
    final image = bot.hasAvatar
        ? ref.watch(hermesBotAvatarProvider(bot.name)).asData?.value
        : null;
    return HermesBotAvatar(
      size: size,
      label: bot.title,
      imageUrl: image,
      shape: bot.avatarShape,
      color: bot.avatarColor,
      imageKind: bot.avatarImageKind,
      active: active,
    );
  }
}

/// A room's picture: up to three member faces, overlapping in a square
/// of [size].
class HermesRoomAvatarStack extends StatelessWidget {
  const HermesRoomAvatarStack({
    super.key,
    required this.members,
    this.size = 32,
  });

  final List<HermesRoomMember> members;
  final double size;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(3).toList();
    if (shown.length < 2) {
      return SizedBox.square(
        dimension: size,
        child: shown.isEmpty
            ? null
            : HermesRoomMemberAvatar(member: shown.single, size: size),
      );
    }
    final face = size * (shown.length == 2 ? 0.66 : 0.56);
    final offsets = shown.length == 2
        ? [Offset.zero, Offset(size - face, size - face)]
        : [
            Offset((size - face) / 2, 0),
            Offset(0, size - face),
            Offset(size - face, size - face),
          ];
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            for (var index = 0; index < shown.length; index++)
              Positioned(
                left: offsets[index].dx,
                top: offsets[index].dy,
                child: HermesRoomMemberAvatar(
                  member: shown[index],
                  size: face,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
