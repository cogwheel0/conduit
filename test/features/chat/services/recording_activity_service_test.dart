import 'dart:async';

import 'package:conduit/features/chat/services/recording_activity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('test/conduit-recording-activity');
const _first = '00000000-0000-4000-8000-000000000001';
const _second = '00000000-0000-4000-8000-000000000002';

class _SupportedActivity extends RecordingActivityService {
  _SupportedActivity() : super(channel: _channel);
  @override
  bool get isSupportedPlatform => true;
}

Future<void> nativeStop(String id) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('stop', {'id': id}),
        ),
        (_) {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test('a retired owner cannot stop or end the next recording', () async {
    final service = _SupportedActivity();
    var firstStops = 0;
    var secondStops = 0;
    try {
      await service.start(_first, () async => firstStops++);
      await service.start(_second, () async => secondStops++);
      await service.end(_first);
      await nativeStop(_first);
      expect(firstStops, 0);
      expect(secondStops, 0);
      await nativeStop(_second);
      expect(secondStops, 1);
      expect(calls.where((call) => call.method == 'end').length, 1);
      for (final call in calls) {
        expect((call.arguments as Map).keys, ['id']);
      }
    } finally {
      await service.end(_second);
    }
  });

  testWidgets(
    'stop cancels a pending start without resurrecting its heartbeat',
    (tester) async {
      final pending = Completer<bool>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'start' ? pending.future : true;
      });
      final service = _SupportedActivity();
      final starting = service.start(_first, () async {});
      await tester.pump();
      await service.end(_first);
      pending.complete(true);
      await tester.pump();
      await starting;
      await tester.pump(const Duration(seconds: 30));
      expect(calls.where((call) => call.method == 'update'), isEmpty);
    },
  );

  testWidgets('heartbeat reports only committed progress and opaque identity', (
    tester,
  ) async {
    final service = _SupportedActivity();
    var saved = 2.5;
    final starting = service.start(
      _first,
      () async {},
      savedSeconds: () => saved,
    );
    await tester.pump();
    await starting;
    try {
      saved = 4;
      await tester.pump(const Duration(seconds: 10));
      final update = calls.singleWhere((call) => call.method == 'update');
      expect(update.arguments, {'id': _first, 'savedSeconds': 4.0});
    } finally {
      await service.end(_first);
    }
  });

  test('disabled Live Activities do not prevent capture', () async {
    messenger.setMockMethodCallHandler(_channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    final service = _SupportedActivity();
    try {
      expect(await service.start(_first, () async {}), isFalse);
    } finally {
      await service.end(_first);
    }
  });
}
