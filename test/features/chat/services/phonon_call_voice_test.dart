import 'dart:async';

import 'package:conduit/features/chat/services/native_tts_service.dart';
import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingVoice extends NativeTtsService {
  RecordingVoice({this.available = true});
  final bool available;
  final spoken = <String>[];
  final _events = StreamController<NativeTtsEvent>.broadcast();
  @override
  Future<bool> isAvailable() async => available;
  @override
  Stream<NativeTtsEvent> get events => _events.stream;
  void complete() => _events.add(const NativeTtsEvent(type: 'complete'));
  @override
  Future<bool> stop() async => true;
  @override
  Future<bool> speak({
    required String text,
    String? voiceIdentifier,
    required double rate,
    required double pitch,
    required double volume,
    bool voiceCall = false,
  }) async {
    spoken.add(text);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecordingVoice system;
  late RecordingVoice phonon;
  final manager = TtsManager.instance;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    system = RecordingVoice();
    phonon = RecordingVoice();
    await manager.debugSetNativeTtsService(system);
    await manager.debugSetPhononTtsService(phonon);
    manager.setVoiceCallActive(true);
  });
  tearDown(() async {
    await manager.reset();
    await manager.debugSetNativeTtsService(null);
    await manager.debugSetPhononTtsService(null);
    await system._events.close();
    await phonon._events.close();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Android calls reject a missing Zoey engine instead of using system TTS',
    () async {
      await manager.debugSetPhononTtsService(RecordingVoice(available: false));
      await expectLater(manager.initialize(), throwsA(isA<StateError>()));
      await expectLater(
        manager.startStreaming(useServer: true),
        throwsA(isA<StateError>()),
      );
      expect(system.spoken, isEmpty);
    },
  );

  test(
    'call speech uses only Phonon even when server speech is requested',
    () async {
      await manager.initialize(config: const TtsConfig(preferServer: true));
      final session = await manager.speak('Testing Zoey.', useServer: true);
      expect(session!.useServerTts, isFalse);
      expect(phonon.spoken, ['Testing Zoey.']);
      expect(system.spoken, isEmpty);
    },
  );

  test(
    'foreign system completion cannot advance a Phonon streaming turn',
    () async {
      await manager.initialize();
      await manager.startStreaming();
      await manager.feedStreamingText(
        'The first sentence carries enough words to stand alone. The second sentence also carries enough words to stand alone.',
      );
      final firstCount = phonon.spoken.length;
      expect(firstCount, 1);
      system.complete();
      await Future<void>.delayed(Duration.zero);
      expect(phonon.spoken.length, firstCount);
      await manager.finishStreaming(
        finalText: 'The first sentence carries enough words to stand alone. The second sentence also carries enough words to stand alone.',
      );
      phonon.complete();
      await Future<void>.delayed(Duration.zero);
      expect(phonon.spoken.length, 2);
    },
  );

  test('read aloud returns to its prior engine after hangup', () async {
    await manager.initialize();
    await manager.speak('Call voice.');
    await manager.reset();
    await manager.speak('Read aloud.', useServer: false);
    expect(phonon.spoken, ['Call voice.']);
    expect(system.spoken, ['Read aloud.']);
  });
}
