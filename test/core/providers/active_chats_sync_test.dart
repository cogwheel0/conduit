import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// A captured `addChatEventHandler` registration so tests can drive the
/// global `chat:active` handler directly and assert the wildcard contract.
class _CapturedRegistration {
  _CapturedRegistration({
    required this.conversationId,
    required this.sessionId,
    required this.messageId,
    required this.requireFocus,
    required this.handler,
  });

  final String? conversationId;
  final String? sessionId;
  final String? messageId;
  final bool requireFocus;
  final SocketChatEventHandler handler;
}

/// Minimal SocketService stand-in that records the handler `ActiveChatsSync`
/// registers and lets the test deliver events to it. `onReconnect` is a
/// broadcast controller the test can pump.
class _MockSocketService implements SocketService {
  @override
  final ServerConfig serverConfig = const ServerConfig(
    id: 'test',
    name: 'Test',
    url: 'http://localhost:0',
  );

  final List<_CapturedRegistration> registrations = <_CapturedRegistration>[];
  final _reconnectController = StreamController<void>.broadcast();

  void emitReconnect() => _reconnectController.add(null);

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    final reg = _CapturedRegistration(
      conversationId: conversationId,
      sessionId: sessionId,
      messageId: messageId,
      requireFocus: requireFocus,
      handler: handler,
    );
    registrations.add(reg);
    return SocketEventSubscription(
      () => registrations.remove(reg),
      handlerId: 'test-${registrations.length}',
    );
  }

  @override
  Stream<void> get onReconnect => _reconnectController.stream;

  void disposeController() => _reconnectController.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// ApiService whose `checkActiveChats` returns a scripted set so the
/// cold-open / reconnect reconciliation path can be tested deterministically.
class _FakeApiService extends ApiService {
  _FakeApiService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'http://localhost:0',
        ),
        workerManager: WorkerManager(),
      );

  Set<String> nextActive = const <String>{};
  int checkActiveChatsCalls = 0;
  List<String>? lastCheckedIds;

  @override
  Future<Set<String>> checkActiveChats(List<String> chatIds) async {
    checkActiveChatsCalls += 1;
    lastCheckedIds = chatIds;
    return nextActive;
  }
}

/// Conversations override returning a fixed list (avoids the DB-backed build).
class _FakeConversations extends Conversations {
  _FakeConversations(this._items);
  final List<Conversation> _items;

  @override
  Future<List<Conversation>> build() async => _items;
}

