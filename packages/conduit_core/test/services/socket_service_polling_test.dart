import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:test/test.dart';

import 'fake_engine_io_server.dart';

// Issue #848: an Open WebUI server with ENABLE_WEBSOCKET_SUPPORT=false serves
// Socket.IO over HTTP long-polling only.

ServerConfig _config(FakeEngineIoServer server) =>
    ServerConfig(id: 'polling-server', name: 'Polling server', url: server.url);

void main() {
  group('a server that allows only polling', () {
    late FakeEngineIoServer server;

    setUp(() async {
      server = await FakeEngineIoServer.start();
    });

    tearDown(() => server.close());

    test('is reached over HTTP long-polling, and its events arrive', () async {
      final service = SocketService(
        serverConfig: _config(server),
        authToken: 'token-1',
        allowWebsocketUpgrade: false,
      );
      addTearDown(service.dispose);
      final joined = server.nextReceived(
        (packet) => packet.startsWith('42["user-join"'),
      );

      check(await service.ensureConnected(timeout: const Duration(seconds: 5)))
          .isTrue();
      check(service.sessionId).equals(server.socketIoSid);
      check(service.currentTransport).equals('polling');
      check(server.upgradeRequests).isEmpty();
      check(await joined.timeout(const Duration(seconds: 5)))
          .contains('"token":"token-1"');

      final delivered = Completer<Map<String, dynamic>>();
      final subscription = service.addChatEventHandler(
        conversationId: 'chat-1',
        handler: (event, _) {
          if (!delivered.isCompleted) delivered.complete(event);
        },
      );
      addTearDown(subscription.dispose);
      server.push(
        '42["events",{"chat_id":"chat-1","message_id":"reply-1",'
        '"data":{"type":"chat:completion","data":{"content":"Hel"}}}]',
      );

      final event = await delivered.future.timeout(const Duration(seconds: 5));
      check(event['message_id']).equals('reply-1');
      check((event['data'] as Map)['type']).equals('chat:completion');
    });

    test('a session the server forgets is replaced by a new one', () async {
      final service = SocketService(
        serverConfig: _config(server),
        allowWebsocketUpgrade: false,
      );
      addTearDown(service.dispose);
      check(await service.ensureConnected(timeout: const Duration(seconds: 5)))
          .isTrue();
      final first = service.sessionId;

      // A server restart: the next poll is refused as an unknown session.
      server.failNextPollWith = 400;
      final reconnected = service.healthStream.firstWhere(
        (health) => health.isConnected && service.sessionId != first,
      );
      server.push('2'); // Wakes the held poll so the refusal is served next.
      await reconnected.timeout(const Duration(seconds: 10));

      check(service.isConnected).isTrue();
      check(service.sessionId).isNotNull().not((it) => it.equals(first!));
    });
  });

  group('the transports asked for', () {
    Map<String, dynamic> optionsFor({
      required bool websocketOnly,
      required bool allowWebsocketUpgrade,
    }) {
      late Map<String, dynamic> options;
      final service = SocketService(
        serverConfig: const ServerConfig(
          id: 'options',
          name: 'Options',
          url: 'https://example.com',
        ),
        websocketOnly: websocketOnly,
        allowWebsocketUpgrade: allowWebsocketUpgrade,
        socketFactory: (base, builder, _) {
          options = builder.build();
          return io.io(base, <String, dynamic>{
            'autoConnect': false,
            'forceNew': true,
            'reconnection': false,
          });
        },
      );
      addTearDown(service.dispose);
      unawaited(service.connect());
      return options;
    }

    test('are polling alone, with no upgrade, when the server allows only '
        'polling', () {
      final options = optionsFor(
        websocketOnly: false,
        allowWebsocketUpgrade: false,
      );
      check(options['transports'] as List).deepEquals(['polling']);
      check(options['upgrade']).equals(false);
      check(options['rememberUpgrade']).equals(false);
    });

    test('start on a WebSocket in polling mode on a native platform when the '
        'server allows one, since a polling session there cannot move', () {
      final options = optionsFor(
        websocketOnly: false,
        allowWebsocketUpgrade: true,
      );
      check(options['transports'] as List).deepEquals(['websocket']);
      check(options['upgrade']).equals(false);
    });

    test('are a WebSocket alone in WebSocket mode', () {
      final options = optionsFor(
        websocketOnly: true,
        allowWebsocketUpgrade: true,
      );
      check(options['transports'] as List).deepEquals(['websocket']);
    });
  });

  test(
    'polling mode falls back to polling where a WebSocket is refused',
    () async {
      // A server that allows WebSockets, behind a proxy that blocks them.
      final server = await FakeEngineIoServer.start();
      addTearDown(server.close);
      final service = SocketService(serverConfig: _config(server));
      addTearDown(service.dispose);

      check(await service.ensureConnected(timeout: const Duration(seconds: 5)))
          .isTrue();
      check(server.upgradeRequests).isNotEmpty();
      check(service.sessionId).equals(server.socketIoSid);
      check(service.currentTransport).equals('polling');
    },
  );

  test('a later service for the same server is not handed the earlier '
      "one's transports", () async {
    // On a fresh install the first socket starts in WebSocket mode, before the
    // server's policy (polling only) has loaded and the socket is replaced.
    final server = await FakeEngineIoServer.start();
    addTearDown(server.close);
    final first = SocketService(
      serverConfig: _config(server),
      websocketOnly: true,
    );
    await first.connect();
    first.dispose();

    final second = SocketService(
      serverConfig: _config(server),
      allowWebsocketUpgrade: false,
    );
    addTearDown(second.dispose);
    check(await second.ensureConnected(timeout: const Duration(seconds: 5)))
        .isTrue();
    check(second.currentTransport).equals('polling');
  });

  test('a server that redirects elsewhere is not followed by either '
      'transport, so its custom headers stay with it', () async {
    final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => elsewhere.close(force: true));
    final reachedElsewhere = <String?>[];
    elsewhere.listen((request) {
      reachedElsewhere.add(request.headers.value('x-api-key'));
      request.response.close();
    });
    final server = await FakeEngineIoServer.start();
    addTearDown(server.close);
    server.redirectTo = Uri.parse('http://127.0.0.1:${elsewhere.port}');

    final service = SocketService(
      serverConfig: _config(server)
          .copyWith(customHeaders: const {'X-Api-Key': 'synthetic-key'}),
      websocketOnly: true,
    );
    addTearDown(service.dispose);

    check(
      await service.ensureConnected(
        timeout: const Duration(milliseconds: 1500),
      ),
    ).isFalse();
    // The WebSocket was tried, then the polling fallback, and both refused
    // the redirect.
    check(server.requests.map((r) => r.transport)).contains('websocket');
    check(server.requests.map((r) => r.transport)).contains('polling');
    check(reachedElsewhere).isEmpty();
  });

  group('a socket the server never completed a handshake for', () {
    // The server accepts the WebSocket and refuses polling, so neither the
    // first attempt nor the polling fallback after it can connect.
    for (final upgrade in [
      FakeWebSocketUpgrade.acceptThenDrop,
      FakeWebSocketUpgrade.handshakeWithoutConnect,
    ]) {
      test(
        'is not connected and has no session id (${upgrade.name})',
        () async {
          final server = await FakeEngineIoServer.start(
            webSocketUpgrade: upgrade,
            allowPolling: false,
          );
          addTearDown(server.close);
          final service = SocketService(
            serverConfig: _config(server),
            websocketOnly: true,
          );
          addTearDown(service.dispose);

          check(
            await service.ensureConnected(
              timeout: const Duration(milliseconds: 1500),
            ),
          ).isFalse();
          // The transport did open: the server accepted the upgrade.
          check(server.upgradeRequests).isNotEmpty();
          check(service.isConnected).isFalse();
          check(service.sessionId).isNull();
          check(service.currentHealth.isConnected).isFalse();
        },
      );
    }
  });
}
