import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/services/engine_io_polling_socket_io.dart';
import 'package:test/test.dart';
import 'package:web_socket/web_socket.dart' as ws;

import 'fake_engine_io_server.dart';

void main() {
  late FakeEngineIoServer server;
  late HttpClient client;

  Uri pollingUrl() => Uri.parse(
    '${server.url.replaceFirst('http', 'ws')}'
    '/ws/socket.io/?EIO=4&transport=polling',
  );

  Future<EngineIoPollingSocket> open({Map<String, String>? headers}) async {
    final socket = await EngineIoPollingSocket.connect(
      pollingUrl(),
      client: client,
      headers: headers,
    );
    addTearDown(socket.close);
    return socket;
  }

  setUp(() async {
    server = await FakeEngineIoServer.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  test(
    'handshakes and polls over plain HTTP, one packet per message',
    () async {
      final socket = await open(headers: {'Authorization': 'Bearer token'});
      final events = StreamIterator(socket.events);

      check(await events.moveNext()).isTrue();
      final handshake = events.current as ws.TextDataReceived;
      check(handshake.text).startsWith('0{"sid":"eio-1"');
      check(socket.sid).equals('eio-1');

      server
        ..push('40{"sid":"socket-1"}')
        ..push('42["events",{"chat_id":"c1"}]');
      check(await events.moveNext()).isTrue();
      check(events.current).equals(ws.TextDataReceived('40{"sid":"socket-1"}'));
      check(await events.moveNext()).isTrue();
      check(events.current)
          .equals(ws.TextDataReceived('42["events",{"chat_id":"c1"}]'));

      check(server.upgradeRequests).isEmpty();
      final first = server.requests.first;
      check(first.method).equals('GET');
      check(first.transport).equals('polling');
      check(first.uri.queryParameters['EIO']).equals('4');
      check(first.sid).isNull();
      check(first.authorization).equals('Bearer token');
      final polls = server.requests.skip(1);
      check(polls).isNotEmpty();
      check(polls.map((r) => r.sid)).every((sid) => sid.equals('eio-1'));
      check(polls.map((r) => r.authorization))
          .every((value) => value.equals('Bearer token'));
    },
  );

  test('packets written together go in one POST, in order', () async {
    final socket = await open();
    socket
      ..sendText('40{"token":"t"}')
      ..sendText('42["user-join",{}]');
    await server.nextReceived((packet) => packet.startsWith('42'));
    socket.sendText('3');
    await server.nextReceived((packet) => packet == '3');

    check(server.postBodies).deepEquals([
      '40{"token":"t"}${FakeEngineIoServer.recordSeparator}42["user-join",{}]',
      '3',
    ]);
  });

  test('binary packets travel as base64', () async {
    final socket = await open();
    final events = StreamIterator(socket.events);
    check(await events.moveNext()).isTrue(); // The open packet.

    server.push('bAQID');
    check(await events.moveNext()).isTrue();
    check(events.current)
        .equals(ws.BinaryDataReceived(Uint8List.fromList([1, 2, 3])));

    socket.sendBytes(Uint8List.fromList([4, 5]));
    check(await server.nextReceived((p) => p.startsWith('b'))).equals('bBAU=');
  });

  test('the server closing the session ends the events', () async {
    final socket = await open();
    final events = socket.events.toList();
    server.push('1');

    final received = await events.timeout(const Duration(seconds: 5));
    check(
      received.last,
    ).equals(ws.CloseReceived(1000, 'The server closed the Engine.IO session'));
    check(() => socket.sendText('42[]')).throws<ws.WebSocketConnectionClosed>();
  });

  test('a failed poll ends the session as a dropped connection', () async {
    final socket = await open();
    server.failNextPollWith = HttpStatus.badRequest;

    final received = await socket.events.toList().timeout(
      const Duration(seconds: 5),
    );
    final close = received.last as ws.CloseReceived;
    check(close.code).equals(1006);
    check(close.reason).contains('400');
  });

  test('close tells the server, after what was still being sent', () async {
    final socket = await open();
    final done = socket.events.drain<void>();
    socket.sendText('41');
    await socket.close();
    await done.timeout(const Duration(seconds: 5));

    check(server.received).deepEquals(['41', '1']);
    // socket_io_client closes its transport without awaiting it.
    await socket.close();
    check(() => socket.sendText('42[]')).throws<ws.WebSocketConnectionClosed>();
  });

  test('a server that does not answer with an open packet fails the '
      'handshake', () async {
    final refused = EngineIoPollingSocket.connect(
      pollingUrl().replace(path: '/elsewhere/'),
      client: client,
    );
    await check(refused).throws<ws.WebSocketException>();
  });

  test('cookies the server sets are sent back for the session, in place of '
      'configured ones of the same name', () async {
    await server.close();
    server = await FakeEngineIoServer.start(
      handshakeCookies: [Cookie('lb', 'node-2')],
    );
    final socket = await open(
      headers: {'Cookie': 'lb=stale; proxy=configured'},
    );
    socket.sendText('40');
    await server.nextReceived((packet) => packet == '40');

    final post = server.requests.lastWhere((r) => r.method == 'POST');
    check(post.cookie).equals('proxy=configured; lb=node-2');
  });

  group('each POST stays within what the server decodes', () {
    test('at most 16 packets, the rest in order in later POSTs', () async {
      final socket = await open();
      final packets = [for (var i = 0; i < 40; i++) '42["n",$i]'];
      packets.forEach(socket.sendText);
      await server.nextReceived((packet) => packet == packets.last);

      check(server.received).deepEquals(packets);
      check(
        server.postBodies.map(
          (body) => body.split(FakeEngineIoServer.recordSeparator).length,
        ),
      ).deepEquals([16, 16, 8]);
    });

    test('no more bytes than the handshake allows', () async {
      await server.close();
      server = await FakeEngineIoServer.start(maxPayload: 50);
      final socket = await open();
      final packets = [for (var i = 0; i < 3; i++) '42["${'x' * 14}",$i]'];
      packets.forEach(socket.sendText);
      await server.nextReceived((packet) => packet == packets.last);

      check(server.received).deepEquals(packets);
      check(server.postBodies).length.equals(2);
      check(
        server.postBodies,
      ).every((body) => body.has((b) => b.length, 'length').isLessOrEqual(50));
    });
  });

  test('a POST counts as delivered only when the server says ok', () async {
    final socket = await open();
    final events = socket.events.toList();
    server.postReplyBody = 'OK'; // As python-engineio answers.
    socket.sendText('40');
    await server.nextReceived((packet) => packet == '40');

    server.postReplyBody = '<html>Sign in to the proxy</html>';
    socket.sendText('42["after"]');

    final received = await events.timeout(const Duration(seconds: 5));
    final close = received.last as ws.CloseReceived;
    check(close.code).equals(1006);
    check(close.reason).contains('send');
    check(server.received).deepEquals(['40', '42["after"]']);
  });

  test('a poll answered with no packets ends the session', () async {
    server.answerNextPollEmpty = true;
    final socket = await open();

    final received = await socket.events.toList().timeout(
      const Duration(seconds: 5),
    );
    final close = received.last as ws.CloseReceived;
    check(close.code).equals(1006);
    check(close.reason).contains('no packets');
    // Not polled again: whatever answers so would otherwise be asked at once,
    // over and over.
    check(server.requests.where((r) => r.method == 'GET' && r.sid != null))
        .length
        .equals(1);
  });

  test('close completes only once what was being sent has gone', () async {
    final socket = await open();
    final hold = server.holdPosts = Completer<void>();
    socket.sendText('41');
    await server.nextReceived((packet) => packet == '41');

    var closed = false;
    final closing = socket.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(closed).isFalse();

    hold.complete();
    await closing.timeout(const Duration(seconds: 5));
    check(server.received).deepEquals(['41', '1']);
  });

  test(
    'a response whose body stalls is let go when its time runs out',
    () async {
      await server.close();
      server = await FakeEngineIoServer.start(stallHandshakeBody: true);

      final stalled = EngineIoPollingSocket.connect(
        pollingUrl(),
        client: client,
        timeout: const Duration(milliseconds: 300),
      );
      await check(stalled).throws<TimeoutException>();

      // Aborting the request alone would keep the connection until the client
      // closes; cancelling the body releases it.
      await server.stalledResponseReleased.timeout(const Duration(seconds: 3));
    },
  );

  test('the client takes no longer to open a connection than a request may '
      'wait, since a request cannot stop an attempt still opening', () async {
    check(EngineIoPollingSocket.connectTimeout)
      ..isLessThan(EngineIoPollingSocket.handshakeTimeout)
      ..isLessThan(EngineIoPollingSocket.sendTimeout);

    final unbounded = HttpClient();
    addTearDown(() => unbounded.close(force: true));
    final quicker = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    addTearDown(() => quicker.close(force: true));
    for (final candidate in [unbounded, quicker]) {
      final socket = await EngineIoPollingSocket.connect(
        pollingUrl(),
        client: candidate,
      );
      await socket.close();
    }

    check(unbounded.connectionTimeout)
        .equals(EngineIoPollingSocket.connectTimeout);
    check(quicker.connectionTimeout).equals(const Duration(seconds: 3));
  });

  group('the connection limit follows a request time shorter than it', () {
    test('a short handshake timeout', () async {
      final fresh = HttpClient();
      addTearDown(() => fresh.close(force: true));
      final socket = await EngineIoPollingSocket.connect(
        pollingUrl(),
        client: fresh,
        timeout: const Duration(seconds: 2),
      );
      await socket.close();

      check(fresh.connectionTimeout).equals(const Duration(seconds: 2));
    });

    test('short ping values, which shorten each poll', () async {
      await server.close();
      // A poll may then take 1 s + 1 s + the 10 s margin.
      server = await FakeEngineIoServer.start(
        pingIntervalMs: 1000,
        pingTimeoutMs: 1000,
      );
      final fresh = HttpClient();
      addTearDown(() => fresh.close(force: true));
      final socket = await EngineIoPollingSocket.connect(
        pollingUrl(),
        client: fresh,
      );
      await socket.close();

      check(fresh.connectionTimeout).equals(const Duration(seconds: 12));
    });
  });

  group('a redirect to another origin is never followed', () {
    // What reaches the other origin, with the custom header it carried.
    late HttpServer elsewhere;
    late List<String> reachedElsewhere;
    const credentials = {'X-Api-Key': 'synthetic-key'};

    setUp(() async {
      reachedElsewhere = [];
      elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      elsewhere.listen((request) {
        reachedElsewhere.add(
          '${request.method} ${request.headers.value('x-api-key')}',
        );
        request.response.close();
      });
    });

    tearDown(() => elsewhere.close(force: true));

    Uri elsewhereUrl() => Uri.parse('http://127.0.0.1:${elsewhere.port}');

    test('for the handshake', () async {
      server.redirectTo = elsewhereUrl();

      final redirected = EngineIoPollingSocket.connect(
        pollingUrl(),
        client: client,
        headers: credentials,
      );
      await check(redirected).throws<ws.WebSocketException>(
        (refusal) => refusal.has((e) => e.message, 'message').contains('302'),
      );
      check(reachedElsewhere).isEmpty();
    });

    test('for a poll', () async {
      final socket = await open(headers: credentials);
      final events = socket.events.toList();
      server
        ..redirectTo = elsewhereUrl()
        ..push('2'); // Answers the held poll; the next one is redirected.

      final close = (await events.timeout(const Duration(seconds: 5))).last;
      check(close).isA<ws.CloseReceived>()
        ..has((c) => c.code, 'code').equals(1006)
        ..has((c) => c.reason, 'reason').contains('302');
      check(reachedElsewhere).isEmpty();
    });

    test('for a POST', () async {
      final socket = await open(headers: credentials);
      final events = socket.events.toList();
      // Redirect only once the first poll is held, so the POST meets it first.
      while (!server.requests.any((r) => r.method == 'GET' && r.sid != null)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      server.redirectTo = elsewhereUrl();
      socket.sendText('40');

      final close = (await events.timeout(const Duration(seconds: 5))).last;
      check(close).isA<ws.CloseReceived>()
        ..has((c) => c.code, 'code').equals(1006)
        ..has((c) => c.reason, 'reason').contains('303');
      check(reachedElsewhere).isEmpty();
    });
  });
}
