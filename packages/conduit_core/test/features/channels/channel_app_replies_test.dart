// Private app replies (Open WebUI 0.12.1): `events:app` reaches only the
// asking user and is shown in the channel or thread it names, as in
// Messages.svelte, without being stored.
import 'package:checks/checks.dart';
import 'package:conduit_core/features/channels/providers/channel_app_replies.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Map<String, dynamic> _appEvent({
  String channelId = 'c1',
  String messageId = 'm1',
  String? parentId,
  String type = 'error',
}) => {
  'app_id': 'app-1',
  'app_name': 'Deploy Bot',
  'channel_id': channelId,
  'message_id': messageId,
  'parent_id': parentId,
  'reply': {'type': type, 'content': 'App is inactive'},
};

void main() {
  late _AppEventSocket socket;
  late ProviderContainer container;

  setUp(() {
    socket = _AppEventSocket();
    container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWithValue(socket),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
      ],
    );
    addTearDown(container.dispose);
  });

  test('an events:app reply goes to the channel or thread it names', () {
    final channel = channelAppRepliesProvider('c1', null);
    final thread = channelAppRepliesProvider('c1', 'p1');
    container.listen(channel, (_, _) {});
    container.listen(thread, (_, _) {});

    socket.deliver(_appEvent());
    socket.deliver(_appEvent(messageId: 'r1', parentId: 'p1'));
    // Another channel's reply and an acknowledgement show nowhere here.
    socket.deliver(_appEvent(channelId: 'c2', messageId: 'm2'));
    socket.deliver(_appEvent(messageId: 'm3', type: 'ack'));

    check(container.read(channel).keys).deepEquals(['m1:app-1']);
    check(container.read(channel)['m1:app-1']!.reply.content)
        .equals('App is inactive');
    check(container.read(thread).keys).deepEquals(['r1:app-1']);
  });

  test('a dismissed reply is gone and the view drops it on close', () async {
    final channel = channelAppRepliesProvider('c1', null);
    final subscription = container.listen(channel, (_, _) {});
    socket.deliver(_appEvent());

    container.read(channel.notifier).dismiss('m1:app-1');
    check(container.read(channel)).isEmpty();

    socket.deliver(_appEvent());
    check(container.read(channel)).isNotEmpty();
    check(socket.handlers).length.equals(1);

    // Leaving the channel ends the subscription; nothing is kept.
    subscription.close();
    await container.pump();
    check(socket.handlers).isEmpty();
    check(container.read(channel)).isEmpty();
  });
}

class _AppEventSocket implements SocketService {
  final List<SocketAppEventHandler> handlers = [];

  void deliver(Map<String, dynamic> event) {
    for (final handler in List.of(handlers)) {
      handler(event);
    }
  }

  @override
  SocketEventSubscription addAppEventHandler(SocketAppEventHandler handler) {
    handlers.add(handler);
    return SocketEventSubscription(() => handlers.remove(handler));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
