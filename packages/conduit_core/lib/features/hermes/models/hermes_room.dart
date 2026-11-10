import 'dart:convert';

import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/utils/hermes_time_parsing.dart';

const int kMaxHermesRoomNameCharacters = 256;
const int kMaxHermesRoomMembers = 64;

/// The longest room name Hermes takes.
const int kMaxHermesRoomNameInput = 200;

/// Hermes seats two to six bots in a Group Chat.
const int kMinHermesRoomSeats = 2;
const int kMaxHermesRoomSeats = 6;

/// Hermes' caps on a room's purpose (characters) and notes (UTF-8 bytes).
const int kMaxHermesRoomPurposeCharacters = 500;
const int kMaxHermesRoomNotesBytes = 4096;

/// Hermes' cap on a member label in the room log.
const int kMaxHermesRoomMemberLabelCharacters = 200;

/// One bot seated in a room: a `groups.*` roster row.
class HermesRoomMember {
  const HermesRoomMember({
    required this.memberId,
    required this.profile,
    required this.handle,
    this.displayName,
  });

  /// A local bot as `groups.create` seats it: the profile is its id and
  /// its @handle, and its title its label.
  factory HermesRoomMember.forBot(HermesBot bot) {
    final title = bot.title.trim();
    return HermesRoomMember(
      memberId: bot.name,
      profile: bot.name,
      handle: bot.name,
      displayName: title.isEmpty || title == bot.name
          ? null
          : title.length > kMaxHermesRoomMemberLabelCharacters
          ? title.substring(0, kMaxHermesRoomMemberLabelCharacters)
          : title,
    );
  }

  final String memberId;
  final String profile;

  /// The name an @mention addresses the member by.
  final String handle;
  final String? displayName;

  /// What the room calls the member.
  String get name => displayName ?? handle;

  static HermesRoomMember? fromJson(Object? json) {
    if (json is! Map) return null;
    final memberId = validateHermesOpaqueIdentifier(json['member_id']);
    final profile = validateHermesOpaqueIdentifier(json['profile']);
    if (memberId == null || profile == null) return null;
    return HermesRoomMember(
      memberId: memberId,
      profile: profile,
      handle: validateHermesOpaqueIdentifier(json['handle']) ?? profile,
      displayName: validateHermesBoundedString(
        json['display_name'],
        maxCharacters: kMaxHermesRoomMemberLabelCharacters,
      ),
    );
  }

  /// The roster row `groups.create` takes for a bot on this gateway.
  Map<String, Object?> toCreateJson() => {
    'member_id': memberId,
    'profile': profile,
    'handle': handle,
    'target': {'kind': 'local', 'profile': profile},
    'display_name': ?displayName,
  };
}

/// A Bot Mode Group Chat hosted by a Hermes gateway: one `groups.list` row.
class HermesRoom {
  const HermesRoom({
    required this.id,
    required this.name,
    this.memberProfiles = const [],
    this.members = const [],
    this.updatedAt,
    this.disbanded = false,
    this.latestSeq,
    this.authorityEpoch,
  });

  final String id;

  /// The room's name, falling back to its id.
  final String name;

  /// Profiles of the bots in the room, in roster order.
  final List<String> memberProfiles;

  /// The bots in the room, in roster order.
  final List<HermesRoomMember> members;
  final DateTime? updatedAt;

  /// Whether the room was disbanded (its id stays tombstoned).
  final bool disbanded;

  /// The newest event in the room's log, when Hermes said.
  final int? latestSeq;

  /// Which run of the room's owning gateway wrote the log; a new one
  /// starts the log again.
  final int? authorityEpoch;

  HermesRoomMember? member(String? memberId) {
    if (memberId == null) return null;
    for (final member in members) {
      if (member.memberId == memberId) return member;
    }
    return null;
  }

  static HermesRoom? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = validateHermesOpaqueIdentifier(json['room_id']);
    if (id == null) return null;
    final profiles = <String>[];
    final members = <HermesRoomMember>[];
    final rows = json['members'];
    if (rows is List) {
      for (final row in rows.take(kMaxHermesRoomMembers)) {
        if (row is! Map) continue;
        final profile = validateHermesOpaqueIdentifier(row['profile']);
        if (profile != null && !profiles.contains(profile)) {
          profiles.add(profile);
        }
        final member = HermesRoomMember.fromJson(row);
        if (member != null &&
            members.every((m) => m.memberId != member.memberId)) {
          members.add(member);
        }
      }
    }
    final latest = json['latest_seq'];
    final epoch = json['authority_epoch'];
    return HermesRoom(
      id: id,
      name:
          validateHermesBoundedString(
            json['name'],
            maxCharacters: kMaxHermesRoomNameCharacters,
          ) ??
          id,
      memberProfiles: List.unmodifiable(profiles),
      members: List.unmodifiable(members),
      updatedAt: parseHermesTimestamp(json['updated_at']),
      disbanded: json['disbanded_at'] != null,
      latestSeq: latest is int && latest >= 0 ? latest : null,
      authorityEpoch: epoch is int && epoch >= 1 ? epoch : null,
    );
  }
}

/// Who answers a message that names nobody.
enum HermesRoomRouting {
  /// Every member takes a turn (Hermes' default).
  everyone,

  /// The lead bot decides who takes it.
  lead,

  /// A quick model call picks who the message is for.
  auto;

  static HermesRoomRouting? parse(Object? value) => switch (value) {
    'everyone' => everyone,
    'lead' => lead,
    'auto' => auto,
    _ => null,
  };
}

/// A room's purpose, shared notes, and routing (`groups.state.context`).
class HermesRoomContext {
  const HermesRoomContext({
    this.purpose = '',
    this.notes = '',
    this.routing,
    this.leadMemberId,
  });

  final String purpose;
  final String notes;

  /// Null on a Hermes without routing (before 0.22.7), which answers as
  /// [HermesRoomRouting.everyone] and takes no routing in a save.
  final HermesRoomRouting? routing;

  /// The lead bot, when [routing] is [HermesRoomRouting.lead].
  final String? leadMemberId;

  static HermesRoomContext? fromJson(Object? json) {
    if (json is! Map) return null;
    final routing = HermesRoomRouting.parse(json['routing']);
    final lead = validateHermesOpaqueIdentifier(json['lead_member_id']);
    return HermesRoomContext(
      purpose:
          validateHermesBoundedString(
            json['purpose'],
            maxCharacters: kMaxHermesRoomPurposeCharacters * 2,
          ) ??
          '',
      notes:
          validateHermesBoundedString(
            json['notes'],
            maxCharacters: kMaxHermesRoomNotesBytes * 2,
          ) ??
          '',
      routing: routing,
      leadMemberId: routing == HermesRoomRouting.lead ? lead : null,
    );
  }
}

/// The UTF-8 size Hermes measures room notes by, after trimming.
int hermesRoomNotesBytes(String notes) => utf8.encode(notes.trim()).length;