Conversation _conv(String id) => Conversation(
  id: id,
  title: 'Conversation $id',
  messages: const [],
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

/// Builds the standard `chat:active` envelope:
/// `{chat_id, message_id, data:{type:'chat:active', data:{active}}}`.
Map<String, dynamic> _activeEnvelope({
  required String chatId,
  required bool active,
  bool chatIdAtEnvelope = true,
  bool chatIdNested = false,
}) {
  final inner = <String, dynamic>{
    'active': active,
    if (chatIdNested) 'chat_id': chatId,
  };
  return <String, dynamic>{
    if (chatIdAtEnvelope) 'chat_id': chatId,
    'message_id': 'm1',
    'data': <String, dynamic>{
      'type': 'chat:active',
      'data': inner,
      if (!chatIdAtEnvelope && !chatIdNested) 'chat_id': chatId,
    },
  };
}

ProviderContainer _makeContainer({
  required _MockSocketService socket,
  _FakeApiService? api,
  List<Conversation> conversations = const <Conversation>[],
}) {
  final resolvedApi = api ?? _FakeApiService();
  final container = ProviderContainer(
    overrides: [
      socketServiceProvider.overrideWithValue(socket),
      apiServiceProvider.overrideWithValue(resolvedApi),
      conversationsProvider.overrideWith(
        () => _FakeConversations(conversations),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ActiveChatsSync — chat:active envelope parsing', () {
    test('active:true adds and active:false removes the chat id', () {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final container = _makeContainer(socket: socket);

      // Materialize the keepAlive sync provider so it binds the socket.
      container.read(activeChatsSyncProvider);
      final reg = socket.registrations.single;

      reg.handler(_activeEnvelope(chatId: 'c1', active: true), null);
      check(container.read(activeChatIdsProvider)).contains('c1');

      reg.handler(_activeEnvelope(chatId: 'c1', active: false), null);
      check(container.read(activeChatIdsProvider)).not((s) => s.contains('c1'));
    });

    test('chat_id nested under data resolves (envelope-level absent)', () {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final container = _makeContainer(socket: socket);
      container.read(activeChatsSyncProvider);
      final reg = socket.registrations.single;

      reg.handler(
        _activeEnvelope(chatId: 'c2', active: true, chatIdAtEnvelope: false),
        null,
      );
      check(container.read(activeChatIdsProvider)).contains('c2');
    });

    test('chat_id nested under data.data resolves', () {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final container = _makeContainer(socket: socket);
      container.read(activeChatsSyncProvider);
      final reg = socket.registrations.single;

      reg.handler(
        _activeEnvelope(
          chatId: 'c3',
          active: true,
          chatIdAtEnvelope: false,
          chatIdNested: true,
        ),
        null,
      );
      check(container.read(activeChatIdsProvider)).contains('c3');
    });

    test('non chat:active envelopes leave the set unchanged', () {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final container = _makeContainer(socket: socket);
      container.read(activeChatsSyncProvider);
      final reg = socket.registrations.single;

      // Seed an active chat, then deliver unrelated types.
      reg.handler(_activeEnvelope(chatId: 'c1', active: true), null);

      reg.handler(<String, dynamic>{
        'chat_id': 'c1',
        'data': {
          'type': 'chat:completion',
          'data': {'content': 'hi'},
        },
      }, null);
      reg.handler(<String, dynamic>{
        'chat_id': 'cX',
        'data': {'type': 'chat:list', 'data': <String, dynamic>{}},
      }, null);

      check(container.read(activeChatIdsProvider)).deepEquals({'c1'});
    });

    test('missing/non-bool active is ignored', () {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final container = _makeContainer(socket: socket);
      container.read(activeChatsSyncProvider);
      final reg = socket.registrations.single;

      reg.handler(<String, dynamic>{
        'chat_id': 'c1',
        'data': {
          'type': 'chat:active',
          'data': {'active': 'yes'},
        },
      }, null);
      check(container.read(activeChatIdsProvider)).isEmpty();
    });
  });

  group('ActiveChatsSync — wildcard delivery contract', () {
    test('registers an unscoped requireFocus:false handler', () {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final container = _makeContainer(socket: socket);
      container.read(activeChatsSyncProvider);

      final reg = socket.registrations.single;
      // All-null selectors + requireFocus:false => SocketService._shouldDeliver
      // short-circuits to deliver-always (cross-chat / other-device events).
      check(reg.requireFocus).isFalse();
      check(reg.conversationId).isNull();
      check(reg.sessionId).isNull();
      check(reg.messageId).isNull();
    });

    test(
      'delivers a chat:active for a background chat while another is focused',
      () {
        final socket = _MockSocketService();
        addTearDown(socket.disposeController);
        final container = _makeContainer(socket: socket);
        container.read(activeChatsSyncProvider);
        final reg = socket.registrations.single;

        // A different chat ("focused-chat") would be the foreground; the
        // wildcard handler must still light up "background-chat".
        reg.handler(
          _activeEnvelope(chatId: 'background-chat', active: true),
          null,
        );
        check(
          container.read(activeChatIdsProvider),
        ).contains('background-chat');
      },
    );
  });

  group('ActiveChatsSync — reconciliation fallback', () {
    test('cold-open refresh replaces the set from checkActiveChats', () async {
      final socket = _MockSocketService();
      addTearDown(socket.disposeController);
      final api = _FakeApiService()..nextActive = {'c2'};
      final container = _makeContainer(
        socket: socket,
        api: api,
        conversations: [_conv('c1'), _conv('c2')],
      );

      container.read(activeChatsSyncProvider);
      // Resolve the conversations list so the cold-open listener fires.
      await container.read(conversationsProvider.future);
      await Future<void>.delayed(Duration.zero);

      check(api.checkActiveChatsCalls).equals(1);
      check(container.read(activeChatIdsProvider)).deepEquals({'c2'});
    });

    test(
      'reconnect triggers a fresh checkActiveChats reconciliation',
      () async {
        final socket = _MockSocketService();
        addTearDown(socket.disposeController);
        final api = _FakeApiService();
        final container = _makeContainer(
          socket: socket,
          api: api,
          conversations: [_conv('c1')],
        );

        container.read(activeChatsSyncProvider);
        await container.read(conversationsProvider.future);
        await Future<void>.delayed(Duration.zero);
        final coldOpenCalls = api.checkActiveChatsCalls;

        api.nextActive = {'c1'};
        socket.emitReconnect();
        await Future<void>.delayed(Duration.zero);

        check(api.checkActiveChatsCalls).equals(coldOpenCalls + 1);
        check(container.read(activeChatIdsProvider)).deepEquals({'c1'});
      },
    );
  });

  group('ActiveChatsSync — logout / socket teardown', () {
    test('clears the set when the bound socket becomes null', () {
      final socket = _MockSocketService();
      final api = _FakeApiService();
      addTearDown(socket.disposeController);

      final container = ProviderContainer(
        overrides: [
          socketServiceProvider.overrideWithValue(socket),
          apiServiceProvider.overrideWithValue(api),
          conversationsProvider.overrideWith(
            () => _FakeConversations(const []),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(activeChatsSyncProvider);
      final reg = socket.registrations.single;
      reg.handler(_activeEnvelope(chatId: 'c1', active: true), null);
      check(container.read(activeChatIdsProvider)).contains('c1');

      // Simulate logout: socketServiceProvider transitions to null. The
      // `ref.listen<SocketService?>` inside ActiveChatsSync re-binds, and
      // _bindSocket(null) clears the set so no stale spinner survives.
      container.updateOverrides([
        socketServiceProvider.overrideWithValue(null),
        apiServiceProvider.overrideWithValue(null),
        conversationsProvider.overrideWith(() => _FakeConversations(const [])),
      ]);

      check(container.read(activeChatIdsProvider)).isEmpty();
      // A queued callback from the disposed authenticated socket must not be
      // able to repopulate state after logout.
      reg.handler(_activeEnvelope(chatId: 'late-a', active: true), null);
      check(container.read(activeChatIdsProvider)).isEmpty();
    });
  });

  group('ActiveChatIds — token-guarded conditional clear', () {
    test('setInactiveIfUnchanged clears when not re-activated', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(activeChatIdsProvider.notifier);

      notifier.setActive('c1');
      final token = notifier.activationToken('c1');
      notifier.setInactiveIfUnchanged('c1', token);

      check(container.read(activeChatIdsProvider)).not((s) => s.contains('c1'));
    });

    test('setInactiveIfUnchanged is a no-op after a racing re-activation', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(activeChatIdsProvider.notifier);

      // Stream A activates the chat and finishes; its async clear captured
      // the token now.
      notifier.setActive('c1');
      final tokenFromA = notifier.activationToken('c1');

      // Stream B starts for the same chat before A's lookup resolves.
      notifier.setActive('c1');

      // A's stale clear resolves with an empty task list — must NOT clear,
      // since B re-activated the chat (token changed).
      notifier.setInactiveIfUnchanged('c1', tokenFromA);

      check(container.read(activeChatIdsProvider)).contains('c1');
    });
  });
}
