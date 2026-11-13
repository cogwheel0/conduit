// What both hosts show for a channel and its messages: a direct message's
// title, who a message's sender is for grouping, and the unread count a
// message from someone else adds.
import 'package:checks/checks.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/channels/utils/channel_mentions.dart';
import 'package:conduit_core/features/channels/utils/channel_presentation.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  const dm = Channel(
    id: 'dm-1',
    name: '',
    type: 'dm',
    users: [
      {'id': 'me', 'name': 'Robin'},
      {'id': 'u2', 'name': 'Juniper'},
    ],
  );

  test('a direct message is titled by its participants', () {
    check(channelDisplayName(dm, fallback: 'Unknown'))
        .equals('Robin, Juniper');
  });

  test('a direct message can leave the signed-in user out of its title', () {
    check(
      channelDisplayName(dm, fallback: 'Unknown', excludingUserId: 'me'),
    ).equals('Juniper');
    // A conversation with oneself still names someone.
    const solo = Channel(
      id: 'dm-2',
      name: '',
      type: 'dm',
      users: [
        {'id': 'me', 'name': 'Robin'},
      ],
    );
    check(
      channelDisplayName(solo, fallback: 'Unknown', excludingUserId: 'me'),
    ).equals('Robin');
    // A channel keeps its name.
    const channel = Channel(id: 'c1', name: 'garden-club');
    check(
      channelDisplayName(channel, fallback: 'Unknown', excludingUserId: 'me'),
    ).equals('garden-club');
  });

  test('mentions read as @names, and a model speaks under its own id', () {
    check(
      stripMentions('Ask <@U:u2|Juniper> and <@M:fake|Kestrel>'),
    ).equals('Ask @Juniper and @Kestrel');
    const model = ChannelMessage(
      id: 'm1',
      userId: 'me',
      meta: {'model_id': 'kestrel', 'model_name': 'Kestrel 8B'},
    );
    check(channelMessageSender(model)).equals('kestrel');
    check(messageDisplayName(model)).equals('Kestrel 8B');
    const app = ChannelMessage(
      id: 'm2',
      appId: 'a1',
      user: ChannelMessageUser(id: 'a1', name: 'Builder'),
    );
    check(channelMessageSender(app)).equals('a1');
    const person = ChannelMessage(id: 'm3', userId: 'u2');
    check(channelMessageSender(person)).equals('u2');
  });

  test('a message from someone else adds one unread', () async {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(null),
        channelsListProvider.overrideWith(_Listed.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(channelsListProvider.future);
    final list = container.read(channelsListProvider.notifier);
    list.bumpUnread('c1');
    list.bumpUnread('c1');
    // A channel the list does not hold is left alone.
    list.bumpUnread('gone');
    check(
      container.read(channelsListProvider).value!.single.unreadCount,
    ).equals(3);
    list.markRead('c1');
    check(
      container.read(channelsListProvider).value!.single.unreadCount,
    ).equals(0);
  });
}

class _Listed extends ChannelsList {
  @override
  Future<List<Channel>> build() async => const [
    Channel(id: 'c1', name: 'garden-club', unreadCount: 1),
  ];
}
