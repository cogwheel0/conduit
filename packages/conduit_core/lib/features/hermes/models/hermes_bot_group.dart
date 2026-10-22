import 'package:conduit_core/features/hermes/models/hermes_bot.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

const hermesGroupsNamespace = 'hermes-bots-groups';
const conduitGroupOptionsNamespace = 'conduit-group-options';

class HermesGroupMessage {
  const HermesGroupMessage({
    required this.id,
    required this.text,
    required this.at,
    this.botProfile,
    this.speaker = 'You',
    this.toolUpdates = const [],
  });
  final String id;
  final String text;
  final DateTime at;
  final String? botProfile;
  final String speaker;
  final List<ChatStatusUpdate> toolUpdates;
  bool get isUser => botProfile == null;
  Map<String, dynamic> toJson({bool includeTools = true}) => {
    'id': id,
    'text': text,
    'at': at.millisecondsSinceEpoch,
    'from': {
      'kind': isUser ? 'user' : 'member',
      'name': speaker,
      if (botProfile != null) 'source': botProfile,
    },
    if (includeTools && toolUpdates.isNotEmpty)
      'toolUpdates': toolUpdates.map((update) => update.toJson()).toList(),
  };
  static HermesGroupMessage? fromJson(
    Map<String, dynamic> json, {
    int maxTextCharacters = 48000,
  }) {
    final text = validateHermesBoundedString(
      json['text'],
      maxCharacters: maxTextCharacters,
      trim: false,
      allowEmpty: true,
    );
    final at = json['at'];
    if (text == null ||
        at is! num ||
        !at.isFinite ||
        at.abs() > 8640000000000000) {
      return null;
    }
    final from = json['from'] is Map ? json['from'] as Map : const {};
    final speaker =
        validateHermesBoundedString(from['name'], maxCharacters: 128) ?? 'Bot';
    final member = from['kind'] == 'member';
    final source = validateHermesBoundedString(
      from['source'],
      maxCharacters: 128,
    );
    return HermesGroupMessage(
      id:
          validateHermesOpaqueIdentifier(json['id']) ??
          'legacy-${sha256.convert(utf8.encode(jsonEncode([at, speaker, source, text])))}',
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      botProfile: member ? source ?? speaker : null,
      speaker: member ? speaker : 'You',
      toolUpdates: [
        if (json['toolUpdates'] is List)
          for (final row in (json['toolUpdates'] as List).take(200))
            if (row is Map)
              ChatStatusUpdate.fromJson(Map<String, dynamic>.from(row)),
      ],
    );
  }
}

class HermesBotGroup {
  const HermesBotGroup({
    required this.key,
    required this.name,
    required this.memberProfiles,
    this.roomId,
    this.coordinator,
    this.purpose = '',
    this.messages = const [],
    this.memberSessions = const {},
    this.omitted = 0,
    this.raw = const {},
    this.sharedFolder,
    this.sharedReadOnly = true,
    this.icon = 'group',
    this.color = '#8b5cf6',
    this.pendingTurn = const {},
    this.previousRooms = const [],
  });
  final String key;
  final String? roomId;
  final String name;
  final List<String> memberProfiles;
  final String? coordinator;
  final String purpose;
  final List<HermesGroupMessage> messages;
  final Map<String, String> memberSessions;
  final int omitted;
  final Map<String, dynamic> raw;
  final String? sharedFolder;
  final bool sharedReadOnly;
  final String icon, color;
  final Map<String, dynamic> pendingTurn;
  final List<Map<String, dynamic>> previousRooms;
  DateTime? get lastActive {
    final room = raw['hostedRoom'];
    final time = room is Map ? room['updated_at'] : null;
    final native = time is num && time.isFinite
        ? DateTime.fromMillisecondsSinceEpoch((time * 1000).round())
        : null;
    final local = messages.isEmpty ? null : messages.last.at;
    return native != null && (local == null || native.isAfter(local))
        ? native
        : local;
  }

