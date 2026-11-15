@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/null_sink.dart';
import 'support/scripted_openai.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

/// Stopping the daemon while chats are still open in it: one that answered a
/// moment ago (its scope lingers for [TurnsService.lingerAfterTurn]), and one
/// still answering. Quitting the app right after a reply is the common case.
///
/// One daemon for the file: `CoreRuntime` keeps process-wide state.
void main() {
  late Directory tempDir;
  late DaemonServer server;
  late ScriptedOpenAi provider;
  late json_rpc.Peer peer;
  late String model;
  final received = <EventEnvelope>[];

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_shutdown');
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
    final port = await server.start();
    server.attachCore(
      await CoreRuntime.start(
        config: config,
        directories: directories,
        log: log,
      ),
    );
    provider = await ScriptedOpenAi.start();

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
    await peer.sendRequest(
      ConduitMethods.directSetPreferred,
      const DirectPreferred(preferred: true).toJson(),
    );
    await peer.sendRequest(
      ConduitMethods.directSetHistory,
      const DirectHistory(localOnly: true).toJson(),
    );
    final saved = DirectConnectionList.fromJson(
      (await peer.sendRequest(
        ConduitMethods.directSave,
        DirectConnectionEdit(
          name: 'Scripted',
          kind: DirectKind.openai,
          baseUrl: provider.baseUrl,
          manualModelIds: const <String>['scripted-model'],
        ).toJson(),
      )) as Map<String, dynamic>,
    );
    model = DirectModelId.encode(saved.connections.single.id, 'scripted-model');
    await peer.sendRequest(
      ConduitMethods.eventsSubscribe,
      const EventSubscription(events: <String>[ConduitEvents.turnFinished])
          .toJson(),
    );
  });

  tearDownAll(() async {
    await provider.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<SendTurnAccepted> send(String text) async => SendTurnAccepted.fromJson(
    (await peer.sendRequest(
      ConduitMethods.turnsSend,
      SendTurn(model: model, text: text).toJson(),
    )) as Map<String, dynamic>,
  );

  bool finished(String chatId) => received.any(
    (e) =>
        e.event == ConduitEvents.turnFinished && e.payload['chatId'] == chatId,
  );

  test('stops with one chat lingering after its answer and one still '
      'answering', () async {
    // Answered: its scope stays open for a while in case of a follow-up.
    final answered = await send('Say hello');
    await until(() => finished(answered.chatId));
    // Still answering when the stop comes.
    await send('hold:quit Thinking it over');
    await until(() => provider.requests.length >= 2);

    await server.stop().timeout(const Duration(seconds: 20));
  });
}
