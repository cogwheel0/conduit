@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/runtime.dart';

/// The services as a host other than the daemon composes them: over its
/// container, with its own system service, a session over an in-memory
/// channel, and no HTTP server.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late ProtocolServices services;
  late RpcSession session;
  late json_rpc.Peer client;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('conduitd_composed');
    runtime = await startTestRuntime(temporary);
    services = ProtocolServices.compose(
      runtime.container,
      events: EventBus(),
      system: SystemService(
        paths: testDaemonPaths,
        platform: 'ios',
        daemonVersion: '0.0.0-test',
        requestStop: (_) => fail('nothing here stops the host'),
      ),
      ports: ProtocolHostPorts(
        uiRequests: runtime.uiRequests,
        handoff: runtime.handoff,
        openUrl: runtime.openUrl,
        calls: runtime.calls,
        apple: runtime.apple,
        location: runtime.location,
      ),
    );
    final pipe = StreamChannelController<String>(sync: true);
    session = services.openSession(pipe.local, sessionId: 'phone');
    unawaited(session.listen());
    client = json_rpc.Peer(pipe.foreign);
    unawaited(client.listen());
  });

  tearDown(() async {
    await client.close();
    await session.close();
    runtime.beginShutdown();
    await services.closeTransports();
    await services.dispose();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('a session handshakes and reaches the services', () async {
    final handshake = HandshakeResponse.fromJson(
      await client.sendRequest(
        ConduitMethods.systemHandshake,
        const HandshakeRequest(
          protocolVersion: kConduitProtocolVersion,
          clientName: 'test',
          clientVersion: '0.0.0',
          windowKind: WindowKind.main,
          locale: 'en',
        ).toJson(),
      ) as Map<String, dynamic>,
    );
    expect(handshake.sessionId, 'phone');
    expect(handshake.platform, 'ios');
    expect(handshake.paths, testDaemonPaths);

    // A host that supplies no local speech engine offers none.
    final voice = VoiceSettings.fromJson(
      await client.sendRequest(ConduitMethods.voiceSettings)
          as Map<String, dynamic>,
    );
    expect(voice.localStt, isFalse);
  });
}
