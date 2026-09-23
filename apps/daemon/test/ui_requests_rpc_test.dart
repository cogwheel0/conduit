@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/null_sink.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

/// A question from the core, across the RPC boundary and back (WP-3.6).
///
/// One daemon for the file.
///
/// `Hive.init` and `PreferencesStore` are process-global, so a second
/// `CoreRuntime` in this isolate would not be a second daemon -- it would be
/// the same global storage under a new container, which is not a thing the
/// product ever does. Tests that need isolation use a distinct server id.
void main() {
  late Directory tempDir;
  late DaemonServer server;
  late int port;
  late json_rpc.Peer peer;
  final received = <EventEnvelope>[];

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_ui_rpc');
    final config = BootstrapConfig(
      sessionToken: _token,
      masterKey: _masterKey,
      userDataDir: tempDir.path,
    );
    final directories = DaemonDirectories.create(tempDir.path);
    final log = DaemonLog(level: 'error', sink: NullSink());

    server = DaemonServer(
      config: config,
      directories: directories,
      daemonVersion: '0.0.0-test',
      log: log,
    );
    port = await server.start();
    server.attachCore(
      await CoreRuntime.start(
        config: config,
        directories: directories,
        log: log,
      ),
    );

    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(_token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    peer = json_rpc.Peer(socket.cast<String>());
    registerEventSink(peer, onEvent: received.add);
    unawaited(peer.listen());
    await callTyped<HandshakeResponse>(
      peer,
      ConduitMethods.systemHandshake,
      params: const HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'test',
        clientVersion: '0.0.0',
        windowKind: WindowKind.headless,
        locale: 'en',
      ).toJson(),
      decodeResult: HandshakeResponse.fromJson,
    );
  });

  tearDownAll(() async {
    await peer.close();
    await server.stop();
    await tempDir.delete(recursive: true);
  });

  Future<UiRequest> nextRequest() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final hit = received
          .where((e) => e.event == ConduitEvents.uiRequest)
          .lastOrNull;
      if (hit != null) {
        received.remove(hit);
        return UiRequest.fromJson(hit.payload);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('no ui.request arrived');
  }

  test('a window hears the question and its answer reaches the core', () async {
    final answer = server.uiRequests!.confirm(
      title: 'Run delete_file?',
      message: 'a.txt',
    );
    final request = await nextRequest();
    expect(request.messageArgs['title'], 'Run delete_file?');

    final result = await peer.sendRequest(
      ConduitMethods.uiRespond,
      UiResponse(requestId: request.requestId, choice: 'allow').toJson(),
    );
    expect((result as Map)['accepted'], isTrue);
    expect(await answer, isTrue);

    // Settled for every window, so none keeps offering it.
    expect(
      received.any(
        (e) =>
            e.event == ConduitEvents.uiSettled &&
            e.payload['requestId'] == request.requestId,
      ),
      isTrue,
    );
  });

  test('a second answer to the same question is refused', () async {
    final answer = server.uiRequests!.confirm(title: 'Again?');
    final request = await nextRequest();
    await peer.sendRequest(
      ConduitMethods.uiRespond,
      UiResponse(requestId: request.requestId, choice: 'deny').toJson(),
    );
    final late = await peer.sendRequest(
      ConduitMethods.uiRespond,
      UiResponse(requestId: request.requestId, choice: 'allow').toJson(),
    );
    expect((late as Map)['accepted'], isFalse);
    expect(await answer, isFalse);
  });
}
