import 'package:conduit/features/chat/services/tts_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsManager splitTextForSpeech', () {
    const sampleText =
        'Curious engineers optimize audio boundaries for smoother '
        'conversations. Another sentence follows to verify chunk '
        'merging behavior.';

    test('keeps sentence-level chunks for device mode', () async {
      await TtsManager.instance.updateConfig(
        const TtsConfig(preferServer: false),
      );

      final chunks = TtsManager.instance.splitTextForSpeech(sampleText);

      expect(chunks.length, 2);
    });

    test('keeps OpenWebUI-sized chunks for server mode', () async {
      await TtsManager.instance.updateConfig(
        const TtsConfig(preferServer: true),
      );

      final chunks = TtsManager.instance.splitTextForSpeech(sampleText);

      expect(chunks.length, 2);
    });
  });

  group('TtsManager getMessageContentParts', () {
    test('supports paragraphs mode like OpenWebUI', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'First paragraph\n\nSecond paragraph',
        splitOn: TtsManager.splitOnParagraphs,
      );

      expect(chunks, ['First paragraph', 'Second paragraph']);
    });

    test('supports none mode like OpenWebUI', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'One.\nTwo.',
        splitOn: TtsManager.splitOnNone,
      );

      expect(chunks, ['One.\nTwo.']);
    });

    test('strips details blocks before splitting', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        'Hello <details><summary>Hidden</summary>ignored</details> world.',
      );

      expect(chunks, ['Hello  world.']);
    });

    test('cleans markdown internally without caller preprocessing', () {
      final chunks = TtsManager.instance.getMessageContentParts(
        '## **Hello**\n- world',
        splitOn: TtsManager.splitOnNone,
      );

      expect(chunks, ['Hello\nworld']);
    });
  });
}
