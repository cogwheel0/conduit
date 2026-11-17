@TestOn('vm')
library;

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Answers this Mac did not run (another device, a scheduled task) notify
/// as the phone's do: the last `chat:completion` frame on the server's
/// socket, once, unless the daemon announced that answer itself.
void main() {
  late _Socket socket;
  late ProviderContainer container;
  late EventBus events;
  late List<EventEnvelope> heard;
  late Set<String> announced;
  late NotificationsService notifications;

  setUp(() {
    socket = _Socket();
    container = ProviderContainer(
      overrides: [
        socketServiceProvider.overrideWith((ref) => ref.watch(_socketInUse)),
        apiServiceProvider.overrideWithValue(null),
        settledActiveAccountIdProvider.overrideWith(_SettledAccount.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'robin',
            email: 'robin@example.com',
            name: 'Robin',
            role: 'user',
          ),
        ),
      ],
    );
    container.read(_socketInUse.notifier).use(socket);
    events = EventBus();
    heard = <EventEnvelope>[];
    events.attach('window', heard.add);
    announced = <String>{};
    notifications = NotificationsService(
      container,
      events: events,
      announced: announced.contains,
      answerGrace: const Duration(milliseconds: 20),
    );
  });

  tearDown(() {
    notifications.dispose();
    container.dispose();
  });

  Map<String, dynamic> frame(
    String chatId,
    String messageId, {
    bool done = true,
    String content = 'High tide at six.',
  }) => <String, dynamic>{
    'chat_id': chatId,
    'message_id': messageId,
    'data': <String, dynamic>{
      'type': 'chat:completion',
      'data': <String, dynamic>{
        'done': done,
        'content': content,
        'title': 'Tide tables',
      },
    },
  };

  List<AnswerNotice> answered() => <AnswerNotice>[
    for (final e in heard)
      if (e.event == ConduitEvents.notificationsAnswered)
        AnswerNotice.fromJson(e.payload),
  ];

  // The grace runs on fake time: past it, every notice due has been told.
  void grace(FakeAsync async) => async.elapse(const Duration(milliseconds: 80));

  test('a finished answer from elsewhere notifies once', () {
    fakeAsync((async) {
      socket.chat(frame('tides', 'reply-1', done: false));
      socket.chat(frame('tides', 'reply-1'));
      // The same last frame again (a replay): no second notice.
      socket.chat(frame('tides', 'reply-1'));
      grace(async);
      expectOneNotice(answered());
    });
  });

  test('an answer this daemon announced is left to turn.finished', () {
    fakeAsync((async) {
      announced.add('reply-2');
      socket.chat(frame('harbour', 'reply-2'));
      // Announced only after the frame came, within the grace.
      socket.chat(frame('harbour', 'reply-3'));
      announced.add('reply-3');
      grace(async);
      expect(answered(), isEmpty);
    });
  });

  test('a malformed frame or another event says nothing', () {
    fakeAsync((async) {
      socket.chat(<String, dynamic>{'data': 'not a map'});
      socket.chat(<String, dynamic>{
        'chat_id': 'tides',
        'data': <String, dynamic>{'type': 'chat:title'},
      });
      grace(async);
      expect(answered(), isEmpty);
    });
  });

  test('an answer heard before another account took over is not told', () {
    fakeAsync((async) {
      socket.chat(frame('tides', 'reply-1'));
      container.read(settledActiveAccountIdProvider.notifier).state =
          'account-sky';
      grace(async);
      expect(answered(), isEmpty, reason: "the last account's answer");
    });
  });

  test('an answer the next socket replays is told once', () {
    fakeAsync((async) {
      socket.chat(frame('tides', 'reply-1'));
      // The socket is replaced within the grace; the new one replays it.
      final next = _Socket();
      container.read(_socketInUse.notifier).use(next);
      async.flushMicrotasks();
      next.chat(frame('tides', 'reply-1'));
      grace(async);
      next.chat(frame('tides', 'reply-1'));
      grace(async);
      expectOneNotice(answered());
    });
  });

  test('an answer heard on a socket since replaced is not told', () {
    fakeAsync((async) {
      socket.chat(frame('tides', 'reply-1'));
      container.read(_socketInUse.notifier).use(_Socket());
      async.flushMicrotasks();
      grace(async);
      expect(answered(), isEmpty, reason: "the last socket's answer");
    });
  });
}

void expectOneNotice(List<AnswerNotice> notices) {
  expect(notices, hasLength(1));
  expect(notices.single.chatId, 'tides');
  expect(notices.single.messageId, 'reply-1');
  expect(notices.single.title, 'Tide tables');
}

class _Socket implements SocketService {
  final List<SocketChatEventHandler> _chat = <SocketChatEventHandler>[];

  void chat(Map<String, dynamic> event) {
    for (final handler in List.of(_chat)) {
      handler(event, null);
    }
  }

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
    _chat.add(handler);
    return SocketEventSubscription(() => _chat.remove(handler));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The socket in use, which a switch replaces.
final _socketInUse = NotifierProvider<_SocketInUse, SocketService?>(
  _SocketInUse.new,
);

class _SocketInUse extends Notifier<SocketService?> {
  @override
  SocketService? build() => null;

  // ignore: use_setters_to_change_properties
  void use(SocketService socket) => state = socket;
}

/// The account the socket belongs to, settled: notifications carry its
/// scope.
class _SettledAccount extends SettledActiveAccountId {
  @override
  String? build() => 'account-robin';

  // ignore: use_setters_to_change_properties
  void switchTo(String accountId) => state = accountId;
}
