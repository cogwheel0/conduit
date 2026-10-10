import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit/features/notifications/providers/notification_socket_listener.dart';
import 'package:conduit_core/features/notifications/services/active_view_tracker.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart'
    show HermesBackendMode;
import 'package:conduit_core/features/notifications/services/hermes_push_watches.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
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
    bool keepsAliveInBackground = false,
    SocketReplayGapCallback? onReplayGap,
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

/// The active account, settled as [accountId].
class _SettledAccount extends SettledActiveAccountId {
  _SettledAccount(this.accountId);

  final String? accountId;

  @override
  String? build() => accountId;
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

class _ReconnectChannelApi extends ApiService {
  _ReconnectChannelApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  String messageId = 'before-reconnect';
  int messageRequests = 0;

  @override
  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int skip = 0,
    int limit = 50,
  }) async {
    messageRequests += 1;
    return <Map<String, dynamic>>[
      <String, dynamic>{'id': messageId, 'content': messageId},
    ];
  }
}

Map<String, dynamic> _chatCompletion({
  String chatId = 'chat-1',
  bool done = true,
  String type = 'chat:completion',
}) => {
  'chat_id': chatId,
  'message_id': 'msg-1',
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

  ProviderContainer makeContainer(
    _MockSocketService socket, {
    ApiService? api,
    String? accountId = 'acct-1',
  }) {
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
        if (api != null) apiServiceProvider.overrideWithValue(api),
        settledActiveAccountIdProvider.overrideWith(
          () => _SettledAccount(accountId),
        ),
        currentUserProvider.overrideWith(
          (ref) async => const User(
            id: 'me',
            username: 'me',
            email: 'me@example.com',
            role: 'user',
          ),
        ),
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
    check(routed.single.scope).equals('owui:acct-1');
    check(routed.single.dedupKey).equals('owui:acct-1|chat:chat-1:msg-1');
  });

  test('routes nothing before an account settles', () async {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket, accountId: null);
    container.read(notificationSocketListenerProvider);
    await container.read(currentUserProvider.future);

    socket.chat.single.handler(_chatCompletion(), null);
    socket.channel.single.handler(_channelMessage(), null);
    await Future<void>.delayed(Duration.zero);

    check(routed).isEmpty();
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
    await container.read(currentUserProvider.future); // resolve self id

    socket.channel.single.handler(_channelMessage(), null);
    await Future<void>.delayed(Duration.zero);

    check(routed).length.equals(1);
    check(routed.single.kind).equals(NotificationKind.channelMessage);
    check(routed.single.dedupKey).equals('owui:acct-1|channel:chan-1:m1');
  });

  test(
    'skips channel classification until the current user resolves',
    () async {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final container = makeContainer(socket);
      container.read(notificationSocketListenerProvider);

      // Do NOT await currentUserProvider: id is still unresolved, so a channel
      // message must be skipped rather than risk self-notifying.
      socket.channel.single.handler(_channelMessage(), null);
      await Future<void>.delayed(Duration.zero);

      check(routed).isEmpty();
    },
  );

  test('reconnect reconciles channel unread via refresh', () async {
    final socket = _MockSocketService();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket);
    container.read(notificationSocketListenerProvider);

    final channels =
        container.read(channelsListProvider.notifier) as _FakeChannelsList;
    final before = channels.refreshCalls;

    socket.emitReconnect();
    await Future<void>.delayed(Duration.zero);

    check(channels.refreshCalls).equals(before + 1);
  });

  test('reconnect also reloads cached channel messages', () async {
    final socket = _MockSocketService();
    final api = _ReconnectChannelApi();
    addTearDown(socket.disposeController);
    final container = makeContainer(socket, api: api);
    container.read(notificationSocketListenerProvider);
    final messages = channelMessagesProvider('chan-1');
    final messagesSubscription = container.listen(messages, (_, _) {});
    addTearDown(messagesSubscription.close);
    final initial = await container.read(messages.future);
    check(initial.single.id).equals('before-reconnect');

    api.messageId = 'after-reconnect';
    socket.emitReconnect();
    await Future<void>.delayed(Duration.zero);
    final refreshed = await container.read(messages.future);

    check(refreshed.single.id).equals('after-reconnect');
    check(api.messageRequests).equals(2);
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
      settledActiveAccountIdProvider.overrideWith(
        () => _SettledAccount('acct-1'),
      ),
      currentUserProvider.overrideWith(
        (ref) async => const User(
          id: 'me',
          username: 'me',
          email: 'me@example.com',
          role: 'user',
        ),
      ),
    ]);

    // Old subscriptions disposed, fresh ones registered on the new socket.
    check(socket1.chat).isEmpty();
    check(socket1.channel).isEmpty();
    check(socket2.chat).length.equals(1);
    check(socket2.channel).length.equals(1);
  });

  group('pushCoversNotification', () {
    late DateTime now;
    late HermesPushWatches watches;

    setUp(() {
      now = DateTime(2026, 10, 10, 12);
      watches = HermesPushWatches(now: () => now);
    });

    PushState pushWith(
      PushTarget target, {
      PushStatus status = PushStatus.on,
      bool optedOut = false,
      bool enabled = true,
    }) => PushState(
      enabled: enabled,
      targets: {
        target.scope: PushTargetState(
          target: target,
          status: status,
          optedOut: optedOut,
        ),
      },
    );

    HermesPushTarget hermes(HermesBackendMode mode) => HermesPushTarget(
      connectionId: 'conn-1',
      label: 'Home',
      baseUrl: 'https://hermes.example',
      mode: mode,
    );

    final turn = AppNotification(
      kind: NotificationKind.chatCompletion,
      scope: 'hermes:conn-1',
      title: 'Plan',
      body: 'Done.',
      sourceId: 's-1',
      dedupKey: 'hermes:conn-1|hermes:s-1:local',
      group: 'hermes:s-1',
      sharesPushDedupKey: false,
    );

    test('an API server session pushes only while its watch lasts', () {
      final push = pushWith(hermes(HermesBackendMode.responsesApi));
      check(pushCoversNotification(push, turn, watches: watches)).isFalse();

      watches.record('conn-1', 's-1', ttl: const Duration(hours: 6));
      check(pushCoversNotification(push, turn, watches: watches)).isTrue();
      // Another session of the connection was never watched.
      check(
        pushCoversNotification(
          push,
          turn.copyWith(sourceId: 's-2'),
          watches: watches,
        ),
      ).isFalse();

      now = now.add(const Duration(hours: 6));
      check(pushCoversNotification(push, turn, watches: watches)).isFalse();
    });

    test('a desktop session pushes without a watch', () {
      check(
        pushCoversNotification(
          pushWith(hermes(HermesBackendMode.desktopGateway)),
          turn,
          watches: watches,
        ),
      ).isTrue();
    });

    test('nothing pushes unless push is on for the scope', () {
      watches.record('conn-1', 's-1', ttl: const Duration(hours: 6));
      final target = hermes(HermesBackendMode.desktopGateway);
      for (final push in [
        null,
        pushWith(target, enabled: false),
        pushWith(target, status: PushStatus.verifying),
        pushWith(target, optedOut: true),
      ]) {
        check(pushCoversNotification(push, turn, watches: watches)).isFalse();
      }
      check(
        pushCoversNotification(
          pushWith(target, status: PushStatus.updateAvailable),
          turn,
          watches: watches,
        ),
      ).isTrue();
    });

    test('an Open WebUI account with push on pushes', () {
      final push = pushWith(
        const OpenWebUiPushTarget(accountId: 'acct-1', label: 'Ada'),
      );
      final frame = turn.copyWith(
        scope: 'owui:acct-1',
        sourceId: 'c1',
        dedupKey: 'owui:acct-1|chat:c1:x',
      );
      check(pushCoversNotification(push, frame, watches: watches)).isTrue();
    });
  });
}
