import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/utils/hermes_time_parsing.dart';

const int kMaxHermesRoomNameCharacters = 256;
const int kMaxHermesRoomMembers = 64;

/// A Bot Mode Group Chat hosted by a Hermes gateway: one `groups.list` row.
class HermesRoom {
  const HermesRoom({
    required this.id,
    required this.name,
    this.memberProfiles = const [],
    this.updatedAt,
    this.disbanded = false,
  });

  final String id;

  /// The room's name, falling back to its id.
  final String name;

  /// Profiles of the bots in the room, in roster order.
  final List<String> memberProfiles;
  final DateTime? updatedAt;

  /// Whether the room was disbanded (its id stays tombstoned).
  final bool disbanded;

  static HermesRoom? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = validateHermesOpaqueIdentifier(json['room_id']);
    if (id == null) return null;
    final members = <String>[];
    final rows = json['members'];
    if (rows is List) {
      for (final row in rows.take(kMaxHermesRoomMembers)) {
        if (row is! Map) continue;
        final profile = validateHermesOpaqueIdentifier(row['profile']);
        if (profile != null && !members.contains(profile)) {
          members.add(profile);
        }
      }
    }
    return HermesRoom(
      id: id,
      name:
          validateHermesBoundedString(
            json['name'],
            maxCharacters: kMaxHermesRoomNameCharacters,
          ) ??
          id,
      memberProfiles: List.unmodifiable(members),
      updatedAt: parseHermesTimestamp(json['updated_at']),
      disbanded: json['disbanded_at'] != null,
    );
  }
}
