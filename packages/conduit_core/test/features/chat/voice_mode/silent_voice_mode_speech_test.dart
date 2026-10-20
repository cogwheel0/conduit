import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  group('SilentVoiceModeSpeech', () {
    test('reports completion when the turn finishes, so listening resumes', () {
      final speech = SilentVoiceModeSpeech();
      addTearDown(speech.dispose);

      expect(speech.events, emits(isA<TtsCompleted>()));

      return speech.finishStreamingTts(finalText: 'Hello');
    });

    test('does not report completion before the turn finishes', () async {
      final speech = SilentVoiceModeSpeech();
      final events = <TtsEvent>[];
      final sub = speech.events.listen(events.add);

      await speech.startStreamingTts();
      await speech.feedStreamingText('Hello');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await speech.dispose();

      expect(events, isEmpty);
    });

    test('finishing after disposal is harmless', () async {
      final speech = SilentVoiceModeSpeech();
      await speech.dispose();

      await speech.finishStreamingTts();
    });

    test('the unbound provider closes the engine with its container', () async {
      final container = ProviderContainer();
      final speech = container.read(voiceModeSpeechProvider);
      var done = false;
      speech.events.listen((_) {}, onDone: () => done = true);

      container.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
    });
  });
}
