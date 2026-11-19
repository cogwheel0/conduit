@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart'
    hide ChannelMessages, ChannelTypingUsers;
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/channel_message.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// What `channels.*` adds to the core's channel providers for a window:
/// how the list names and permits each channel, the unread count and the
/// `channels.posted` notice a message from someone else gets (mobile's
/// notification rules), and a list's changes sent as what changed.
void main() {
  late _Socket socket;
  late ProviderContainer container;
  late EventBus events;
  late List<EventEnvelope> heard;
  late ChannelsService channels;

  setUp(() {
    socket = _Socket();
    container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWithValue(socket),
        apiServiceProvider.overrideWithValue(null),
        settledActiveAccountIdProvider.overrideWith(_SettledAccount.new),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'robin',
            email: 'robin@example.com',
            name: 'Robin',
            role: 'user',
          ),
        ),
        channelsListProvider.overrideWith(_Listed.new),
        userPermissionsProvider.overrideWith(
          (ref) async => <String, dynamic>{
            'features': <String, dynamic>{'channels': true},
          },
        ),
      ],
    );
    events = EventBus();
    heard = <EventEnvelope>[];
    events.attach('window', heard.add);
    events.subscribe(
      'window',
      EventSubscription(scopes: <String>[ChannelsService.scopeFor('c1')]),
    );
    channels = ChannelsService(container, events: events);
  });

  tearDown(() => container.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  List<ChannelPosted> posted() => <ChannelPosted>[
    for (final envelope in heard)
      if (envelope.event == ConduitEvents.channelsPosted)
        ChannelPosted.fromJson(envelope.payload),
  ];

  int unread(String id) => container
      .read(channelsListProvider)
      .value!
      .singleWhere((c) => c.id == id)
      .unreadCount;

  Map<String, dynamic> message(
    String channelId,
    String id, {
    String author = 'u2',
    String name = 'Juniper',
    String content = 'Seedlings are up',
  }) => <String, dynamic>{
    'channel_id': channelId,
    'channel': <String, dynamic>{'id': channelId, 'name': channelId},
    'data': <String, dynamic>{
      'type': 'message',
      'data': <String, dynamic>{
        'id': id,
        'content': content,
        'user': <String, dynamic>{'id': author, 'name': name},
      },
    },
  };

  test('the list titles a direct message by the others in it', () async {
    final list = await channels.list();
    expect(list.canCreate, isTrue);
    final dm = list.channels.singleWhere((c) => c.id == 'dm1');
    expect(dm.kind, ChannelKind.dm);
    expect(dm.title, 'Juniper');
    expect(dm.canLeave, isTrue);
    expect(dm.canDelete, isFalse);
    final mine = list.channels.singleWhere((c) => c.id == 'c1');
    expect(mine.kind, ChannelKind.group);
    expect(mine.manager && mine.canDelete && mine.canLeave, isTrue);
    final theirs = list.channels.singleWhere((c) => c.id == 'c2');
    expect(theirs.muted, isTrue);
    expect(theirs.manager || theirs.canDelete, isFalse);
  });

  test(
    'someone else posting counts as unread and says whether it alerts',
    () async {
      await container.read(channelsListProvider.future);
      socket.channel(message('c1', 'm1'));
      await settle();
      expect(unread('c1'), 1);
      expect(posted().single.alert, isTrue);
      expect(posted().single.author, 'Juniper');
      expect(posted().single.channelTitle, 'garden-club');

      // A channel set to mentions only counts it, but alerts only when the
      // user is mentioned.
      socket.channel(message('c2', 'm2'));
      socket.channel(
        message('c2', 'm3', content: 'Over to <@U:me|Robin> for the beans'),
      );
      await settle();
      expect(unread('c2'), 2);
      expect(posted().map((p) => p.alert), <bool>[true, false, true]);
      expect(posted().last.mention, isTrue);

      // The user's own message, or one already counted, is not.
      socket.channel(message('c1', 'm4', author: 'me', name: 'Robin'));
      socket.channel(message('c1', 'm1'));
      await settle();
      expect(unread('c1'), 1);
      expect(posted(), hasLength(3));
    },
  );

  test('the channel in front of the user is read as messages come', () async {
    await container.read(channelsListProvider.future);
    await channels.focus('c1');
    socket.channel(message('c1', 'm5'));
    await settle();
    expect(unread('c1'), 0);
    expect(posted(), isEmpty);
    expect(socket.emitted.where((e) => e == 'events:channel'), isNotEmpty);
    // Once it is not, the next one counts.
    await channels.focus(null);
    socket.channel(message('c1', 'm6'));
    await settle();
    expect(unread('c1'), 1);
  });

  test('a list a window shows is patched with what changed', () async {
    final opened = await channels.messages(
      const ChannelMessagesQuery(channelId: 'c1'),
    );
    expect(opened.messages, isEmpty);
    final list = container.read(channelMessagesProvider('c1').notifier);
    list.prependMessage(
      const ChannelMessage(
        id: 'm1',
        channelId: 'c1',
        userId: 'u2',
        content: 'Ask <@U:me|Robin>',
        createdAt: 1790000000000,
        user: ChannelMessageUser(id: 'u2', name: 'Juniper'),
      ),
    );
    await settle();
    final added = heard.lastWhere(
      (e) => e.event == ConduitEvents.channelsMessage,
    );
    final change = ChannelMessagesChanged.fromJson(added.payload);
    expect(change.full, isFalse);
    expect(change.upserts.single.id, 'm1');
    expect(change.upserts.single.display, 'Ask **@Robin**');
    expect(change.upserts.single.senderKey, 'u2');
    list.removeMessage('m1');
    await settle();
    final gone = ChannelMessagesChanged.fromJson(
      heard.lastWhere((e) => e.event == ConduitEvents.channelsMessage).payload,
    );
    expect(gone.removed, <String>['m1']);
    expect(gone.upserts, isEmpty);
  });

  test('an app answering the user alone reaches the channel', () async {
    socket.app(<String, dynamic>{
      'app_id': 'a1',
      'app_name': 'Builder',
      'channel_id': 'c1',
      'message_id': 'm9',
      'reply': <String, dynamic>{
        'type': 'download',
        'title': 'Report',
        'content': '# Done',
        'filename': 'report.md',
      },
    });
    socket.app(<String, dynamic>{
      'app_id': 'a1',
      'channel_id': 'c1',
      'message_id': 'm9',
      'reply': <String, dynamic>{'type': 'ack'},
    });
    await settle();
    final replies = <ChannelAppReplyEvent>[
      for (final e in heard)
        if (e.event == ConduitEvents.channelsAppReply)
          ChannelAppReplyEvent.fromJson(e.payload),
    ];
    expect(replies.single.reply.kind, ChannelAppReplyKind.download);
    expect(replies.single.appName, 'Builder');
  });
  test("a channel read under one account is not the next one's", () async {
    var account = Object();
    final api = _Api();
    // The account's permissions, read once the test says.
    final permissions = Completer<Map<String, dynamic>>();
    final socket = _Socket();
    final container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWithValue(socket),
        apiServiceProvider.overrideWithValue(api),
        settledActiveAccountIdProvider.overrideWith(_SettledAccount.new),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'robin',
            email: 'robin@example.com',
            name: 'Robin',
            role: 'user',
          ),
        ),
        channelsListProvider.overrideWith(_Listed.new),
        userPermissionsProvider.overrideWith((ref) => permissions.future),
      ],
    );
    addTearDown(container.dispose);
    final events = EventBus();
    final heard = <EventEnvelope>[];
    events.attach('window', heard.add);
    final channels = ChannelsService(container, events: events);
    await container.read(channelsListProvider.future);
    void anotherAccount() {
      account = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
    }

    final expired = throwsA(
      isA<RpcError>().having(
        (e) => e.code,
        'code',
        ConduitErrorCodes.sessionExpired,
      ),
    );
    const seedSwap = <String, dynamic>{
      'id': 'c9',
      'name': 'seed-swap',
      'type': 'group',
      'user_id': 'u2',
    };

    // The channel arrives once another account is signed in: it is neither
    // made the active channel nor read under that account.
    final opening = channels.open('c9');
    anotherAccount();
    api.channel.complete(seedSwap);
    await expectLater(opening, expired);
    expect(container.read(activeChannelProvider), isNull);
    expect(socket.emitted, isEmpty);

    // An app's answer for the asker alone comes after the switch.
    final pressing = channels.appAction(
      const ChannelAppAction(channelId: 'c1', messageId: 'm7', actionId: 'go'),
    );
    await Future<void>.delayed(Duration.zero);
    anotherAccount();
    api.interaction.complete(<String, dynamic>{
      'type': 'message',
      'content': 'Your plot is B4',
    });
    await expectLater(pressing, expired);

    // A post in a channel the list doesn't hold yet, read after the switch:
    // no notice for the next account.
    api.channel = Completer<Map<String, dynamic>>();
    socket.channel(message('c9', 'm8'));
    await Future<void>.delayed(Duration.zero);
    anotherAccount();
    api.channel.complete(seedSwap);
    await Future<void>.delayed(Duration.zero);
    expect(
      heard.where((e) => e.event == ConduitEvents.channelsPosted),
      isEmpty,
    );

    // The list, its permissions read only after the switch: not the next
    // account's list, with its flags.
    final listing = channels.list();
    await Future<void>.delayed(Duration.zero);
    anotherAccount();
    permissions.complete(<String, dynamic>{
      'features': <String, dynamic>{'channels': true},
    });
    await expectLater(listing, expired);
  });
}


