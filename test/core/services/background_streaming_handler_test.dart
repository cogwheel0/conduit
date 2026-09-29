import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/core/services/background_streaming_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds typed platform lease payloads', () {
    final startedAt = DateTime.fromMillisecondsSinceEpoch(123456);

    final leases = buildBackgroundStreamLeasesForTesting(
      const ['voice-call'],
      requiresMicrophone: true,
      kind: BackgroundStreamKind.voice,
      startedAt: startedAt,
    );

    expect(leases, hasLength(1));
    final lease = leases.single.toPlatform();
    expect(lease.id, 'voice-call');
    expect(lease.kind, PlatformBackgroundStreamKind.voice);
    expect(lease.requiresMicrophone, isTrue);
    expect(lease.startedAtMillis, 123456);
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

  test(
    'forwards native service failures with their exact stream owners',
    () async {
      List<String>? failedStreamIds;
      await BackgroundStreamingHandler.instance.initialize(
        serviceFailedCallback: (_, _, streamIds) {
          failedStreamIds = streamIds;
        },
      );

      BackgroundStreamingHandler.instance.serviceFailed(
        PlatformServiceFailureEvent(
          error: 'service stopped',
          errorType: 'native',
          streamIds: const <String>['chat-stream-assistant-1'],
        ),
      );

      check(failedStreamIds)
          .isNotNull()
          .deepEquals(const <String>['chat-stream-assistant-1']);
    },
  );
}
