import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/core/services/background_streaming_handler.dart';

void main() {
  test('builds typed platform lease payloads', () {
    final startedAt = DateTime.fromMillisecondsSinceEpoch(123456);

    final leases = buildBackgroundStreamLeasesForTesting(
      const ['voice-call'],
      requiresMicrophone: true,
      kind: BackgroundStreamKind.voice,
      startedAt: startedAt,
    );

    expect(leases, hasLength(1));
    expect(leases.single.toPlatformMap(), {
      'id': 'voice-call',
      'kind': 'voice',
      'requiresMicrophone': true,
      'startedAt': 123456,
    });
  });

  test('filters socket keepalive before native lease creation', () {
    final leases = buildBackgroundStreamLeasesForTesting(
      const [BackgroundStreamingHandler.socketKeepaliveId, 'chat-stream-1'],
      requiresMicrophone: false,
      kind: BackgroundStreamKind.chat,
      startedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

    expect(leases.map((lease) => lease.id), ['chat-stream-1']);
  });

  test('does not create native leases for socket-only keepalive', () {
    final leases = buildBackgroundStreamLeasesForTesting(
      const [BackgroundStreamingHandler.socketKeepaliveId],
      requiresMicrophone: false,
      kind: BackgroundStreamKind.chat,
      startedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

    expect(leases, isEmpty);
  });
}
