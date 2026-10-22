import 'package:conduit/features/chat/services/phonon_tts_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('app.cogwheel.conduit/phonon_tts');
  const events = 'app.cogwheel.conduit/phonon_tts/events';
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PhononTtsService service;
  late List<MethodCall> calls;
  setUp(() {
    service = PhononTtsService();
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel(events),
      (call) async => null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(const MethodChannel(events), null);
  });
  Future<void> speak() => service.speak(
    text: 'A voice test.',
    voiceIdentifier: 'system-default',
    rate: 0.5,
    pitch: 1,
    volume: 0.8,
    voiceCall: true,
  );
  Future<void> emit(
    int id, {
    String backend = 'phonon',
    String voice = PhononTtsService.voiceId,
  }) async {
    await messenger.handlePlatformMessage(
      events,
      codec.encodeSuccessEnvelope({
        'type': 'complete',
        'requestId': id,
        'backend': backend,
        'voice': voice,
      }),
      (_) {},
    );
    await pumpEventQueue();
  }

  test(
    'always binds the exact Zoey identity and no system rate/pitch controls',
    () async {
      await speak();
      final arguments = calls.single.arguments as Map;
      expect(arguments['voiceIdentifier'], PhononTtsService.voiceId);
      expect(arguments['requestId'], 1);
      expect(arguments.containsKey('rate'), isFalse);
      expect(arguments.containsKey('pitch'), isFalse);
    },
  );
  test(
    'rejects foreign voice and stale completion after stop or replacement',
    () async {
      final received = <String>[];
      final subscription = service.events.listen(
        (event) => received.add(event.type),
      );
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      await speak();
      await emit(1, backend: 'system');
      await emit(1, voice: 'another-voice');
      await service.stop();
      await emit(1);
      await speak();
      await emit(1);
      expect(received, isEmpty);
      await emit(2);
      expect(received, ['complete']);
    },
  );
  test('failed preparation remains unavailable', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'phonon_load_failed');
    });
    expect(await service.isAvailable(), isFalse);
  });
}
