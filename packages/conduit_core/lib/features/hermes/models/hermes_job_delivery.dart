import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

/// Hermes' "save only" target: the run is kept in Hermes and sent nowhere.
const String kHermesLocalDeliveryTarget = 'local';

const String _botChatToken = 'bot-chat';
const String _roomPrefix = 'room:';
const int _maxDeliveryTargets = 64;
const int _maxDeliveryNameCharacters = 256;

// `cron/scheduler_delivery_room.py` `_ROOM_TOKEN_RE`: a room id, then the
// profile whose gateway hosts the room.
final RegExp _roomIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$');
final RegExp _roomProfilePattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// What a single delivery target sends to.
enum HermesDeliveryKind {
  /// Saved in Hermes only.
  local,

  /// A messaging platform's home channel (`telegram`, `discord`, …).
  platform,

  /// A bot's Bot Chat (`bot-chat:<profile>`).
  botChat,

  /// A Group Chat (`room:<room_id>@<profile>`); wakes only @mentioned bots.
  room,

  /// Anything else (`origin`, `all`, `telegram:<chat>`, …), shown as stored.
  other,
}

/// The targets in a `deliver` value, a comma-separated list. Empty means
/// `local`, as Hermes reads it.
List<String> parseHermesDeliveryTargets(String? value) {
  final targets = <String>[];
  for (final part in (value ?? '').split(',')) {
    final target = part.trim();
    if (target.isEmpty || targets.contains(target)) continue;
    targets.add(target);
    if (targets.length >= _maxDeliveryTargets) break;
  }
  return targets.isEmpty ? const [kHermesLocalDeliveryTarget] : targets;
}

/// [value] with [target] selected or not. The last target cannot be cleared:
/// a job always delivers somewhere.
String toggleHermesDeliveryTarget(
  String? value,
  String target, {
  required bool selected,
}) {
  final targets = [...parseHermesDeliveryTargets(value)];
  if (selected) {
    if (!targets.contains(target)) targets.add(target);
  } else if (targets.length > 1) {
    targets.remove(target);
  }
  return targets.join(',');
}

/// Whether two `deliver` values name the same targets, in any order.
bool hermesDeliveryTargetsMatch(String? left, String? right) {
  final a = parseHermesDeliveryTargets(left);
  final b = parseHermesDeliveryTargets(right);
  return a.length == b.length && a.toSet().containsAll(b);
}

HermesDeliveryKind hermesDeliveryKind(String target) {
  final lowered = target.trim().toLowerCase();
  if (lowered == kHermesLocalDeliveryTarget) return HermesDeliveryKind.local;
  if (hermesBotChatProfile(target) != null) return HermesDeliveryKind.botChat;
  if (lowered.startsWith(_roomPrefix)) return HermesDeliveryKind.room;
  if (RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(lowered)) {
    return const {'origin', 'all'}.contains(lowered)
        ? HermesDeliveryKind.other
        : HermesDeliveryKind.platform;
  }
  return HermesDeliveryKind.other;
}

/// The profile of a `bot-chat[:<profile>]` target: empty for the job's own
/// profile, null when [target] is not a Bot Chat target.
String? hermesBotChatProfile(String target) {
  final raw = target.trim();
  final lowered = raw.toLowerCase();
  if (lowered == _botChatToken) return '';
  if (!lowered.startsWith('$_botChatToken:')) return null;
  return raw.substring(_botChatToken.length + 1).trim();
}

/// The room id and hosting profile of a `room:<room_id>[@<profile>]` target,
/// or null when [target] is not a well-formed room target.
({String roomId, String? profile})? hermesRoomDeliveryAddress(String target) {
  final raw = target.trim();
  if (!raw.toLowerCase().startsWith(_roomPrefix)) return null;
  final address = raw.substring(_roomPrefix.length).trim();
  final at = address.lastIndexOf('@');
  final roomId = at < 0 ? address : address.substring(0, at);
  final profile = at < 0 ? null : address.substring(at + 1);
  if (!_roomIdPattern.hasMatch(roomId) ||
      (profile != null && !_roomProfilePattern.hasMatch(profile))) {
    return null;
  }
  return (roomId: roomId, profile: profile);
}

String hermesBotChatDeliveryTarget(String profile) => '$_botChatToken:$profile';

/// A room target naming [profile], the profile whose gateway hosts the room;
/// null when either part would make a malformed target.
String? hermesRoomDeliveryTarget(String roomId, String profile) {
  if (!_roomIdPattern.hasMatch(roomId) ||
      !_roomProfilePattern.hasMatch(profile)) {
    return null;
  }
  return '$_roomPrefix$roomId@$profile';
}

/// One target a job can deliver to.
class HermesDeliveryOption {
  const HermesDeliveryOption({
    required this.target,
    required this.kind,
    required this.name,
    this.available = true,
  });

  /// The `deliver` token.
  final String target;
  final HermesDeliveryKind kind;