  String get identity => roomId ?? key;
  bool get hasScopedMembers =>
      raw['members'] is List &&
      (raw['members'] as List).any(
        (member) =>
            member is Map &&
            (member['sourceScoped'] == true ||
                member['connectionId'] is String &&
                    (member['connectionId'] as String).isNotEmpty),
      );
  HermesBotGroup copyWith({
    String? key,
    String? roomId,
    List<Map<String, dynamic>>? previousRooms,
    List<HermesGroupMessage>? messages,
    Map<String, String>? memberSessions,
    String? name,
    List<String>? memberProfiles,
    String? coordinator,
    bool clearCoordinator = false,
    String? purpose,
    int? omitted,
    Map<String, dynamic>? raw,
    String? sharedFolder,
    bool? sharedReadOnly,
    String? icon,
    String? color,
    Map<String, dynamic>? pendingTurn,
  }) => HermesBotGroup(
    key: key ?? this.key,
    roomId: roomId ?? this.roomId,
    previousRooms: previousRooms ?? this.previousRooms,
    name: name ?? this.name,
    memberProfiles: memberProfiles ?? this.memberProfiles,
    coordinator: clearCoordinator ? null : coordinator ?? this.coordinator,
    purpose: purpose ?? this.purpose,
    messages: messages ?? this.messages,
    memberSessions: memberSessions ?? this.memberSessions,
    omitted: omitted ?? this.omitted,
    raw: raw ?? this.raw,
    sharedFolder: sharedFolder ?? this.sharedFolder,
    sharedReadOnly: sharedReadOnly ?? this.sharedReadOnly,
    icon: icon ?? this.icon,
    color: color ?? this.color,
    pendingTurn: pendingTurn ?? this.pendingTurn,
  );
  static HermesBotGroup? fromJson(
    String key,
    Map<String, dynamic> json,
    Map<String, dynamic> options,
  ) {
    final name =
        validateHermesBoundedString(json['name'], maxCharacters: 64) ??
        key.replaceFirst(RegExp(r'^name:'), '');
    if (name.length > 128 || json['members'] is! List) return null;
    final profiles = <String>[];
    for (final member in (json['members'] as List).take(6)) {
      if (member is! Map) continue;
      final handle = member['handle'];
      final candidate = handle is String
          ? handle.replaceFirst('@', '')
          : member['name'];
      if (candidate is String &&
          HermesConfig.isValidDesktopProfile(candidate)) {
        profiles.add(candidate);
      }
    }
    final log = json['log'];
    final messages = <HermesGroupMessage>[];
    if (log is List) {
      for (final row in log.take(10000)) {
        if (row is Map) {
          final message = HermesGroupMessage.fromJson(
            Map<String, dynamic>.from(row),
          );
          if (message != null) messages.add(message);
        }
      }
    }
    final sessions = <String, String>{};
    if (options['sessions'] is Map) {
      for (final entry in (options['sessions'] as Map).entries) {
        final id = validateHermesOpaqueIdentifier(entry.value);
        if (entry.key is String && profiles.contains(entry.key) && id != null) {
          sessions[entry.key] = id;
        }
      }
    }
    final coordinator = options['coordinator'];
    return HermesBotGroup(
      key: key,
      roomId: validateHermesOpaqueIdentifier(json['roomId']),
      name: name,
      memberProfiles: profiles.toSet().toList(),
      coordinator: coordinator is String && profiles.contains(coordinator)
          ? coordinator
          : null,
      purpose:
          validateHermesBoundedString(
            options['purpose'],
            maxCharacters: 5000,
          ) ??
          '',
      messages: messages,
      memberSessions: sessions,
      omitted: json['omitted'] is int ? json['omitted'] as int : 0,
      raw: json,
      previousRooms: [
        if (options['previousRooms'] is List)
          for (final room in (options['previousRooms'] as List).take(32))
            if (room is Map &&
                validateHermesOpaqueIdentifier(room['room_id']) != null &&
                room['members'] is List)
              Map<String, dynamic>.from(room),
      ],
      pendingTurn:
          options['pendingTurn'] is Map &&
              jsonEncode(options['pendingTurn']).length < 4096
          ? Map<String, dynamic>.from(options['pendingTurn'])
          : const {},
      sharedFolder: validateHermesBoundedString(
        options['sharedFolder'],
        maxCharacters: 4096,
      ),
      sharedReadOnly: options['sharedReadOnly'] != false,
      icon:
          validateHermesBoundedString(options['icon'], maxCharacters: 32) ??
          'group',
      color:
          options['color'] is String &&
              RegExp(r'^#[a-fA-F0-9]{6}$').hasMatch(options['color'])
          ? options['color'] as String
          : '#8b5cf6',
    );
  }

