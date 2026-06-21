import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/channel.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/features/channels/providers/channel_providers.dart';
import 'package:conduit/features/notifications/models/app_notification.dart';
import 'package:conduit/features/notifications/providers/notification_socket_listener.dart';
import 'package:conduit/features/notifications/services/active_view_tracker.dart';
import 'package:conduit/features/notifications/services/local_notification_service.dart';
import 'package:conduit/features/notifications/services/notification_router.dart';
import 'package:conduit/features/notifications/services/notification_sound_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class _CapturedChat {
  _CapturedChat({required this.requireFocus, required this.handler});
  final bool requireFocus;
  final SocketChatEventHandler handler;
}

class _CapturedChannel {
  _CapturedChannel({required this.requireFocus, required this.handler});
  final bool requireFocus;
  final SocketChannelEventHandler handler;
}

/// SocketService stand-in that records the wildcard chat/channel handlers the
/// listener registers and lets the test drive them + pump reconnect.
class _MockSocketService implements SocketService {
  final List<_CapturedChat> chat = <_CapturedChat>[];
  final List<_CapturedChannel> channel = <_CapturedChannel>[];
  final _reconnect = StreamController<void>.broadcast();

  void emitReconnect() => _reconnect.add(null);
  void disposeController() => _reconnect.close();

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    final reg = _CapturedChat(requireFocus: requireFocus, handler: handler);
    chat.add(reg);
    return SocketEventSubscription(() => chat.remove(reg));
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    final reg = _CapturedChannel(requireFocus: requireFocus, handler: handler);
    channel.add(reg);
    return SocketEventSubscription(() => channel.remove(reg));
  }

  @override
  Stream<void> get onReconnect => _reconnect.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Channels list whose `refresh` is counted (reconnect reconciliation).
class _FakeChannelsList extends ChannelsList {
  int refreshCalls = 0;

  @override
  Future<List<Channel>> build() async => const <Channel>[];

  @override
  Future<void> refresh() async {
    refreshCalls += 1;
  }
}

Map<String, dynamic> _chatCompletion({
  String chatId = 'chat-1',
  bool done = true,
  String type = 'chat:completion',
}) => {
  'chat_id': chatId,
  'data': {
    'type': type,
    'data': {'done': done, 'content': 'hello', 'title': 'Greeting'},
  },
};

Map<String, dynamic> _channelMessage({
  String channelId = 'chan-1',
  String type = 'message',
}) => {
  'channel_id': channelId,
  'channel': {'type': 'group', 'name': 'general'},
  'data': {
    'type': type,
    'data': {
      'id': 'm1',
      'content': 'hi',
      'user': {'id': 'other', 'name': 'Ada'},
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settings = AppSettings(
    notificationsEnabled: true,
    notificationSound: false,
    notificationSoundAlways: false,
    notificationInAppBanner: true,
    notificationSystem: true,
    notificationChatEnabled: true,
    notificationChannelEnabled: true,
  );

  late List<AppNotification> routed;

  ProviderContainer makeContainer(_MockSocketService socket) {
    routed = <AppNotification>[];
    final captureRouter = NotificationRouter(
      readSettings: () => settings,
      readActiveView: () => const ActiveView(),
      isAppForeground: () => true,
      localNotifications: LocalNotificationService(),
      sound: const NotificationSoundService(),
      showInAppBanner: routed.add,
      onChannelUnread: (_) {},
    );
    final container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWithValue(socket),
        notificationRouterProvider.overrideWithValue(captureRouter),
        channelsListProvider.overrideWith(_FakeChannelsList.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('registers one wildcard chat + channel handler, requireFocus:false', () {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket);

    container.read(notificationSocketListenerProvider);

    check(socket.chat).length.equals(1);
    check(socket.channel).length.equals(1);
    check(socket.chat.single.requireFocus).isFalse();
    check(socket.channel.single.requireFocus).isFalse();
  });

  test('routes a notifiable chat completion', () async {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket);
    container.read(notificationSocketListenerProvider);

    socket.chat.single.handler(_chatCompletion(), null);
    await Future<void>.delayed(Duration.zero);

    check(routed).length.equals(1);
    check(routed.single.kind).equals(NotificationKind.chatCompletion);
  });

  test('ignores a non-terminal completion frame', () async {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket);
    container.read(notificationSocketListenerProvider);

    socket.chat.single.handler(_chatCompletion(done: false), null);
    await Future<void>.delayed(Duration.zero);

    check(routed).isEmpty();
  });

  test('ignores a non-notifiable chat type', () async {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket);
    container.read(notificationSocketListenerProvider);

    socket.chat.single.handler(_chatCompletion(type: 'chat:title'), null);
    await Future<void>.delayed(Duration.zero);

    check(routed).isEmpty();
  });

  test('routes a notifiable channel message', () async {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket);
    container.read(notificationSocketListenerProvider);

    socket.channel.single.handler(_channelMessage(), null);
    await Future<void>.delayed(Duration.zero);

    check(routed).length.equals(1);
    check(routed.single.kind).equals(NotificationKind.channelMessage);
  });

  test('reconnect reconciles channel unread via refresh', () async {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket);
    container.read(notificationSocketListenerProvider);

    final channels = container.read(channelsListProvider.notifier)
        as _FakeChannelsList;
    final before = channels.refreshCalls;

    socket.emitReconnect();
    await Future<void>.delayed(Duration.zero);

    check(channels.refreshCalls).equals(before + 1);
  });

  test('re-binds handlers when the socket instance changes', () {
    final socket1 = _MockSocketService();
    final socket2 = _MockSocketService();
    addTearDown(socket1.disposeController);
    addTearDown(socket2.disposeController);
    final container = makeContainer(socket1);

    container.read(notificationSocketListenerProvider);
    check(socket1.chat).length.equals(1);

    container.updateOverrides([
      socketServiceProvider.overrideWithValue(socket2),
      notificationRouterProvider.overrideWithValue(
        container.read(notificationRouterProvider),
      ),
      channelsListProvider.overrideWith(_FakeChannelsList.new),
    ]);

    // Old subscriptions disposed, fresh ones registered on the new socket.
    check(socket1.chat).isEmpty();
    check(socket1.channel).isEmpty();
    check(socket2.chat).length.equals(1);
    check(socket2.channel).length.equals(1);
  });
}
