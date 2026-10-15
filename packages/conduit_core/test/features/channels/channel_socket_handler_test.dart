// The `events:channel` envelope routing (routers/channels.py): a thread
// reply is a `message` with a parent_id and must not land in the channel's
// own list, as in Open WebUI's Channel.svelte.
import 'package:checks/checks.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_socket_handler.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  late _CapturingSocket socket;
  late ProviderContainer container;

  setUp(() async {
    socket = _CapturingSocket();
    final epoch = Object();
    container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWithValue(socket),
        openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        apiServiceProvider.overrideWithValue(null),
        channelsListProvider.overrideWith(_ListedChannels.new),
      ],
    );
    container.listen(channelSocketHandlerProvider, (_, _) {});
    container.listen(channelMessagesProvider('c1'), (_, _) {});
    await container.read(channelMessagesProvider('c1').future);
    container.read(channelSocketHandlerProvider.notifier).subscribe('c1');
  });

  tearDown(() => container.dispose());

  Map<String, dynamic> messageEvent(Map<String, dynamic> message) => {
    'channel_id': 'c1',
    'message_id': message['id'],
    'data': {'type': 'message', 'data': message},
  };

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a top-level message joins the channel list', () async {
    socket.deliver(messageEvent({'id': 'm1', 'content': 'hi'}));
    await settle();
    check(container.read(channelMessagesProvider('c1')).value!.map((m) => m.id))
        .deepEquals(['m1']);
  });

  test('a thread reply goes to its open thread, not the channel', () async {
    container.listen(threadMessagesProvider('c1', 'p1'), (_, _) {});
    await container.read(threadMessagesProvider('c1', 'p1').future);

    socket.deliver(
      messageEvent({'id': 'r1', 'content': 'reply', 'parent_id': 'p1'}),
    );
    await settle();

    check(container.read(channelMessagesProvider('c1')).value!).isEmpty();
    check(
      container
          .read(threadMessagesProvider('c1', 'p1'))
          .value!
          .map((m) => m.id),
    ).deepEquals(['r1']);
  });

  test('a thread reply for a closed thread is dropped', () async {
    socket.deliver(
      messageEvent({'id': 'r2', 'content': 'reply', 'parent_id': 'p2'}),
    );
    await settle();
    check(container.read(channelMessagesProvider('c1')).value!).isEmpty();
    check(container.exists(threadMessagesProvider('c1', 'p2'))).isFalse();
  });

  test('an update without a user keeps the sender and the reactions', () async {
    // The edit endpoint and message:update carry the bare MessageModel.
    socket.deliver(
      messageEvent({
        'id': 'm1',
        'content': 'hi',
        'user': {'id': 'u1', 'name': 'Ada'},
        'reactions': [
          {'name': 'tada', 'count': 1},
        ],
        'reply_count': 2,
      }),
    );
    await settle();

    socket.deliver({
      'channel_id': 'c1',
      'message_id': 'm1',
      'data': {
        'type': 'message:update',
        'data': {'id': 'm1', 'content': 'hi edited', 'data': {}},
      },
    });
    await settle();

    final message = container.read(channelMessagesProvider('c1')).value!.single;
    check(message.content).equals('hi edited');
    check(message.userName).equals('Ada');
    check(message.reactions.map((r) => r.name)).deepEquals(['tada']);
    check(message.replyCount).equals(2);
  });

  test('a thread reply edit keeps the sender and the reactions', () async {
    container.listen(threadMessagesProvider('c1', 'p1'), (_, _) {});
    await container.read(threadMessagesProvider('c1', 'p1').future);
    socket.deliver(
      messageEvent({
        'id': 'r1',
        'content': 'reply',
        'parent_id': 'p1',
        'user': {'id': 'u1', 'name': 'Ada'},
        'reactions': [
          {'name': 'tada', 'count': 1},
        ],
      }),
    );
    await settle();

    socket.deliver({
      'channel_id': 'c1',
      'message_id': 'r1',
      'data': {
        'type': 'message:update',
        'data': {
          'id': 'r1',
          'content': 'reply edited',
          'parent_id': 'p1',
          'data': {},
        },
      },
    });
    await settle();

    final reply = container
        .read(threadMessagesProvider('c1', 'p1'))
        .value!
        .single;
    check(reply.content).equals('reply edited');
    check(reply.userName).equals('Ada');
    check(reply.reactions.map((r) => r.name)).deepEquals(['tada']);
  });

  // Open WebUI 0.12.1 sends channel:mute to the user's own sessions.
  test('channel:mute sets the listed channel to mentions only', () async {
    await container.read(channelsListProvider.future);
    Map<String, dynamic> muteEvent(Object? muted) => {
      'channel_id': 'c1',
      'data': {
        'type': 'channel:mute',
        'data': {'is_channel_muted': muted},
      },
    };
    bool muted() =>
        container.read(channelsListProvider).value!.single.isChannelMuted;

    socket.deliver(muteEvent(true));
    check(muted()).isTrue();

    // A malformed event changes nothing.
    socket.deliver(muteEvent('yes'));
    check(muted()).isTrue();

    socket.deliver(muteEvent(false));
    check(muted()).isFalse();
  });

  test('parseChannelMuteEvent reads only channel:mute events', () {
    check(
      parseChannelMuteEvent({
        'channel_id': 'c9',
        'data': {
          'type': 'channel:mute',
          'data': {'is_channel_muted': true},
        },
      }),
    ).equals((channelId: 'c9', isChannelMuted: true));
    check(
      parseChannelMuteEvent({
        'channel_id': 'c9',
        'data': {'type': 'message', 'data': <String, dynamic>{}},
      }),
    ).isNull();
  });
}

class _ListedChannels extends ChannelsList {
  @override
  Future<List<Channel>> build() async => const [
    Channel(id: 'c1', name: 'general'),
  ];
}

class _CapturingSocket implements SocketService {
  SocketChannelEventHandler? _handler;

  void deliver(Map<String, dynamic> event) => _handler?.call(event, null);

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    _handler = handler;
    return SocketEventSubscription(() => _handler = null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