  Map<String, dynamic> roomJson() => {
    ...raw,
    'name': name,
    if (roomId != null) 'roomId': roomId,
    'members': [for (final profile in memberProfiles) _memberJson(profile)],
    'log': messages.map((m) => m.toJson(includeTools: false)).toList(),
    'holdDetection': raw['holdDetection'] != false,
  };
  Map<String, dynamic> _memberJson(String profile) {
    final members = raw['members'];
    if (members is List) {
      for (final member in members) {
        if (member is Map &&
            (member['name'] == profile ||
                member['handle'] == profile ||
                member['handle'] == '@$profile')) {
          return Map<String, dynamic>.from(member);
        }
      }
    }
    return {'name': profile, 'handle': profile};
  }

  Map<String, dynamic> optionsJson() => {
    'previousRooms': previousRooms,
    'purpose': purpose,
    'coordinator': coordinator,
    'sessions': memberSessions,
    'sharedFolder': sharedFolder,
    'sharedReadOnly': sharedReadOnly,
    'icon': icon,
    'color': color,
    if (pendingTurn.isNotEmpty) 'pendingTurn': pendingTurn,
  };
}

class HermesBotDraft {
  const HermesBotDraft({
    required this.profile,
    required this.title,
    required this.description,
    required this.instructions,
    this.cloneFrom,
    this.shareAuth = false,
    this.model,
    this.provider,
    this.disabledSkills,
    this.toolsets,
    this.mcpServers,
    this.role,
  });
  final String profile, title, description, instructions;
  final String? cloneFrom, model, provider;
  final bool shareAuth;
  final List<String>? disabledSkills;
  final List<String>? toolsets;
  final List<String>? mcpServers;

  /// Optional creation-form title. The roster title falls back to the name;
  /// an explicitly empty role omits the optional Role line in the persona.
  final String? role;

  /// Matches the desktop's Bot Mode template. The current bot protocol owns
  /// agent messaging, so older CLI handoff instructions do not belong here.
  String get soul {
    final custom = instructions.trim();
    if (custom.isNotEmpty) return custom;
    final display = title.trim();
    final mission = description.trim();
    final roleTitle = (role ?? title).trim();
    return [
      '# $display',
      '',
      if (roleTitle.isNotEmpty) '**Role:** $roleTitle',
      if (mission.isNotEmpty) '**Mission:** $mission',
      '',
      'You are $display, a persistent named agent (profile `$profile`) on this machine.',
      'You keep your own memory, skills, and conversation history across sessions.',
    ].join('\n');
  }

  void validate() {
    if (!HermesConfig.isValidDesktopProfile(profile) ||
        profile == 'default' ||
        title.trim().isEmpty ||
        title.length > kMaxHermesBotTitleCharacters ||
        description.length > 5000 ||
        instructions.length > 16000 ||
        (role != null && role!.length > kMaxHermesBotTitleCharacters) ||
        (cloneFrom != null &&
            !HermesConfig.isValidDesktopProfile(cloneFrom!))) {
      throw ArgumentError('Invalid bot profile');
    }
  }
}

class HermesBotSetupIncomplete implements Exception {
  const HermesBotSetupIncomplete(this.profile);
  final String profile;
}
