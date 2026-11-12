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

  test('cookies the server sets are sent back for the session', () async {
    await server.close();
    server = await FakeEngineIoServer.start(
      handshakeCookies: [Cookie('lb', 'node-2')],
    );
    final socket = await open(headers: {'Cookie': 'proxy=configured'});
    socket.sendText('40');
    await server.nextReceived((packet) => packet == '40');

    final post = server.requests.lastWhere((r) => r.method == 'POST');
    check(post.cookie).equals('proxy=configured; lb=node-2');
  });
}
