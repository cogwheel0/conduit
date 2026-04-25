import 'package:conduit/features/chat/services/voice_transcript_accumulator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceTranscriptAccumulator', () {
    test('updates the current segment with newer partials', () {
      final accumulator = VoiceTranscriptAccumulator();

      expect(
        accumulator.applyResult(
          recognizedWords: 'hello world',
          isFinalResult: false,
        ),
        'hello world',
      );
      expect(
        accumulator.applyResult(
          recognizedWords: 'hello world again',
          isFinalResult: true,
        ),
        'hello world again',
      );
      expect(accumulator.text, 'hello world again');
    });

    test('merges overlap when the recognizer restarts mid-turn', () {
      final accumulator = VoiceTranscriptAccumulator();

      accumulator.applyResult(
        recognizedWords: 'this is a long speech and another thing',
        isFinalResult: false,
      );

      expect(
        accumulator.applyResult(
          recognizedWords: 'and another thing plus more context',
          isFinalResult: false,
        ),
        'this is a long speech and another thing plus more context',
      );
    });

    test('treats close recognizer corrections as the same segment', () {
      final accumulator = VoiceTranscriptAccumulator();

      accumulator.applyResult(
        recognizedWords: 'recognize speech',
        isFinalResult: false,
      );

      expect(
        accumulator.applyResult(
          recognizedWords: 'recognized speech',
          isFinalResult: false,
        ),
        'recognized speech',
      );
    });

    test('ignores punctuation-only revisions when comparing segments', () {
      final accumulator = VoiceTranscriptAccumulator();

      accumulator.applyResult(
        recognizedWords: 'hello world',
        isFinalResult: false,
      );

      expect(
        accumulator.applyResult(
          recognizedWords: 'hello, world',
          isFinalResult: false,
        ),
        'hello, world',
      );
    });

    test('updates non-Latin partials instead of duplicating them', () {
      final accumulator = VoiceTranscriptAccumulator();

      accumulator.applyResult(recognizedWords: '你好', isFinalResult: false);

      expect(
        accumulator.applyResult(recognizedWords: '你好世界', isFinalResult: false),
        '你好世界',
      );
    });

    test('merges non-Latin overlap when the recognizer restarts mid-turn', () {
      final accumulator = VoiceTranscriptAccumulator();

      accumulator.applyResult(recognizedWords: '你好世界', isFinalResult: false);

      expect(
        accumulator.applyResult(recognizedWords: '世界和平', isFinalResult: false),
        '你好世界和平',
      );
    });

    test('finalizePending keeps the last partial transcript', () {
      final accumulator = VoiceTranscriptAccumulator();
      accumulator.applyResult(
        recognizedWords: 'partial transcript without final callback',
        isFinalResult: false,
      );

      expect(
        accumulator.finalizePending(),
        'partial transcript without final callback',
      );
    });
  });
}
