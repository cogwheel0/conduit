import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/services/computer_socket_relay.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer backend;
  late ComputerSocketRelay relay;
  final peers = <WebSocket>[];
  final requests = <({String path, String? cookie, String? proxy})>[];
  var reject = false;

  Future<ComputerSocketRelay> start({
    ComputerSurface surface = ComputerSurface.browser,
    Map<String, String> cookies = const {'CF_Authorization': 'synthetic-proxy'},
    bool audio = false,
  }) => ComputerSocketRelay.start(
    ComputerConnection(
      surface: surface,
      streamUri: Uri.parse(
        'ws://127.0.0.1:${backend.port}/nested/${surface.name}/stream',
      ),
      proxyCookies: cookies,
      proxyHeaders: {'X-Proxy-Credential': 'synthetic-header'},
      audioAvailable: audio,
    ),
  );

  Future<WebSocket> connect(
    Uri uri, {
    String? origin = ComputerSocketRelay.viewerOrigin,
  }) => WebSocket.connect(
    uri.toString(),
    headers: {
      'origin': ?origin,
      // A WebView's unrelated cookies must never reach the backend.
      HttpHeaders.cookieHeader: 'unrelated=must-not-forward',
    },
  );

  setUp(() async {
    peers.clear();
    requests.clear();
    reject = false;
    backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    backend.listen((request) async {
      requests.add((
        path: request.uri.path,
        cookie: request.headers.value(HttpHeaders.cookieHeader),
        proxy: request.headers.value('X-Proxy-Credential'),
      ));
      if (reject) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      peers.add(socket);
      socket.listen(socket.add, onError: (_) {});
    });
    relay = await start();
  });
  tearDown(() async {
    await relay.close();
    for (final socket in peers) {
      unawaited(socket.close());
    }
    await backend.close(force: true);
  });

  test(
    'forwards text and binary frames with only the selected proxy cookies',
    () async {
      final socket = await connect(relay.streamUri);
      final frames = StreamIterator(socket);
      socket.add('synthetic input');
      expect(await frames.moveNext(), isTrue);
      expect(frames.current, 'synthetic input');
      socket.add([0, 1, 127, 255]);
      expect(await frames.moveNext(), isTrue);
      expect(frames.current, [0, 1, 127, 255]);
      expect(requests.single, (
        path: '/nested/browser/stream',
        cookie: 'CF_Authorization=synthetic-proxy',
        proxy: 'synthetic-header',
      ));
      await frames.cancel();
      await socket.close();
    },
  );

  test(
    'rejects missing or wrong origin, capability, endpoint, and query',
    () async {
      for (final origin in <String?>[null, 'https://untrusted.example']) {
        await expectLater(
          connect(relay.streamUri, origin: origin),
          throwsA(isA<WebSocketException>()),
        );
      }
      for (final uri in [
        relay.streamUri.replace(path: '/wrong/stream'),
        relay.streamUri.replace(path: '${relay.streamUri.path}/other'),
        relay.streamUri.replace(
          path: relay.streamUri.path.replaceAll('/stream', '/audio'),
        ),
        relay.streamUri.replace(query: 'target=untrusted'),
      ]) {
        await expectLater(connect(uri), throwsA(isA<WebSocketException>()));
      }
      expect(requests, isEmpty);
    },
  );

  test(
    'browser VNC and advertised desktop audio preserve the fixed upstream path',
    () async {
      var socket = await connect(
        relay.streamUri.replace(
          path: relay.streamUri.path.replaceAll('/stream', '/vnc'),
        ),
      );
      socket.add('vnc');
      expect(await socket.first, 'vnc');
      await socket.close();
      expect(requests.last.path, '/nested/browser/vnc');
      await relay.close();
      relay = await start(surface: ComputerSurface.desktop, audio: true);
      socket = await connect(
        relay.streamUri.replace(
          path: relay.streamUri.path.replaceAll('/stream', '/audio'),
        ),
      );
      socket.add('audio');
      expect(await socket.first, 'audio');
      await socket.close();
      expect(requests.last.path, '/nested/desktop/audio');
      await expectLater(
        connect(
          relay.streamUri.replace(
            path: relay.streamUri.path.replaceAll('/stream', '/vnc'),
          ),
        ),
        throwsA(isA<WebSocketException>()),
      );
    },
  );

  test('proxy denial and backend permanent close reach the viewer', () async {
    reject = true;
    var socket = await connect(relay.streamUri);
    await socket.drain<void>();
    expect(socket.closeCode, 4003);
    reject = false;
    socket = await connect(relay.streamUri);
    final frames = StreamIterator(socket);
    socket.add('ready');
    await frames.moveNext();
    unawaited(peers.last.close(4001));
    expect(await frames.moveNext(), isFalse);
    expect(socket.closeCode, 4001);
  });

  test(
    'disposal closes both peers and a new viewer inherits no cookies',
    () async {
      final socket = await connect(relay.streamUri);
      final frames = StreamIterator(socket);
      socket.add('ready');
      await frames.moveNext();
      final oldUri = relay.streamUri;
      await relay.close();
      expect(await frames.moveNext(), isFalse);
      await expectLater(connect(oldUri), throwsA(isA<SocketException>()));
      relay = await start(cookies: {});
      final next = await connect(relay.streamUri);
      next.add('new viewer');
      expect(await next.first, 'new viewer');
      expect(requests.last.cookie, isNull);
      await next.close();
    },
  );
}
