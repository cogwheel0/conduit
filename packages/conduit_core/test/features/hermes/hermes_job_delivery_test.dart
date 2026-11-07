import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:test/test.dart';

void main() {
  group('deliver value', () {
    test('splits, trims, and de-duplicates targets', () {
      check(parseHermesDeliveryTargets(' local, telegram ,local,'))
          .deepEquals(['local', 'telegram']);
      check(parseHermesDeliveryTargets(null)).deepEquals(['local']);
      check(parseHermesDeliveryTargets(' , ')).deepEquals(['local']);
    });

    test('toggling never clears the last target', () {
      check(toggleHermesDeliveryTarget('local', 'slack', selected: true))
          .equals('local,slack');
      check(toggleHermesDeliveryTarget('local,slack', 'local', selected: false))
          .equals('slack');
      check(toggleHermesDeliveryTarget('slack', 'slack', selected: false))
          .equals('slack');
      check(toggleHermesDeliveryTarget('slack', 'slack', selected: true))
          .equals('slack');
    });

    test('matches the same targets in any order', () {
      check(hermesDeliveryTargetsMatch('local,slack', 'slack, local')).isTrue();
      check(hermesDeliveryTargetsMatch(null, 'local')).isTrue();
      check(hermesDeliveryTargetsMatch('local', 'local,slack')).isFalse();
    });
  });

  group('target kinds', () {
    test('classifies each kind of token', () {
      check(hermesDeliveryKind('local')).equals(HermesDeliveryKind.local);
      check(hermesDeliveryKind('telegram'))
          .equals(HermesDeliveryKind.platform);
      check(hermesDeliveryKind('bot-chat:research'))
          .equals(HermesDeliveryKind.botChat);
      check(hermesDeliveryKind('bot-chat')).equals(HermesDeliveryKind.botChat);
      check(hermesDeliveryKind('room:r1@ops')).equals(HermesDeliveryKind.room);
      check(hermesDeliveryKind('origin')).equals(HermesDeliveryKind.other);
      check(hermesDeliveryKind('all')).equals(HermesDeliveryKind.other);
      check(hermesDeliveryKind('telegram:-1001:7'))
          .equals(HermesDeliveryKind.other);
    });

    test('reads a room address and its hosting profile', () {
      check(hermesRoomDeliveryAddress('room:standup.2@ops')).isNotNull()
        ..has((a) => a.roomId, 'roomId').equals('standup.2')
        ..has((a) => a.profile, 'profile').equals('ops');
      check(hermesRoomDeliveryAddress('room:standup')).isNotNull()
          .has((a) => a.profile, 'profile')
          .isNull();
      check(hermesRoomDeliveryAddress('room:@ops')).isNull();
      check(hermesRoomDeliveryAddress('room:a b@ops')).isNull();
      check(hermesRoomDeliveryAddress('local')).isNull();
    });

    test('builds only well-formed room targets', () {
      check(hermesRoomDeliveryTarget('standup', 'ops'))
          .equals('room:standup@ops');
      check(hermesRoomDeliveryTarget('bad id', 'ops')).isNull();
      check(hermesRoomDeliveryTarget('standup', 'o/ps')).isNull();
      check(hermesBotChatDeliveryTarget('research'))
          .equals('bot-chat:research');
    });

    test('describes targets no list knows', () {
      check(describeHermesDeliveryTarget('bot-chat:research'))
        ..has((o) => o.kind, 'kind').equals(HermesDeliveryKind.botChat)
        ..has((o) => o.name, 'name').equals('research');
      check(describeHermesDeliveryTarget('room:standup@ops'))
        ..has((o) => o.kind, 'kind').equals(HermesDeliveryKind.room)
        ..has((o) => o.name, 'name').equals('standup');
      check(describeHermesDeliveryTarget('room:not valid'))
        ..has((o) => o.kind, 'kind').equals(HermesDeliveryKind.other)
        ..has((o) => o.name, 'name').equals('room:not valid');
      check(describeHermesDeliveryTarget('origin').kind)
          .equals(HermesDeliveryKind.other);
    });
  });

  group('options', () {
    final options = HermesDeliveryOptions.build(
      targets: [
        {'id': 'local', 'name': 'Local (save only)', 'home_target_set': true},
        {'id': 'telegram', 'name': 'Telegram', 'home_target_set': true},
        {
          'id': 'discord',
          'name': 'Discord',
          'home_target_set': false,
          'home_env_var': 'DISCORD_HOME_CHANNEL',
        },
        {'id': 'bot-chat:research', 'name': 'Bot Chat (research)'},
        {'id': 'bot-chat:default', 'name': 'Bot Chat (default)'},
        {'id': 'a,b', 'name': 'Broken'},
        {'id': 42},
      ],
      bots: const [
        HermesBot(name: 'research', title: 'Research'),
        HermesBot(name: 'scout', title: 'Scout'),
      ],
      rooms: const [
        HermesRoom(id: 'standup', name: 'Daily standup'),
        HermesRoom(id: 'old', name: 'Old room', disbanded: true),
        HermesRoom(id: 'has space', name: 'Malformed'),
      ],
      roomProfile: 'ops',
    );

    test('order local, platforms, Bot Chats, then Group Chats', () {
      check(options.options.map((o) => o.target).toList()).deepEquals([
        'local',
        'telegram',
        'discord',
        'bot-chat:research',
        'bot-chat:default',
        'bot-chat:scout',
        'room:standup@ops',
      ]);
    });

    test('a platform without a home channel is unavailable', () {
      check(options.optionFor('telegram')!.available).isTrue();
      check(options.optionFor('discord')!.available).isFalse();
      check(options.optionFor('discord')!.name).equals('Discord');
    });

    test('Bot Chats carry the bot title, else the profile', () {
      check(options.optionFor('bot-chat:research')!.name).equals('Research');
      check(options.optionFor('bot-chat:default')!.name).equals('default');
      check(options.optionFor('bot-chat:scout')!.name).equals('Scout');
    });

    test('rooms are addressed through the connection profile', () {
      check(options.optionFor('room:standup@ops')!)
        ..has((o) => o.kind, 'kind').equals(HermesDeliveryKind.room)
        ..has((o) => o.name, 'name').equals('Daily standup');
    });

    test('saved targets the lists lack stay offered', () {
      final all = options.withSelected(['telegram', 'origin', 'room:x@lab']);

      check(all.length).equals(options.options.length + 2);
      check(all[all.length - 2].target).equals('origin');
      check(all.last)
        ..has((o) => o.target, 'target').equals('room:x@lab')
        ..has((o) => o.kind, 'kind').equals(HermesDeliveryKind.room);
    });

    test('local alone when Hermes lists nothing', () {
      final empty = HermesDeliveryOptions.build(targets: [], roomProfile: 'o');

      check(empty.options.map((o) => o.target).toList()).deepEquals(['local']);
    });
  });

  test('rooms parse from groups.list rows', () {
    final room = HermesRoom.fromJson({
      'room_id': 'standup',
      'name': 'Daily standup',
      'members': [
        {'member_id': 'm1', 'profile': 'research'},
        {'member_id': 'm2', 'profile': 'scout'},
        {'member_id': 'm3', 'profile': 'research'},
        {'member_id': 'm4'},
      ],
      'authority_gateway_id': 'install:synthetic',
      'authority_epoch': 1,
      'revision': 3,
      'created_at': 1767225600.0,
      'updated_at': 1767229200.0,
      'disbanded_at': null,
    })!;

    check(room.id).equals('standup');
    check(room.name).equals('Daily standup');
    check(room.memberProfiles).deepEquals(['research', 'scout']);
    check(room.updatedAt).isNotNull();
    check(room.disbanded).isFalse();
    check(HermesRoom.fromJson({'room_id': 'r', 'disbanded_at': 1.0})!)
      ..has((r) => r.name, 'name').equals('r')
      ..has((r) => r.disbanded, 'disbanded').isTrue();
    check(HermesRoom.fromJson({'name': 'no id'})).isNull();
  });
}