const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://home.invalid',
);

/// The server's channel answers, each held until the test completes it.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  var channel = Completer<Map<String, dynamic>>();
  final interaction = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> getChannel(
    String channelId, {
    ApiAuthSnapshot? authSnapshot,
  }) => channel.future;

  @override
  Future<Map<String, dynamic>?> getChannelMessage(
    String channelId,
    String messageId,
  ) async => <String, dynamic>{
    'id': messageId,
    'channel_id': channelId,
    'user_id': 'app-1',
    'content': 'Pick a plot',
    'created_at': 1790000000000,
    'app_id': 'allotments',
    'user': <String, dynamic>{'id': 'app-1', 'name': 'Allotments'},
  };

  @override
  Future<Map<String, dynamic>> createAppInteraction(
    String appId, {
    required String messageId,
    required String actionId,
  }) => interaction.future;
}

class _Listed extends ChannelsList {
  @override
  Future<List<Channel>> build() async => const <Channel>[
    Channel(id: 'c1', name: 'garden-club', type: 'group', userId: 'me'),
    Channel(
      id: 'c2',
      name: 'allotment',
      type: 'group',
      userId: 'u2',
      isChannelMuted: true,
    ),
    Channel(
      id: 'dm1',
      name: '',
      type: 'dm',
      users: <Map<String, dynamic>>[
        <String, dynamic>{'id': 'me', 'name': 'Robin'},
        <String, dynamic>{'id': 'u2', 'name': 'Juniper'},
      ],
    ),
  ];
}

class _Socket implements SocketService {
  final List<SocketChannelEventHandler> _channel =
      <SocketChannelEventHandler>[];
  final List<SocketAppEventHandler> _app = <SocketAppEventHandler>[];
  final StreamController<void> _reconnects = StreamController<void>.broadcast();
  final List<String> emitted = <String>[];

  void channel(Map<String, dynamic> event) {
    for (final handler in List.of(_channel)) {
      handler(event, null);
    }
  }

  void app(Map<String, dynamic> event) {
    for (final handler in List.of(_app)) {
      handler(event);
    }
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    _channel.add(handler);
    return SocketEventSubscription(() => _channel.remove(handler));
  }

  @override
  SocketEventSubscription addAppEventHandler(SocketAppEventHandler handler) {
    _app.add(handler);
    return SocketEventSubscription(() => _app.remove(handler));
  }

  @override
  Stream<void> get onReconnect => _reconnects.stream;

  @override
  void emit(String event, dynamic data) => emitted.add(event);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The account the socket belongs to, settled: notifications carry its
/// scope.
class _SettledAccount extends SettledActiveAccountId {
  @override
  String? build() => 'account-robin';
}
