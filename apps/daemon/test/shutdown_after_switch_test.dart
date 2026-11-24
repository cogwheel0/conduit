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

import '../../../packages/conduit_services/test/support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';
import 'support/runtime.dart';
import '../../../packages/conduit_services/test/support/scripted_openai.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

/// Stopping the daemon while a Direct reply still streams across an account
/// change: the chat is kept on this device, so the change leaves it open and
/// the reply runs on, holding its database lease. Stopping must cut it off,
/// not wait for the provider to finish.
///
/// One daemon for the file: `CoreRuntime` keeps process-wide state.
void main() {
  test('stopping the daemon cuts off a Direct reply that ran on across an '
      'account change, rather than waiting for the provider', () async {
    final tempDir = await Directory.systemTemp.createTemp('conduitd_switch');
    addTearDown(() => tempDir.delete(recursive: true));
    final config = BootstrapConfig(
      sessionToken: _token,
      masterKey: _masterKey,
      userDataDir: tempDir.path,
    );
    final directories = DaemonDirectories.create(tempDir.path);
    final server = DaemonServer(
      config: config,
      directories: directories,
      daemonVersion: '0.0.0-test',
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    addTearDown(server.stop);
    final port = await server.start();
    server.attachCore(
      await startTestRuntime(tempDir, config: config, directories: directories),
    );
    final provider = await ScriptedOpenAi.start();
    addTearDown(provider.close);
    final owui = await FakeOwuiAuthServer.start(
      users: const {
        'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
      },
    );
    addTearDown(owui.close);

    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(_token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    final peer = json_rpc.Peer(socket.cast<String>());
    final received = <EventEnvelope>[];
    registerEventSink(peer, onEvent: received.add);
    unawaited(peer.listen());
    addTearDown(peer.close);
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
    final model = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
    await peer.sendRequest(
      ConduitMethods.eventsSubscribe,
      const EventSubscription(events: <String>[ConduitEvents.turnFinished])
          .toJson(),
    );

    // The provider streams a word, then holds the reply until the test ends.
    final asked = provider.asked('hold:ridge');
    final accepted = SendTurnAccepted.fromJson(
      (await peer.sendRequest(
        ConduitMethods.turnsSend,
        SendTurn(model: model, text: 'hold:ridge Thinking it over').toJson(),
      )) as Map<String, dynamic>,
    );
    await asked;

    // Signing in to an Open WebUI account changes its session and client; a
    // chat kept on this device is no account's, and stays open.
    await peer.sendRequest(
      ConduitMethods.accountsAdd,
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ).toJson(),
    );
    await peer.sendRequest(
      ConduitMethods.authLoginWithPassword,
      const PasswordLogin(
        username: 'ada@example.com',
        password: 'pw-ada',
      ).toJson(),
    );
    expect(
      received.where(
        (e) =>
            e.event == ConduitEvents.turnFinished &&
            e.payload['chatId'] == accepted.chatId,
      ),
      isEmpty,
      reason: 'the account change closed a chat it does not own',
    );

    // The provider still holds the reply: only a stop that cuts it off
    // returns.
    await server.stop().timeout(const Duration(seconds: 20));
  });
}
