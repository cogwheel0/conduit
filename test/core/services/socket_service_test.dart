import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/personal_tool_execution.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/network/conduit_user_agent.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:conduit_core/testing.dart';

Future<void> _flushMicrotasks([int count = 1]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('client execution RPCs fail explicitly without a chat listener and reject foreign sessions', () async {
    final factory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: factory.create,
    );
    addTearDown(service.dispose);
    await service.connect();
    factory.sockets.single.id = 'local-session';
    final replies = <dynamic>[];
    for (final type in ['execute', 'execute:python']) {
      for (final session in ['other-session', 'local-session']) {
        service.debugHandleChatEvent({
          'chat_id': 'background-chat',
          'message_id': 'assistant',
          'data': {
            'type': type,
            'data': {'session_id': session, 'code': 'untrusted code'},
          },
        }, (dynamic result) => replies.add(result));
      }
    }
    expect(replies, hasLength(2));
    expect(replies[0]['error'], contains('does not support'));
    expect(replies[1]['stderr'], contains('does not support'));
    expect(replies[1]['stdout'], isEmpty);
    expect(replies[1]['result'], isNull);
  });

  test('terminal and MCP requests are answered without a chat listener', () async {
    // Open WebUI 0.12 waits up to 5 s for a terminal's AGENTS.md and up to
    // 240 s for an MCP elicitation before going on with the turn.
    final factory = _RecordingSocketFactory();
    final service = SocketService(
      serverConfig: _serverConfig,
      socketFactory: factory.create,
    );
    addTearDown(service.dispose);
    await service.connect();
    factory.sockets.single.id = 'local-session';
    final replies = <String, dynamic>{};
    for (final (type, data) in [
      (
        'request:terminal',
        {'terminal_id': 't1', 'path': '/files/cwd', 'session_id': 'local-session'},
      ),
      ('request:terminal:state', {'terminal_id': 't1', 'session_id': 'local-session'}),
      ('request:elicitation', {'mode': 'form', 'message': 'Pick one', 'server_name': 'mcp'}),
    ]) {
      service.debugHandleChatEvent({
        'chat_id': 'background-chat',
        'message_id': 'assistant',
        'data': {'type': type, 'data': data},
      }, (dynamic result) => replies[type] = result);
    }

    expect(replies['request:terminal'], isEmpty);
    expect(replies['request:terminal:state'], {'connected': false});
    expect(replies['request:elicitation'], {'action': 'cancel'});

    // The server's note that such a request is over needs no handling.
    var delivered = 0;
    service.addChatEventHandler(
      conversationId: 'background-chat',
      handler: (_, _) => delivered += 1,
    );
    service.debugHandleChatEvent({
      'chat_id': 'background-chat',
      'message_id': 'assistant',
      'data': {
        'type': 'request:interaction:done',
        'data': {'interaction_id': 'interaction-1'},
      },
    });
    expect(delivered, 0);
  });

  group('a direct tool call is always answered once', () {
    const admission = PersonalToolAdmission(
      kind: PersonalConnectionKind.toolServer,
      identity: 'tools',
      url: 'https://tools.example',
      operations: <String>{'search'},
    );

    Future<
      ({
        SocketService service,
        List<dynamic> replies,
        int Function({String chatId, String callId}) send,
        void Function() admit,
        void Function(String) setSession,
      })
    >
    connected() async {
      final factory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig,
        socketFactory: factory.create,
      );
      addTearDown(service.dispose);
      await service.connect();
      factory.sockets.single.id = 'local-session';
      final replies = <dynamic>[];
      var calls = 0;
      int send({String chatId = 'background-chat', String? callId}) {
        service.debugHandleChatEvent({
          'chat_id': chatId,
          'message_id': 'assistant',
          'data': {
            'type': 'execute:tool',
            'data': {
              'id': callId ?? 'call-${calls++}',
              'session_id': 'local-session',
              'name': 'search',
              'server': {'url': 'https://tools.example'},
            },
          },
        }, (dynamic reply) => replies.add(reply));
        return calls;
      }

      void admit() => service.admitPersonalToolServers(
        chatId: 'background-chat',
        messageId: 'assistant',
        sessionId: 'local-session',
        connections: const [admission],
      );

      return (
        service: service,
        replies: replies,
        send: ({chatId = 'background-chat', callId = ''}) =>
            send(chatId: chatId, callId: callId.isEmpty ? null : callId),
        admit: admit,
        setSession: (id) => factory.sockets.single.id = id,
      );
    }

    test('with no executor, or one that throws', () async {
      final c = await connected();
      c.admit();

      c.send();
      await _flushMicrotasks(2);
      expect(c.replies, hasLength(1));
      expect(c.replies.single['error'], isNotEmpty);

      c.service.toolExecutionHandler = (
        call, {
        required admitted,
        required isActive,
      }) async => throw StateError('boom');
      c.send();
      await _flushMicrotasks(2);
      expect(c.replies, hasLength(2));
      expect(c.replies.last['error'], isNotEmpty);
    });

    test('with an executor that never finishes', () async {
      final c = await connected();
      c.admit();
      c.service.toolExecutionHandler = (
        call, {
        required admitted,
        required isActive,
      }) => Completer<Object?>().future;

      fakeAsync((async) {
        c.send();
        async.elapse(
          SocketService.toolExecutionTimeout - const Duration(seconds: 1),
        );
        expect(c.replies, isEmpty);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(c.replies, hasLength(1));
        expect(c.replies.single['error'], isNotEmpty);
      });
    });

    test(
      'a call that timed out is no longer active for its executor',
      () async {
        final c = await connected();
        c.admit();
        late bool Function() active;
        final started = Completer<void>();
        c.service.toolExecutionHandler =
            (call, {required admitted, required isActive}) {
              active = isActive;
              started.complete();
              return Completer<Object?>().future;
            };

        fakeAsync((async) {
          c.send();
          async.flushMicrotasks();
          expect(started.isCompleted, isTrue);
          expect(active(), isTrue);
          async.elapse(
            SocketService.toolExecutionTimeout + const Duration(seconds: 1),
          );
          async.flushMicrotasks();
          // The executor is still running, but must not start anything now.
          expect(active(), isFalse);
        });
      },
    );

    test('a call whose connection ended is no longer active', () async {
      final c = await connected();
      c.admit();
      late bool Function() active;
      c.service.toolExecutionHandler =
          (call, {required admitted, required isActive}) {
            active = isActive;
            return Completer<Object?>().future;
          };

      c.send();
      await _flushMicrotasks();
      expect(active(), isTrue);
      c.service.dispose();

      expect(active(), isFalse);
    });

    test(
      'is given exactly what the chat request admitted, and only for it',
      () async {
        final c = await connected();
        Map<String, dynamic>? seen;
        List<PersonalToolAdmission>? seenAdmitted;
        c.service.toolExecutionHandler =
            (call, {required admitted, required isActive}) async {
              seen = call;
              seenAdmitted = admitted;
              return 'ok';
            };

        // Nothing was sent for this chat yet: refused, and the executor never ran.
        c.send();
        await _flushMicrotasks(2);
        expect(c.replies.single['error'], 'Tool Server Not Found');
        expect(seen, isNull);

        c.admit();
        c.send();
        await _flushMicrotasks(2);
        expect(seen?['chat_id'], 'background-chat');
        expect(seen?['message_id'], 'assistant');
        expect(seenAdmitted, [admission]);
        expect(c.replies.last, 'ok');

        // Another chat is not covered by it.
        seen = null;
        c.send(chatId: 'another-chat');
        await _flushMicrotasks(2);
        expect(seen, isNull);
        expect(c.replies.last['error'], 'Tool Server Not Found');
      },
    );

    test('a request for another session admits nothing here', () async {
      final c = await connected();
      var ran = false;
      c.service.toolExecutionHandler =
          (call, {required admitted, required isActive}) async {
            ran = true;
            return 'ok';
          };
      c.service.admitPersonalToolServers(
        chatId: 'background-chat',
        messageId: 'assistant',
        sessionId: 'previous-session',
        connections: const [admission],
      );

      c.send();
      await _flushMicrotasks(2);

      expect(ran, isFalse);
      expect(c.replies.single['error'], 'Tool Server Not Found');
    });

    test('a finished completion stops admitting its callbacks', () async {
      final c = await connected();
      var runs = 0;
      c.service.toolExecutionHandler =
          (call, {required admitted, required isActive}) async {
            runs++;
            return 'ok';
          };
      c.admit();
      c.send();
      await _flushMicrotasks(2);
      expect(runs, 1);

      c.service.debugHandleChatEvent({
        'chat_id': 'background-chat',
        'message_id': 'assistant',
        'data': {
          'type': 'chat:completion',
          'data': {'done': true},
        },
      });
      c.send();
      await _flushMicrotasks(2);

      expect(runs, 1);
      expect(c.replies.last['error'], 'Tool Server Not Found');
    });

    test('only a bounded number of requests stay admitted', () async {
      final c = await connected();
      var runs = 0;
      c.service.toolExecutionHandler =
          (call, {required admitted, required isActive}) async {
            runs++;
            return 'ok';
          };
      // One more request than fits: the first, oldest one is dropped.
      for (var i = 0; i <= 32; i++) {
        c.service.admitPersonalToolServers(
          chatId: i == 0 ? 'background-chat' : 'chat-$i',
          messageId: 'assistant',
          sessionId: 'local-session',
          connections: const [admission],
        );
      }

      c.send();
      await _flushMicrotasks(2);

      expect(runs, 0);
      expect(c.replies.single['error'], 'Tool Server Not Found');
    });

    test('a completed call is answered again without running again', () async {
      final c = await connected();
      c.admit();
      var runs = 0;
      c.service.toolExecutionHandler =
          (call, {required admitted, required isActive}) async {
            runs++;
            return <Object?>[
              {'created': runs},
              <String, String>{},
            ];
          };

      c.send(callId: 'same-call');
      await _flushMicrotasks(2);
      c.send(callId: 'same-call');
      await _flushMicrotasks(2);

      expect(runs, 1);
      expect(c.replies, hasLength(2));
      expect(c.replies.last, c.replies.first);
    });

    test(
      'a completed call too large to keep is answered with an error',
      () async {
        final c = await connected();
        c.admit();
        var runs = 0;
        c.service.toolExecutionHandler =
            (call, {required admitted, required isActive}) async {
              runs++;
              return 'x' * (SocketService.maxCompletedToolReplyChars + 1);
            };

        c.send(callId: 'big-call');
        await _flushMicrotasks(2);
        c.send(callId: 'big-call');
        await _flushMicrotasks(2);

        expect(runs, 1);
        expect(c.replies, hasLength(2));
        expect(
          c.replies.first,
          hasLength(SocketService.maxCompletedToolReplyChars + 1),
        );
        expect(c.replies.last['error'], contains('already ran'));
      },
    );

    test('only a bounded number of completed calls are remembered', () async {
      final c = await connected();
      c.admit();
      var runs = 0;
      c.service.toolExecutionHandler =
          (call, {required admitted, required isActive}) async {
            runs++;
            return 'ok';
          };

      for (var i = 0; i <= SocketService.maxCompletedToolCalls; i++) {
        c.send(callId: 'call-id-$i');
        await _flushMicrotasks(2);
      }
      final before = runs;
      // The first call has been forgotten, the last is still remembered.
      c.send(callId: 'call-id-${SocketService.maxCompletedToolCalls}');
      await _flushMicrotasks(2);
      expect(runs, before);
      c.send(callId: 'call-id-0');
      await _flushMicrotasks(2);
      expect(runs, before + 1);
    });
  });

  test('inactive remains foreground and does not force reconnect', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);

    final service = _RecordingSocketService(lifecycle: lifecycle);
    addTearDown(service.dispose);

    lifecycle.emit(AppLifecyclePhase.inactive);
    lifecycle.emit(AppLifecyclePhase.resumed);
    await _flushMicrotasks(2);

    expect(service.isAppForeground, isTrue);
    expect(service.forceConnectCalls, isEmpty);
  });

  test('best-effort connect observes a throwing socket factory', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);

    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: (_, _, _) => throw StateError('factory failed'),
    );
    addTearDown(service.dispose);
    final uncaughtErrors = <Object>[];

    await runZonedGuarded<Future<void>>(() async {
      service.connectBestEffort(reason: 'test-throwing-factory');
      await _flushMicrotasks(4);
    }, (error, _) => uncaughtErrors.add(error));

    expect(uncaughtErrors, isEmpty);
    await expectLater(service.connect(force: true), throwsA(isA<StateError>()));
  });

  test('a waiterless forced fallback reports its factory failure', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    var factoryCalls = 0;
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      websocketOnly: true,
      socketFactory: (base, builder, config) {
        factoryCalls++;
        if (factoryCalls > 1) throw StateError('fallback factory failed');
        return socketFactory.create(base, builder, config);
      },
    );
    addTearDown(service.dispose);
    final originalDebugPrint = debugPrint;
    final messages = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) messages.add(message);
    };
    addTearDown(() => debugPrint = originalDebugPrint);

    await service.connect();
    socketFactory.sockets.single.emitReserved(
      'connect_error',
      StateError('websocket failed'),
    );
    await _flushMicrotasks(4);

    expect(factoryCalls, 2);
    expect(
      messages.any(
        (message) =>
            message.contains('Best-effort socket operation failed') &&
            message.contains('reason=websocket-polling-fallback'),
      ),
      isTrue,
    );
  });

  test('resuming from background forces a fresh socket connection', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);

    final service = _RecordingSocketService(lifecycle: lifecycle);
    addTearDown(service.dispose);

    lifecycle.emit(AppLifecyclePhase.paused);
    expect(service.isAppForeground, isFalse);

    lifecycle.emit(AppLifecyclePhase.resumed);
    await _flushMicrotasks(2);

    expect(service.isAppForeground, isTrue);
    expect(service.forceConnectCalls, [true]);
  });

  test(
    'resume reconnect is guarded while a forced connect is in flight',
    () async {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);

      final connectGate = Completer<void>();
      final service = _RecordingSocketService(
        connectGate: connectGate,
        lifecycle: lifecycle,
      );
      addTearDown(service.dispose);

      lifecycle.emit(AppLifecyclePhase.paused);
      lifecycle.emit(AppLifecyclePhase.resumed);
      await _flushMicrotasks(2);

      lifecycle.emit(AppLifecyclePhase.hidden);
      lifecycle.emit(AppLifecyclePhase.resumed);
      await _flushMicrotasks(2);

      expect(service.forceConnectCalls, [true]);

      connectGate.complete();
      await _flushMicrotasks(2);
    },
  );

  test(
    'force reconnect restores dynamic event listeners on the new socket',
    () async {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      final received = <String>[];
      service.onEvent('task-channel', (data) => received.add(data.toString()));

      await service.connect();
      expect(socketFactory.sockets, hasLength(1));

      socketFactory.sockets.single.emitReserved('task-channel', 'first');
      expect(received, ['first']);

      final oldSocket = socketFactory.sockets.single;
      oldSocket.emitReserved('connect');
      await _flushMicrotasks(2);
      await service.connect(force: true);
      expect(socketFactory.sockets, hasLength(2));

      oldSocket.emitReserved('task-channel', 'old');
      socketFactory.sockets.last.emitReserved('task-channel', 'second');

      expect(received, ['first', 'second']);
    },
  );

  test('forced reconnects coalesce until the active attempt settles', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      authToken: 'session-token',
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    final firstSocket = socketFactory.sockets.single;
    final firstSocketEvents = <String>[];
    firstSocket.onAnyOutgoing(
      (event, _) => firstSocketEvents.add(event.toString()),
    );

    final firstForced = service.connect(force: true);
    final secondForced = service.connect(force: true);
    await _flushMicrotasks(2);

    // A force request cannot dispose or replace a negotiating socket.
    expect(socketFactory.sockets, hasLength(1));
    expect(service.socket, same(firstSocket));

    firstSocket.emitReserved('connect');
    await Future.wait([firstForced, secondForced]);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
    expect(firstSocketEvents, isNot(contains('user-join')));

    // Events queued by the retired attempt cannot trigger another fallback
    // or replace the fresh socket after ownership has moved on.
    firstSocket.emitReserved('connect_error', StateError('stale failure'));
    await _flushMicrotasks(2);
    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
  });

  test('pausing during handshake allows a fresh socket on resume', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);

    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    expect(socketFactory.sockets, hasLength(1));

    // The test socket deliberately emits no disconnect terminal event while
    // it is still negotiating.
    lifecycle.emit(AppLifecyclePhase.paused);
    lifecycle.emit(AppLifecyclePhase.resumed);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
  });

  test('going offline during handshake allows a fresh socket online', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    expect(socketFactory.sockets, hasLength(1));

    service.updateNetworkAvailability(false);
    service.updateNetworkAvailability(true);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, hasLength(2));
    expect(service.socket, same(socketFactory.sockets.last));
  });

  test(
    'connect includes the Conduit User-Agent in handshake headers',
    () async {
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        serverConfig: _serverConfig.copyWith(
          customHeaders: const {
            'X-Proxy-Credential': 'proxy-secret',
            'user-agent': 'spoofed-agent',
          },
        ),
        authToken: 'auth-token',
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      await service.connect();

      final headers = socketFactory.handshakeHeaders.single;
      expect(headers[ConduitUserAgent.headerName], ConduitUserAgent.value);
      expect(headers['Authorization'], 'Bearer auth-token');
      expect(headers['X-Proxy-Credential'], 'proxy-secret');
      expect(headers.keys.where(ConduitUserAgent.isHeaderName), [
        ConduitUserAgent.headerName,
      ]);
    },
  );

  test('connect backs repeated Socket.IO retries off to one minute', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();

    final options = socketFactory.handshakeOptions.single;
    expect(options['reconnectionDelay'], 1000);
    expect(options['reconnectionDelayMax'], 60000);
  });

  test('native handshake sends one Conduit User-Agent value', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final receivedUserAgents = Completer<List<String>>();
      server.listen((request) async {
        if (!receivedUserAgents.isCompleted) {
          receivedUserAgents.complete(
            request.headers[HttpHeaders.userAgentHeader] ?? const [],
          );
        }
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      });

      final service = SocketService(
        serverConfig: ServerConfig(
          id: 'wire-user-agent',
          name: 'Wire User-Agent',
          url: 'http://${server.address.address}:${server.port}',
        ),
        websocketOnly: true,
      );

      try {
        await service.connect();
        expect(
          await receivedUserAgents.future.timeout(const Duration(seconds: 5)),
          [ConduitUserAgent.value],
        );
      } finally {
        service.dispose();
        await server.close(force: true);
      }
    }, _RealHttpOverrides());
  });

  test(
    'resume reconnect emits onReconnect after the new socket connects',
    () async {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);

      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      var reconnectCount = 0;
      final reconnectSub = service.onReconnect.listen((_) {
        reconnectCount += 1;
      });
      addTearDown(reconnectSub.cancel);

      lifecycle.emit(AppLifecyclePhase.paused);
      lifecycle.emit(AppLifecyclePhase.resumed);
      await _flushMicrotasks(2);

      expect(socketFactory.sockets, hasLength(1));
      expect(reconnectCount, 0);

      socketFactory.sockets.single.id = 'session-after-resume';
      socketFactory.sockets.single.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(reconnectCount, 1);
    },
  );

  test(
    'resume reconnect still emits onReconnect after watchdog releases latch',
    () async {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);

      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
        resumeReconnectWatchdogTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(service.dispose);

      var reconnectCount = 0;
      final reconnectSub = service.onReconnect.listen((_) {
        reconnectCount += 1;
      });
      addTearDown(reconnectSub.cancel);

      lifecycle.emit(AppLifecyclePhase.paused);
      lifecycle.emit(AppLifecyclePhase.resumed);
      await _flushMicrotasks(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(socketFactory.sockets, hasLength(1));
      expect(reconnectCount, 0);

      socketFactory.sockets.single.id = 'slow-session-after-resume';
      socketFactory.sockets.single.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(reconnectCount, 1);
    },
  );

  test('resume reconciles an already-connected background lease without replacing it', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);
    var reconnectCount = 0;
    final reconnectSub = service.onReconnect.listen((_) => reconnectCount++);
    addTearDown(reconnectSub.cancel);

    await service.connect();
    final socket = socketFactory.sockets.single;
    socket.connected = true;
    socket.id = 'leased-background-session';
    socket.emitReserved('connect');
    await _flushMicrotasks(2);
    final lease = service.acquireBackgroundActivityLease();
    addTearDown(lease.dispose);

    lifecycle.emit(AppLifecyclePhase.paused);
    expect(socket.connected, isTrue);
    expect(socket.io.reconnection, isTrue);

    lifecycle.emit(AppLifecyclePhase.resumed);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, hasLength(1));
    expect(service.socket, same(socket));
    expect(service.isConnected, isTrue);
    expect(reconnectCount, 1);
  });

  test('background disables reconnect for an idle socket', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    final socket = socketFactory.sockets.single;
    expect(socket.io.reconnection, isTrue);

    lifecycle.emit(AppLifecyclePhase.paused);
    expect(socket.io.reconnection, isFalse);
    expect(service.backgroundActivityLeaseCount, 0);
  });

  test('late reconnect success is retired while transport is gated', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);
    var reconnectSignals = 0;
    final reconnectSub = service.onReconnect.listen((_) => reconnectSignals++);
    addTearDown(reconnectSub.cancel);

    await service.connect();
    final socket = socketFactory.sockets.single;
    socket.connected = true;
    socket.id = 'connected-before-pause';
    socket.emitReserved('connect');
    await _flushMicrotasks(2);
    expect(service.isConnected, isTrue);

    lifecycle.emit(AppLifecyclePhase.paused);
    socket.connected = true;
    socket.emitReserved('reconnect', 1);
    await _flushMicrotasks(2);

    expect(socket.io.reconnection, isFalse);
    expect(socket.connected, isFalse);
    expect(reconnectSignals, 0);
  });

  test(
    'late initial connect cannot authenticate after the app pauses',
    () async {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        authToken: 'session-token',
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);

      await service.connect();
      final socket = socketFactory.sockets.single;
      final outgoingEvents = <String>[];
      socket.onAnyOutgoing((event, _) => outgoingEvents.add(event.toString()));

      lifecycle.emit(AppLifecyclePhase.paused);
      // Model the platform delivering a successful handshake callback after the
      // pause already retired the negotiating transport.
      socket.connected = true;
      socket.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(socket.connected, isFalse);
      expect(socket.io.reconnection, isFalse);
      expect(outgoingEvents, isNot(contains('user-join')));
    },
  );

  test(
    'late forced connect cannot authenticate or signal reconnect when offline',
    () async {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);

      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        authToken: 'session-token',
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);
      var reconnectSignals = 0;
      final reconnectSub = service.onReconnect.listen(
        (_) => reconnectSignals++,
      );
      addTearDown(reconnectSub.cancel);

      lifecycle.emit(AppLifecyclePhase.paused);
      lifecycle.emit(AppLifecyclePhase.resumed);
      await _flushMicrotasks(2);
      final socket = socketFactory.sockets.single;
      final outgoingEvents = <String>[];
      socket.onAnyOutgoing((event, _) => outgoingEvents.add(event.toString()));

      service.updateNetworkAvailability(false);
      socket.connected = true;
      socket.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(socket.connected, isFalse);
      expect(socket.io.reconnection, isFalse);
      expect(outgoingEvents, isNot(contains('user-join')));
      expect(reconnectSignals, 0);
    },
  );

  test(
    'resume while offline reconciles after network recovery connects',
    () async {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);
      final socketFactory = _RecordingSocketFactory();
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        socketFactory: socketFactory.create,
      );
      addTearDown(service.dispose);
      var reconnectSignals = 0;
      final reconnectSub = service.onReconnect.listen((_) {
        reconnectSignals += 1;
      });
      addTearDown(reconnectSub.cancel);

      await service.connect();
      final socket = socketFactory.sockets.single;
      service.updateNetworkAvailability(false);
      lifecycle.emit(AppLifecyclePhase.paused);
      lifecycle.emit(AppLifecyclePhase.resumed);
      await _flushMicrotasks(2);

      expect(socket.io.reconnection, isFalse);
      expect(socketFactory.sockets, hasLength(1));
      expect(reconnectSignals, 0);

      service.updateNetworkAvailability(true);
      await _flushMicrotasks(2);

      expect(socketFactory.sockets, hasLength(2));
      final recoveredSocket = socketFactory.sockets.last;
      recoveredSocket.connected = true;
      recoveredSocket.id = 'recovered-after-offline-resume';
      recoveredSocket.emitReserved('connect');
      await _flushMicrotasks(2);

      expect(service.isConnected, isTrue);
      expect(reconnectSignals, 1);
    },
  );

  group('bounded pre-handler replay', () {
    Map<String, dynamic> event(
      String chatId,
      int sequence, {
      String payload = '',
      String? sessionId,
      String? messageId,
    }) {
      return {
        'chat_id': chatId,
        'session_id': ?sessionId,
        'message_id': ?messageId,
        'data': {
          'type': 'chat:message:delta',
          'data': {'sequence': sequence, 'content': payload},
        },
      };
    }

    test('replays in order and matches conversation/session aliases', () {
      final service = SocketService(serverConfig: _serverConfig);
      addTearDown(service.dispose);
      service.startBuffering(
        'chat-ordered',
        sessionId: 'session-ordered',
        messageId: 'message-ordered',
      );
      final acknowledged = <int>[];
      for (var index = 0; index < 3; index += 1) {
        service.debugHandleChatEvent(
          event(
            'chat-ordered',
            index,
            sessionId: 'session-ordered',
            messageId: 'message-ordered',
          ),
          (dynamic _) => acknowledged.add(index),
        );
      }
      final replayed = <int>[];

      service.addChatEventHandler(
        sessionId: 'session-ordered',
        handler: (socketEvent, ack) {
          replayed.add(
            (socketEvent['data']['data']['sequence'] as num).toInt(),
          );
          ack?.call('ack');
        },
      );

      expect(replayed, [0, 1, 2]);
      expect(acknowledged, [0, 1, 2]);
      expect(service.debugBufferedScopeCount, 0);
    });

    test('event count overflow drops the entire sequence and reports once', () {
      final service = SocketService(serverConfig: _serverConfig);
      addTearDown(service.dispose);
      service.startBuffering('chat-count');
      for (
        var index = 0;
        index <= SocketService.maxBufferedEventsPerScope;
        index += 1
      ) {
        service.debugHandleChatEvent(event('chat-count', index));
      }
      final reasons = <SocketReplayGapReason>[];
      var replayed = 0;

      service.addChatEventHandler(
        conversationId: 'chat-count',
        handler: (_, _) => replayed += 1,
      );
      service.addChatEventHandler(
        conversationId: 'chat-count',
        onReplayGap: reasons.add,
        handler: (_, _) => replayed += 1,
      );
      service.addChatEventHandler(
        conversationId: 'chat-count',
        onReplayGap: reasons.add,
        handler: (_, _) => replayed += 1,
      );

      expect(replayed, 0);
      expect(reasons, [SocketReplayGapReason.eventLimit]);
    });

    test('byte overflow and oversized events report distinct gaps', () {
      final service = SocketService(serverConfig: _serverConfig);
      addTearDown(service.dispose);
      service.startBuffering('chat-bytes');
      final boundedPayload = 'x' * 210000;
      for (var index = 0; index < 6; index += 1) {
        service.debugHandleChatEvent(
          event('chat-bytes', index, payload: boundedPayload),
        );
      }
      SocketReplayGapReason? byteReason;
      service.addChatEventHandler(
        conversationId: 'chat-bytes',
        onReplayGap: (reason) => byteReason = reason,
        handler: (_, _) => fail('partial byte-overflow replay'),
      );
      expect(byteReason, SocketReplayGapReason.byteLimit);

      service.startBuffering('chat-large');
      service.debugHandleChatEvent(
        event('chat-large', 0, payload: 'x' * 300000),
      );
      SocketReplayGapReason? largeReason;
      service.addChatEventHandler(
        conversationId: 'chat-large',
        onReplayGap: (reason) => largeReason = reason,
        handler: (_, _) => fail('oversized event replay'),
      );
      expect(largeReason, SocketReplayGapReason.eventTooLarge);
    });

    test('expired scopes and ninth-scope eviction leave gap tombstones', () {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);
      var now = DateTime(2026);
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        now: () => now,
      );
      addTearDown(service.dispose);
      service.startBuffering('chat-expired');
      service.debugHandleChatEvent(event('chat-expired', 0));
      now = now.add(const Duration(seconds: 31));
      SocketReplayGapReason? expiredReason;
      service.addChatEventHandler(
        conversationId: 'chat-expired',
        onReplayGap: (reason) => expiredReason = reason,
        handler: (_, _) => fail('expired event replay'),
      );
      expect(expiredReason, SocketReplayGapReason.expired);

      for (var index = 0; index < 9; index += 1) {
        service.startBuffering('scope-$index');
      }
      expect(service.debugBufferedScopeCount, 8);
      SocketReplayGapReason? evictionReason;
      service.addChatEventHandler(
        conversationId: 'scope-0',
        onReplayGap: (reason) => evictionReason = reason,
        handler: (_, _) => fail('evicted event replay'),
      );
      expect(evictionReason, SocketReplayGapReason.scopeEvicted);
    });

    test(
      'stopBuffering and dispose release buffered events and tombstones',
      () {
        final service = SocketService(serverConfig: _serverConfig);
        addTearDown(service.dispose);
        service.startBuffering('chat-stop');
        service.debugHandleChatEvent(event('chat-stop', 0));
        service.stopBuffering('chat-stop');
        var replayed = false;
        service.addChatEventHandler(
          conversationId: 'chat-stop',
          onReplayGap: (_) => fail('normal stop must not report a gap'),
          handler: (_, _) => replayed = true,
        );
        expect(replayed, isFalse);

        service.startBuffering('chat-dispose');
        service.debugHandleChatEvent(
          event('chat-dispose', 0, payload: 'x' * 300000),
        );
        expect(service.debugReplayGapCount, 1);
        service.dispose();
        expect(service.debugBufferedScopeCount, 0);
        expect(service.debugReplayGapCount, 0);
      },
    );

    test('token rotation reports a replay gap to pending handlers', () {
      final lifecycle = FakeAppLifecycle();
      addTearDown(lifecycle.dispose);
      final service = SocketService(
        lifecycle: lifecycle,
        serverConfig: _serverConfig,
        authToken: 'old-token',
      );
      addTearDown(service.dispose);
      service.startBuffering('chat-token');
      service.debugHandleChatEvent(event('chat-token', 0));

      service.updateAuthToken('new-token');

      SocketReplayGapReason? reason;
      service.addChatEventHandler(
        conversationId: 'chat-token',
        onReplayGap: (value) => reason = value,
        handler: (_, _) => fail('token-rotated deltas must not replay'),
      );
      expect(reason, SocketReplayGapReason.scopeEvicted);
    });
  });

  test('active stream lease keeps reconnect enabled in background', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    await service.connect();
    final subscription = service.addChatEventHandler(
      sessionId: 'stream-session',
      requireFocus: false,
      keepsAliveInBackground: true,
      handler: (_, _) {},
    );
    lifecycle.emit(AppLifecyclePhase.paused);

    expect(socketFactory.sockets.single.io.reconnection, isTrue);
    expect(service.backgroundActivityLeaseCount, 1);

    subscription.dispose();
    expect(socketFactory.sockets.single.io.reconnection, isFalse);
    expect(service.backgroundActivityLeaseCount, 0);
  });

  test('a handler lease does not create the initial transport', () async {
    final lifecycle = FakeAppLifecycle();
    addTearDown(lifecycle.dispose);
    final socketFactory = _RecordingSocketFactory();
    final service = SocketService(
      lifecycle: lifecycle,
      serverConfig: _serverConfig,
      socketFactory: socketFactory.create,
    );
    addTearDown(service.dispose);

    final subscription = service.addChatEventHandler(
      sessionId: 'detached-stream-session',
      requireFocus: false,
      keepsAliveInBackground: true,
      handler: (_, _) {},
    );
    addTearDown(subscription.dispose);
    await _flushMicrotasks(2);

    expect(socketFactory.sockets, isEmpty);
    expect(service.backgroundActivityLeaseCount, 1);

    await service.connect();
    expect(socketFactory.sockets, hasLength(1));
  });
}

