import '../models/hermes_bot_group.dart';

HermesBotGroup hermesHostedRoom(
  Map<String, dynamic> room, {
  HermesBotGroup? previous,
}) {
  final id = room['room_id'];
  final name = room['name'];
  final members = room['members'];
  if (id is! String ||
      id.isEmpty ||
      name is! String ||
      members is! List ||
      members.length < 2 ||
      members.length > 6) {
    throw const FormatException('Invalid Hermes group');
  }
  final profiles = <String>[];
  for (final member in members) {
    if (member is! Map || member['profile'] is! String) {
      throw const FormatException('Invalid group member');
    }
    profiles.add(member['profile'] as String);
  }
  return HermesBotGroup(
    key: previous?.key ?? 'id:$id',
    roomId: id,
    name: name,
    memberProfiles: profiles,
    coordinator: profiles.contains(previous?.coordinator)
        ? previous!.coordinator
        : profiles.first,
    purpose: previous?.purpose ?? '',
    messages: previous?.messages ?? const [],
    memberSessions: previous?.memberSessions ?? const {},
    sharedFolder: previous?.sharedFolder,
    sharedReadOnly: previous?.sharedReadOnly ?? true,
    icon: previous?.icon ?? 'group',
    color: previous?.color ?? '#8b5cf6',
    previousRooms: previous?.previousRooms ?? const [],
    pendingTurn: previous?.pendingTurn ?? const {},
    raw: {
      ...?previous?.raw,
      'hosted': true,
      'hostedRoom': room,
      'members': [
        for (final member in members)
          {
            'name': member['profile'],
            'handle': member['handle'],
            if (member['target'] is Map && member['target']['kind'] == 'peer')
              'sourceScoped': true,
          },
      ],
    },
  );
}

/// Projects only typed room messages; control events never become user text.
HermesGroupMessage? hermesHostedRoomMessage(
  Map<String, dynamic> event,
  HermesBotGroup group,
) {
  final kind = event['kind'];
  final payload = event['payload'];
  final timestamp = event['created_at'];
  if (kind != 'message.user' && kind != 'message.member' ||
      payload is! Map ||
      payload['text'] is! String ||
      event['event_id'] is! String ||
      timestamp is! num ||
      !timestamp.isFinite) {
    return null;
  }
  String? profile;
  String speaker = 'You';
  if (kind == 'message.member') {
    final room = group.raw['hostedRoom'];
    final members = room is Map && room['members'] is List
        ? room['members'] as List
        : const [];
    for (final member in members) {
      if (member is Map && member['member_id'] == payload['member_id']) {
        profile = member['profile']?.toString();
        speaker = (member['display_name'] ?? profile ?? 'Bot').toString();
        break;
      }
    }
    // An unknown actor must not be mistaken for the human user.
    if (profile == null) return null;
  }
  return HermesGroupMessage(
    id: event['event_id'] as String,
    text: kind == 'message.user'
        ? hermesHostedUserText(payload['text'] as String)
        : payload['text'] as String,
    at: DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).round()),
    botProfile: profile,
    speaker: speaker,
  );
}

const hermesGroupEnvelopeStart =
    '<!-- conduit-group-message:v1 -->\n<message>\n';
const hermesGroupEnvelopeMiddle = '\n</message>\n<context>\n';
String hermesHostedUserText(String text) {
  final start = text.indexOf(hermesGroupEnvelopeStart);
  final end = text.lastIndexOf(hermesGroupEnvelopeMiddle);
  if (start >= 0 &&
      end >= start + hermesGroupEnvelopeStart.length &&
      text.endsWith('\n</context>')) {
    return text.substring(start + hermesGroupEnvelopeStart.length, end);
  }
  return text;
}
