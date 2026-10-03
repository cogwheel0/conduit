import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/channels/providers/channel_socket_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _socketOwnerProvider =
    NotifierProvider<_MutableSocketOwner, SocketService?>(
      _MutableSocketOwner.new,
    );
final _authEpochOwnerProvider = NotifierProvider<_MutableEpoch, Object>(
  _MutableEpoch.new,
);

void main() {
  test('active channel rebinds when socket or auth owner changes', () async {
    final firstSocket = _RecordingSocketService();
    final replacementSocket = _RecordingSocketService();
    final container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWith(
          (ref) => ref.watch(_socketOwnerProvider),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(_authEpochOwnerProvider),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(_socketOwnerProvider.notifier).set(firstSocket);
    final handlerSubscription = container.listen(
      channelSocketHandlerProvider,
      (_, _) {},
    );
    addTearDown(handlerSubscription.close);

    container
        .read(channelSocketHandlerProvider.notifier)
        .subscribe('channel-1');
    expect(firstSocket.channelSubscriptions, ['channel-1']);

    container.read(_socketOwnerProvider.notifier).set(replacementSocket);
    await pumpEventQueue(times: 3);
    expect(firstSocket.disposeCount, 1);
    expect(replacementSocket.channelSubscriptions, ['channel-1']);

    container.read(_authEpochOwnerProvider.notifier).rotate();
    await pumpEventQueue(times: 3);
    expect(replacementSocket.disposeCount, 1);
    expect(replacementSocket.channelSubscriptions, ['channel-1', 'channel-1']);
  });

  group('thread replies from another account', () {
    late _RecordingSocketService socket;
    late _ThreadApi api;
    late ProviderContainer container;

    setUp(() async {
      socket = _RecordingSocketService();
      api = _ThreadApi();
      container = ProviderContainer(
        overrides: [
          socketServiceProvider.overrideWithValue(socket),
          apiServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      final handler = container.listen(channelSocketHandlerProvider, (_, _) {});
      addTearDown(handler.close);
      container.read(channelSocketHandlerProvider.notifier).subscribe('c1');
      final channel = container.listen(
        channelMessagesProvider('c1'),
        (_, _) {},
      );
      addTearDown(channel.close);
      final thread = container.listen(
        threadMessagesProvider('c1', 'parent'),
        (_, _) {},
      );
      addTearDown(thread.close);
      await container.read(channelMessagesProvider('c1').future);
      await container.read(threadMessagesProvider('c1', 'parent').future);
    });

    test('appear in the open thread, not in the channel timeline', () async {
      socket.emitChannelEvent({
        'channel_id': 'c1',
        'message_id': 'reply',
        'data': {
          'type': 'message',
          'data': {
            'id': 'reply',
            'channel_id': 'c1',
            'parent_id': 'parent',
            'content': 'from a friend',
          },
        },
      });
      await pumpEventQueue();

      final thread = container.read(threadMessagesProvider('c1', 'parent'));
      expect(thread.requireValue.map((m) => m.id), ['reply', 'r1']);
      final channel = container.read(channelMessagesProvider('c1'));
      expect(channel.requireValue.map((m) => m.id), ['parent']);
    });

    test('refresh the parent named by the message:reply payload', () async {
      // Open WebUI sends the parent message itself, whose own parent_id is
      // null.
      socket.emitChannelEvent({
        'channel_id': 'c1',
        'message_id': 'parent',
        'data': {
          'type': 'message:reply',
          'data': {
            'id': 'parent',
            'channel_id': 'c1',
            'parent_id': null,
            'reply_count': 1,
          },
        },
      });
      await pumpEventQueue();

      expect(api.refreshedMessageIds, ['parent']);
      final channel = container.read(channelMessagesProvider('c1'));
      expect(channel.requireValue.single.replyCount, 1);
    });

    test('edits of a reply update the open thread', () async {
      socket.emitChannelEvent(
        _event('message:update', {
          'id': 'r1',
          'channel_id': 'c1',
          'parent_id': 'parent',
          'content': 'edited',
        }),
      );
      await pumpEventQueue();

      final thread = container.read(threadMessagesProvider('c1', 'parent'));
      expect(thread.requireValue.single.content, 'edited');
      final channel = container.read(channelMessagesProvider('c1'));
      expect(channel.requireValue.single.content, 'parent');
    });

    test('deleting a reply removes it from the open thread', () async {
      socket.emitChannelEvent(
        _event('message:delete', {
          'id': 'r1',
          'channel_id': 'c1',
          'parent_id': 'parent',
        }),
      );
      await pumpEventQueue();

      final thread = container.read(threadMessagesProvider('c1', 'parent'));
      expect(thread.requireValue, isEmpty);
      final channel = container.read(channelMessagesProvider('c1'));
      expect(channel.requireValue.map((m) => m.id), ['parent']);
    });

    test('reactions on a reply update the open thread', () async {
      socket.emitChannelEvent(
        _event('message:reaction:add', {
          'id': 'r1',
          'channel_id': 'c1',
          'parent_id': 'parent',
          'name': 'thumbsup',
        }),
      );
      await pumpEventQueue();

      expect(api.refreshedMessageIds, ['r1']);
      final thread = container.read(threadMessagesProvider('c1', 'parent'));
      expect(thread.requireValue.single.reactions.single.name, 'thumbsup');
    });
  });
}

Map<String, dynamic> _event(String type, Map<String, dynamic> data) => {
  'channel_id': 'c1',
  'message_id': data['id'],
  'data': {'type': type, 'data': data},
};

class _ThreadApi extends ApiService {
  _ThreadApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'threads',
          name: 'Threads',
          url: 'https://threads.example.com',
        ),
        workerManager: WorkerManager(),
      );

  final List<String> refreshedMessageIds = [];

  @override
  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int skip = 0,
    int limit = 50,
  }) async => [
    {'id': 'parent', 'channel_id': channelId, 'content': 'parent'},
  ];

  @override
  Future<List<Map<String, dynamic>>> getMessageThread(
    String channelId,
    String messageId, {
    int skip = 0,
    int limit = 50,
  }) async => [
    {'id': 'r1', 'channel_id': channelId, 'parent_id': messageId},
  ];

  @override
  Future<Map<String, dynamic>?> getChannelMessage(
    String channelId,
    String messageId,
  ) async {
    refreshedMessageIds.add(messageId);
    if (messageId == 'r1') {
      return {
        'id': 'r1',
        'channel_id': channelId,
        'parent_id': 'parent',
        'reactions': [
          {
            'name': 'thumbsup',
            'users': [
              {'id': 'friend'},
            ],
            'count': 1,
          },
        ],
      };
    }
    return {
      'id': messageId,
      'channel_id': channelId,
      'content': 'parent',
      'reply_count': 1,
    };
  }
}

class _MutableSocketOwner extends Notifier<SocketService?> {
  @override
  SocketService? build() => null;

  void set(SocketService? value) => state = value;
}

class _MutableEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  void rotate() => state = Object();
}

class _RecordingSocketService implements SocketService {
  final List<String> channelSubscriptions = [];
  int disposeCount = 0;
  SocketChannelEventHandler? _handler;

  void emitChannelEvent(Map<String, dynamic> event) => _handler!(event, null);

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    channelSubscriptions.add(conversationId ?? '');
    _handler = handler;
    return SocketEventSubscription(() {
      disposeCount += 1;
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