const _serverConfig = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
);

class _RecordingSocketService extends SocketService {
  _RecordingSocketService({Completer<void>? connectGate, super.lifecycle})
    : _connectGate = connectGate,
      super(serverConfig: _serverConfig);

  final Completer<void>? _connectGate;
  final List<bool> forceConnectCalls = <bool>[];

  @override
  Future<void> connect({bool force = false}) async {
    forceConnectCalls.add(force);
    final gate = _connectGate;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
  }
}

class _RecordingSocketFactory {
  final List<io.Socket> sockets = <io.Socket>[];
  final List<Map<String, String>> handshakeHeaders = <Map<String, String>>[];
  final List<Map<String, dynamic>> handshakeOptions = <Map<String, dynamic>>[];

  io.Socket create(
    String base,
    io.OptionBuilder builder,
    ServerConfig serverConfig,
  ) {
    final options = builder.build();
    handshakeOptions.add(Map<String, dynamic>.from(options));
    handshakeHeaders.add(
      Map<String, String>.from(
        options['extraHeaders'] as Map<dynamic, dynamic>? ?? const {},
      ),
    );
    final socket = io.io(
      'http://localhost:${19000 + sockets.length}',
      <String, dynamic>{
        'autoConnect': false,
        'forceNew': true,
        'reconnection': false,
      },
    );
    sockets.add(socket);
    return socket;
  }
}

class _RealHttpOverrides extends HttpOverrides {}
