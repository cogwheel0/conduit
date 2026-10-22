import 'package:test/test.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/services/hermes_hosted_group_projection.dart';

void main() {
  final room = <String, dynamic>{
    'room_id': 'team',
    'name': 'Team',
    'members': [
      {
        'member_id': 'research',
        'profile': 'research',
        'handle': 'research',
        'display_name': 'Researcher',
      },
      {
        'member_id': 'code',
        'profile': 'code',
        'handle': 'code',
        'display_name': 'Coding',
      },
    ],
  };
  Map<String, dynamic> event(String kind, {String member = 'research'}) => {
    'event_id': 'event-1',
    'kind': kind,
    'created_at': 1234,
    'payload': {'text': 'A reply', 'member_id': member},
  };
  test(
    'hosted projection retains profile-owned options and full local history',
    () {
      final old = HermesBotGroup(
        key: 'id:team',
        roomId: 'team',
        name: 'Old name',
        memberProfiles: const ['research', 'code'],
        coordinator: 'code',
        purpose: 'Research a topic',
        sharedFolder: '/team/files',
        sharedReadOnly: true,
        icon: 'research',
        color: '#5bbf98',
        messages: [
          HermesGroupMessage(id: 'old', text: 'Retained', at: DateTime(2026)),
        ],
      );
      final group = hermesHostedRoom(room, previous: old);
      expect(group.name, 'Team');
      expect(group.coordinator, 'code');
      expect(group.messages.single.text, 'Retained');
      expect(group.sharedFolder, '/team/files');
      expect(group.icon, 'research');
      expect(group.color, '#5bbf98');
      expect(group.hasScopedMembers, false);
      expect(group.raw['hosted'], true);
    },
  );
  test('typed member messages retain their actor; unknown actors cannot become user messages', () {
    final group = hermesHostedRoom(room);
    final message = hermesHostedRoomMessage(event('message.member'), group)!;
    expect(message.botProfile, 'research');
    expect(message.speaker, 'Researcher');
    expect(message.isUser, false);
    expect(
      hermesHostedRoomMessage(
        event('message.member', member: 'other-gateway'),
        group,
      ),
      isNull,
    );
  });
  test('native human messages show the draft without routing instructions', () {
    final text='@research\n${hermesGroupEnvelopeStart}Find the article${hermesGroupEnvelopeMiddle}Internal coordination instructions\n</context>';
    final result=hermesHostedRoomMessage({...event('message.user'),'payload':{'text':text}},hermesHostedRoom(room))!;
    expect(result.text,'Find the article');
    expect(hermesHostedUserText('A normal external message'),'A normal external message');
  });
  test('control events never become conversation content', () {
    final group = hermesHostedRoom(room);
    expect(hermesHostedRoomMessage(event('turn.failed'), group), isNull);
    expect(hermesHostedRoomMessage(event('message.user'), group)!.isUser, true);
  });
  test('malformed rosters are refused', () {
    expect(
      () => hermesHostedRoom({...room, 'members': []}),
      throwsFormatException,
    );
    expect(
      () => hermesHostedRoom({...room, 'room_id': ''}),
      throwsFormatException,
    );
  });
  test('pending recovery receipts survive metadata round trip separately from identity', () {
    final group = HermesBotGroup(
      key: 'id:team',
      roomId: 'team',
      name: 'Team',
      memberProfiles: const ['research', 'code'],
      coordinator: 'code',
      pendingTurn: const {
        'profile': 'code',
        'session': 'member-session',
        'replyId': 'reply-1',
        'promptLength': 500,
        'promptHash': 'hash',
      },
    );
    final restored = HermesBotGroup.fromJson(
      group.key,
      group.roomJson(),
      group.optionsJson(),
    )!;
    expect(restored.pendingTurn, group.pendingTurn);
    expect(restored.memberProfiles, group.memberProfiles);
  });
}
