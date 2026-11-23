@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/core.dart';

/// The byte routes and tunnels with no HTTP server: what each answers, as
/// the daemon's shelf adapter passes it on. The token and origin gate is
/// the adapter's, and `daemon_server_test` covers it.
void main() {
  late CoreRuntime runtime;
  late ProtocolServices services;
  late MediaService media;
  late ProtocolByteRoutes routes;
  var built = false;

  setUp(() async {
    final temporary = Directory.systemTemp.createTempSync('conduitd_bytes');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await startTestCore(temporary);
    addTearDown(runtime.dispose);
    services = ProtocolServices(
      events: EventBus(),
      system: SystemService(
        paths: testDaemonPaths,
        platform: 'ios',
        daemonVersion: '0.0.0-test',
        requestStop: (_) {},
      ),
      ports: ProtocolHostPorts(window: runtime.window),
    );
    addTearDown(services.dispose);
    addTearDown(services.closeTransports);
    addTearDown(runtime.beginShutdown);
    media = MediaService(ownServer: () async => null);
    addTearDown(media.close);
    built = false;
    routes = ProtocolByteRoutes(
      services: () => built ? services : null,
      media: media,
    );
  });

  void build() {
    services.attach(runtime.container);
    built = true;
  }

  Future<ByteResponse> ask(
    String method,
    String target, {
    Map<String, String> headers = const <String, String>{},
    List<int> body = const <int>[],
  }) {
    final url = Uri.parse(target.substring(1));
    final answer = routes.handle(
      ByteRequest(
        method: method,
        url: url,
        headers: headers,
        read: () => Stream<List<int>>.value(body),
      ),
    );
    expect(answer, isNotNull, reason: '$target is a byte route');
    return answer!;
  }

  void expectProblem(ByteResponse answer, int status, String code) {
    expect(answer.status, status);
    expect(answer.headers['content-type'], 'application/json');
    expect(
      answer.headers,
      containsPair('access-control-allow-origin', isNotEmpty),
    );
    final body = jsonDecode(answer.body! as String) as Map<String, dynamic>;
    expect(body['code'], code);
  }

  test('other paths are not byte routes', () {
    for (final path in <String>['health', 'rpc', 'nowhere']) {
      expect(
        routes.handle(
          ByteRequest(
            method: 'GET',
            url: Uri.parse(path),
            headers: const <String, String>{},
            read: () => const Stream<List<int>>.empty(),
          ),
        ),
        isNull,
      );
    }
    expect(routes.tunnel('/files/s1/f1'), isNull);
  });

  test('before the services are built, the routes that need them say the '
      'core is starting', () async {
    for (final (method, path) in <(String, String)>[
      ('POST', ConduitHttpRoutes.upload),
      ('POST', ConduitHttpRoutes.terminalUpload),
      ('GET', ConduitHttpRoutes.file('s1', 'f1')),
      ('POST', ConduitHttpRoutes.transcribe),
      ('GET', ConduitHttpRoutes.recording('rec-1')),
      ('GET', ConduitHttpRoutes.tts('tts-1')),
    ]) {
      expectProblem(
        await ask(method, path),
        503,
        ConduitErrorCodes.daemonUnavailable,
      );
    }
    // Media needs no core.
    expectProblem(
      await ask('GET', '${ConduitHttpRoutes.media}/video?url=x'),
      404,
      ConduitErrorCodes.notFound,
    );
  });

  test('each route takes only its own method', () async {
    build();
    for (final (method, path, allowed) in <(String, String, String)>[
      ('GET', ConduitHttpRoutes.upload, 'POST only'),
      ('GET', ConduitHttpRoutes.terminalUpload, 'POST only'),
      ('GET', ConduitHttpRoutes.transcribe, 'POST only'),
      ('POST', ConduitHttpRoutes.file('s1', 'f1'), 'GET only'),
      ('POST', '${ConduitHttpRoutes.media}/image?url=x', 'GET only'),
      ('POST', ConduitHttpRoutes.recording('rec-1'), 'GET only'),
      ('POST', ConduitHttpRoutes.tts('tts-1'), 'GET only'),
    ]) {
      final answer = await ask(method, path);
      expect(answer.status, 405, reason: path);
      expect(answer.body, allowed, reason: path);
    }
  });

  test(
    'an upload names its file, percent-encoded, and needs an account',
    () async {
      build();
      expectProblem(
        await ask('POST', ConduitHttpRoutes.upload),
        400,
        ConduitErrorCodes.invalidParams,
      );
      expectProblem(
        await ask(
          'POST',
          ConduitHttpRoutes.upload,
          headers: const <String, String>{'x-conduit-filename': '%FF'},
        ),
        400,
        ConduitErrorCodes.invalidParams,
      );
      final answer = await ask(
        'POST',
        ConduitHttpRoutes.upload,
        headers: const <String, String>{'x-conduit-filename': 'tide.txt'},
        body: utf8.encode('high water'),
      );
      expect(answer.status, isNot(200));
      expect(
        answer.headers,
        containsPair('access-control-allow-origin', isNotEmpty),
      );
      expectProblem(
        await ask('POST', ConduitHttpRoutes.terminalUpload),
        400,
        ConduitErrorCodes.invalidParams,
      );
    },
  );

  test(
    'a file, a recording or a speech job that is not there is refused',
    () async {
      build();
      expectProblem(
        await ask('GET', '/files/s1'),
        404,
        ConduitErrorCodes.notFound,
      );
      for (final path in <String>[
        ConduitHttpRoutes.file('s1', 'f1'),
        ConduitHttpRoutes.recording('rec-1'),
        ConduitHttpRoutes.tts('tts-1'),
      ]) {
        final answer = await ask('GET', path);
        expect(answer.status, isNot(200), reason: path);
        expect(answer.headers['content-type'], 'application/json');
      }
    },
  );

  test('media names its kind and its address', () async {
    expectProblem(
      await ask('GET', '${ConduitHttpRoutes.media}/image'),
      404,
      ConduitErrorCodes.notFound,
    );
    // With no account, a site on this computer is no one's own server.
    final url = Uri.encodeQueryComponent('http://127.0.0.1:1/tide.png');
    final refused = await ask(
      'GET',
      '${ConduitHttpRoutes.media}/image?url=$url',
    );
    expectProblem(refused, 403, 'media.refused');
  });

  test('a tunnel to a handle that is not there is refused before it '
      'opens', () async {
    build();
    for (final (path, reason) in <(String, String)>[
      ('/terminal/nope', 'no such terminal'),
      ('/calls/nope', 'no such call'),
    ]) {
      final tunnel = routes.tunnel(path);
      expect(tunnel, isNotNull, reason: path);
      expect(tunnel!.join, isNull);
      expect(tunnel.refusal!.status, 404);
      expect(tunnel.refusal!.body, reason);
    }
  });

  test(
    'a terminal tunnel closes a plain channel when the handle goes',
    () async {
      build();
      final channel = StreamChannelController<dynamic>(sync: true);
      final received = channel.local.stream.toList();
      await services.terminals!.tunnel('gone', channel.foreign);
      expect(await received, isEmpty);
    },
  );
}
