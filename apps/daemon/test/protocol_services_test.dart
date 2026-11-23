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

/// The services as a host other than the daemon builds them: over its
/// container, with its own system service, a session over an in-memory
/// channel, and no HTTP server.
void main() {
  late CoreRuntime runtime;

  setUp(() async {
    final temporary = Directory.systemTemp.createTempSync('conduitd_composed');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await startTestRuntime(temporary);
    addTearDown(runtime.dispose);
  });

  SystemService system() => SystemService(
    paths: testDaemonPaths,
    platform: 'ios',
    daemonVersion: '0.0.0-test',
    requestStop: (_) => fail('nothing here stops the host'),
  );

  /// Services stopped as the daemon stops them, after the test.
  ProtocolServices services({SystemService? reused}) {
    final services = ProtocolServices(
      events: EventBus(),
      system: reused ?? system(),
      ports: ProtocolHostPorts(
        uiRequests: runtime.uiRequests,
        handoff: runtime.handoff,
        openUrl: runtime.openUrl,
        calls: runtime.calls,
        apple: runtime.apple,
        location: runtime.location,
      ),
    );
    addTearDown(services.dispose);
    addTearDown(services.closeTransports);
    addTearDown(runtime.beginShutdown);
    return services;
  }

  json_rpc.Peer connect(ProtocolServices services) {
    final pipe = StreamChannelController<String>(sync: true);
    final session = services.openSession(pipe.local, sessionId: 'phone');
    addTearDown(session.close);
    unawaited(session.listen());
    final client = json_rpc.Peer(pipe.foreign);
    addTearDown(client.close);
    unawaited(client.listen());
    return client;
  }

  test('a session handshakes and reaches the services', () async {
    final built = services()..attach(runtime.container);
    final client = connect(built);

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

  test('a build that fails part-way still stops what it built', () async {
    // The host's system service fails as the last step.
    final built = services(reused: _RefusingSystem());

    expect(() => built.attach(runtime.container), throwsStateError);
    expect(built.isAttached, isFalse);
    expect(built.core.turns, isNull, reason: 'sessions see none of it');
    // The turns service was built and bound to the host's ports.
    expect(runtime.uiRequests.hermesChatOf, isNotNull);

    await built.closeTransports();
    await built.dispose();
    expect(runtime.uiRequests.hermesChatOf, isNull);
  });

  test(
    'sessions no longer reach the services closeTransports closed',
    () async {
      final built = services()..attach(runtime.container);
      expect(built.core.terminals, isNotNull);

      await built.closeTransports();
      final core = built.core;
      expect(core.terminals, isNull);
      expect(core.computer, isNull);
      expect(core.calls, isNull);
      expect(core.speech, isNull);
      expect(core.data, isNull);
      expect(core.chats, isNotNull);
    },
  );

  test('a system service used again reports the new container\'s '
      'capabilities', () async {
    final reused = system()
      ..capabilities = const Capabilities(notes: true, workspace: true);

    services(reused: reused).attach(runtime.container);

    expect(reused.capabilities, Capabilities.none);
  });
}

final class _RefusingSystem extends SystemService {
  _RefusingSystem()
    : super(
        paths: testDaemonPaths,
        platform: 'ios',
        daemonVersion: '0.0.0-test',
        requestStop: (_) {},
      );

  @override
  set capabilities(Capabilities value) => throw StateError('refused');
}
