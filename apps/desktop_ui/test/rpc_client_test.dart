@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_desktop_ui/src/shell_bridge.dart';
import 'package:conduit_desktop_ui/src/rpc/rpc_client.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

const ShellBridge _bridge = ShellBridge(
  rpcPort: 4242,
  token: 'test-token',
  platform: 'linux',
  windowKind: WindowKind.headless,
  isElectron: true,
);

/// A stand-in daemon: a real `json_rpc_2` peer on the far end of an in-memory
/// channel, so the client under test speaks genuine JSON-RPC.
class FakeDaemon {
  FakeDaemon({this.protocolVersion = kConduitProtocolVersion});

  final String protocolVersion;

  /// One entry per connection the client opened, oldest first.
  final List<json_rpc.Peer> peers = <json_rpc.Peer>[];
  final List<EventSubscription> subscriptions = <EventSubscription>[];
  int handshakes = 0;

  json_rpc.Peer get latest => peers.last;

  Future<StreamChannel<String>> open(Uri uri, List<String> protocols) async {
    final controller = StreamChannelController<String>(allowForeignErrors: false);
    final peer = json_rpc.Peer(controller.foreign);
    peers.add(peer);

    peer.registerMethod(ConduitMethods.systemHandshake, (
      json_rpc.Parameters params,
    ) {
      handshakes++;
      final request = HandshakeRequest.fromJson(paramsToMap(params));
      if (request.protocolVersion != protocolVersion) {
        throw RpcError(
          code: ConduitErrorCodes.protocolVersionMismatch,
          args: <String, String>{
            'expected': protocolVersion,
            'actual': request.protocolVersion,
          },
        ).toException();
      }
      return HandshakeResponse(
        protocolVersion: protocolVersion,
        daemonVersion: '0.0.0-fake',
        sessionId: 'session-${peers.length}',
        capabilities: const Capabilities(notes: true),
        paths: const DaemonPaths(
          userData: '/tmp/u',
          database: '/tmp/u/db',
          cache: '/tmp/u/cache',
          logs: '/tmp/u/logs',
          staging: '/tmp/u/staging',
        ),
        platform: 'linux',
      ).toJson();
    });

    peer.registerMethod(ConduitMethods.systemPing, (json_rpc.Parameters _) =>
        const PongResult(uptimeMs: 1, serverTimeMs: 2).toJson());

    peer.registerMethod(ConduitMethods.eventsSubscribe, (
      json_rpc.Parameters params,
    ) {
      final subscription = EventSubscription.fromJson(paramsToMap(params));
      subscriptions.add(subscription);
      return subscription.toJson();
    });

    unawaited(peer.listen().catchError((_) {}));
    return controller.local;
  }

  /// Drops the current connection the way a crashed daemon would.
  Future<void> dropConnection() => latest.close();

  void push(EventEnvelope envelope) => sendEvent(latest, envelope);
}

RpcClient _client(FakeDaemon daemon, {int maxAttempts = 3}) => RpcClient(
  bridge: _bridge,
  clientVersion: '0.0.0-test',
  maxAttempts: maxAttempts,
  // Keep the heartbeat well clear of the test's own timing.
  heartbeatInterval: const Duration(seconds: 30),
  delay: (_) => Future<void>.value(),
  connect: daemon.open,
);

Future<void> _settle([int ticks = 12]) async {
  for (var i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('handshakes and reports the daemon capabilities', () async {
    final daemon = FakeDaemon();
    final client = _client(daemon);
    addTearDown(client.dispose);

    unawaited(client.start());
    await _settle();

    expect(client.current.state, CoreConnectionState.connected);
    expect(client.current.handshake?.daemonVersion, '0.0.0-fake');
    expect(client.current.capabilities.notes, isTrue);
  });

  test('a late subscriber still sees the current state', () async {
    // start() runs before the UI mounts, so a plain broadcast stream would
    // leave the first component waiting on a transition already past.
    final daemon = FakeDaemon();
    final client = _client(daemon);
    addTearDown(client.dispose);

    unawaited(client.start());
    await _settle();

    final seen = <CoreConnectionState>[];
    final subscription = client.connection.listen((c) => seen.add(c.state));
    addTearDown(subscription.cancel);
    await _settle();

    expect(seen, isNotEmpty);
    expect(seen.first, CoreConnectionState.connected);
  });

  test('a protocol version mismatch fails without retrying', () async {
    // Retrying cannot fix a version difference: it means the installed
    // binaries disagree, so hammering the socket only delays the message.
    final daemon = FakeDaemon(protocolVersion: '99.0.0');
    final client = _client(daemon);
    addTearDown(client.dispose);

    await client.start();

    expect(client.current.state, CoreConnectionState.failed);
    expect(
      client.current.error?.code,
      ConduitErrorCodes.protocolVersionMismatch,
    );
    expect(daemon.handshakes, 1, reason: 'must not retry a version mismatch');
  });

  test('reconnects after the daemon drops the socket', () async {
    final daemon = FakeDaemon();
    final client = _client(daemon);
    addTearDown(client.dispose);

    unawaited(client.start());
    await _settle();
    expect(client.current.state, CoreConnectionState.connected);

    await daemon.dropConnection();
    await _settle(40);

    expect(daemon.peers.length, greaterThanOrEqualTo(2));
    expect(client.current.state, CoreConnectionState.connected);
  });

  test('replays its subscription on reconnect', () async {
    // Subscriptions are declarative precisely so recovery is one call. If
    // this regresses, a reconnected window goes silent instead of erroring.
    final daemon = FakeDaemon();
    final client = _client(daemon);
    addTearDown(client.dispose);

    unawaited(client.start());
    await _settle();
    await client.subscribe(
      const EventSubscription(
        events: <String>[ConduitEvents.turnDelta],
        scopes: <String>['chat_a'],
      ),
    );
    await _settle();
    expect(daemon.subscriptions, hasLength(1));

    await daemon.dropConnection();
    await _settle(40);

    expect(daemon.subscriptions, hasLength(2));
    expect(daemon.subscriptions.last.scopes, <String>['chat_a']);
  });

  test('delivers events and notices a gap in the sequence', () async {
    final daemon = FakeDaemon();
    final client = _client(daemon);
    addTearDown(client.dispose);

    final received = <EventEnvelope>[];
    final subscription = client.events.listen(received.add);
    addTearDown(subscription.cancel);

    unawaited(client.start());
    await _settle();

    daemon.push(
      const EventEnvelope(event: ConduitEvents.syncStatus, seq: 1),
    );
    await _settle();
    expect(received, hasLength(1));
    expect(client.missedEvents, isFalse);

    // seq 2 never arrives: the client must notice rather than assume it can
    // keep patching its local state.
    daemon.push(
      const EventEnvelope(event: ConduitEvents.syncStatus, seq: 3),
    );
    await _settle();
    expect(received, hasLength(2));
    expect(client.missedEvents, isTrue);
    expect(client.lastSeq, 3);
  });

  test('refuses calls while disconnected instead of hanging', () async {
    final daemon = FakeDaemon(protocolVersion: '99.0.0');
    final client = _client(daemon);
    addTearDown(client.dispose);
    await client.start();

    expect(
      () => client.call<PongResult>(
        ConduitMethods.systemPing,
        decode: PongResult.fromJson,
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.daemonUnavailable,
        ),
      ),
    );
  });
}