  /// Display name without the kind: a platform's, bot's, or room's name, the
  /// target itself for [HermesDeliveryKind.other], empty for local.
  final String name;

  /// False for a platform without a home channel: Hermes has nowhere to send.
  final bool available;
}

/// The targets a connection offers, in display order: local, platforms, Bot
/// Chats, then Group Chats.
class HermesDeliveryOptions {
  const HermesDeliveryOptions(this.options);

  /// Only local: what Conduit can offer when Hermes lists no targets.
  static const localOnly = HermesDeliveryOptions([
    HermesDeliveryOption(
      target: kHermesLocalDeliveryTarget,
      kind: HermesDeliveryKind.local,
      name: '',
    ),
  ]);

  final List<HermesDeliveryOption> options;

  HermesDeliveryOption? optionFor(String target) {
    for (final option in options) {
      if (option.target == target) return option;
    }
    return null;
  }

  /// [options] followed by every selected target they do not list, so that
  /// editing a job never drops a saved route.
  List<HermesDeliveryOption> withSelected(Iterable<String> selected) => [
    ...options,
    for (final target in selected)
      if (optionFor(target) == null) describeHermesDeliveryTarget(target),
  ];

  /// Combines `GET /api/cron/delivery-targets` rows, the Bot Mode roster, and
  /// the gateway's Group Chats. [roomProfile] is the connection's profile,
  /// whose gateway hosts the listed rooms.
  static HermesDeliveryOptions build({
    required List<Map<String, dynamic>> targets,
    List<HermesBot> bots = const [],
    List<HermesRoom> rooms = const [],
    required String roomProfile,
  }) {
    final botTitles = {for (final bot in bots) bot.name: bot.title};
    final platforms = <HermesDeliveryOption>[];
    final botChats = <HermesDeliveryOption>[];
    final seen = <String>{kHermesLocalDeliveryTarget};

    for (final row in targets.take(256)) {
      final target = validateHermesBoundedString(
        row['id'],
        maxCharacters: _maxDeliveryNameCharacters,
      );
      if (target == null || target.contains(',') || !seen.add(target)) {
        continue;
      }
      final name = validateHermesBoundedString(
        row['name'],
        maxCharacters: _maxDeliveryNameCharacters,
      );
      switch (hermesDeliveryKind(target)) {
        case HermesDeliveryKind.botChat:
          final profile = hermesBotChatProfile(target) ?? '';
          botChats.add(
            HermesDeliveryOption(
              target: target,
              kind: HermesDeliveryKind.botChat,
              name: botTitles[profile] ?? (profile.isEmpty ? target : profile),
            ),
          );
        case HermesDeliveryKind.platform:
          platforms.add(
            HermesDeliveryOption(
              target: target,
              kind: HermesDeliveryKind.platform,
              name: name ?? target,
              available: row['home_target_set'] != false,
            ),
          );
        case HermesDeliveryKind.local:
        case HermesDeliveryKind.room:
        case HermesDeliveryKind.other:
          break;
      }
    }

    // A server whose target list predates Bot Chat entries still lists bots.
    for (final bot in bots) {
      final target = hermesBotChatDeliveryTarget(bot.name);
      if (!seen.add(target)) continue;
      botChats.add(
        HermesDeliveryOption(
          target: target,
          kind: HermesDeliveryKind.botChat,
          name: bot.title,
        ),
      );
    }

    final roomOptions = <HermesDeliveryOption>[];
    for (final room in rooms) {
      if (room.disbanded) continue;
      final target = hermesRoomDeliveryTarget(room.id, roomProfile);
      if (target == null || !seen.add(target)) continue;
      roomOptions.add(
        HermesDeliveryOption(
          target: target,
          kind: HermesDeliveryKind.room,
          name: room.name,
        ),
      );
    }

    return HermesDeliveryOptions([
      ...localOnly.options,
      ...platforms,
      ...botChats,
      ...roomOptions,
    ]);
  }
}

/// A best-effort option for a target no list describes: its kind, and the
/// name its token carries.
HermesDeliveryOption describeHermesDeliveryTarget(String target) {
  final kind = hermesDeliveryKind(target);
  final name = switch (kind) {
    HermesDeliveryKind.local => '',
    HermesDeliveryKind.botChat => switch (hermesBotChatProfile(target)) {
      final profile? when profile.isNotEmpty => profile,
      _ => target,
    },
    HermesDeliveryKind.room =>
      hermesRoomDeliveryAddress(target)?.roomId ?? target,
    HermesDeliveryKind.platform || HermesDeliveryKind.other => target,
  };
  // A malformed room token stays as stored rather than looking valid.
  final effectiveKind =
      kind == HermesDeliveryKind.room &&
          hermesRoomDeliveryAddress(target) == null
      ? HermesDeliveryKind.other
      : kind;
  return HermesDeliveryOption(target: target, kind: effectiveKind, name: name);
}
