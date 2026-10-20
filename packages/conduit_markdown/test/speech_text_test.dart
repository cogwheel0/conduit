import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

void main() {
  group('getMessageContentParts', () {
    test('merges short sentences the way Open WebUI does', () {
      expect(
        getMessageContentParts('Hi. There. This sentence is long enough.'),
        ['Hi. There. This sentence is long enough.'],
      );
      expect(
        getMessageContentParts(
          'Curious engineers optimize audio boundaries for smoother '
          'conversations. Another sentence follows to verify chunk merging.',
        ),
        hasLength(2),
      );
    });

    test('splits on paragraphs or not at all', () {
      expect(
        getMessageContentParts(
          'First paragraph\n\nSecond paragraph',
          splitOn: speechSplitOnParagraphs,
        ),
        ['First paragraph', 'Second paragraph'],
      );
      expect(
        getMessageContentParts('One.\nTwo.', splitOn: speechSplitOnNone),
        ['One.\nTwo.'],
      );
    });

    test('never speaks a reasoning block, even an open one', () {
      expect(
        getMessageContentParts(
          'Checking. <details type="reasoning" done="false">'
          '<summary>Thinking</summary>secret plans',
        ),
        ['Checking.'],
      );
    });
  });

  group('advanceStreamingChunks', () {
    test('holds the growing chunk back until the answer is done', () {
      final first = advanceStreamingChunks(
        chunks: const ['One sentence here.', 'Two is still'],
        fedChunkCount: 0,
        spokenText: '',
        finalized: false,
      );
      expect(first.chunks, ['One sentence here.']);
      final last = advanceStreamingChunks(
        chunks: const ['One sentence here.', 'Two is still going.'],
        fedChunkCount: first.fedChunkCount,
        spokenText: first.spokenText,
        finalized: true,
      );
      expect(last.chunks, ['Two is still going.']);
    });

    test('does not repeat what was heard when a block disappears', () {
      final heard = advanceStreamingChunks(
        chunks: const ['Tool output.', 'The answer.', 'More'],
        fedChunkCount: 0,
        spokenText: '',
        finalized: false,
      );
      final next = advanceStreamingChunks(
        chunks: const ['The answer.', 'More text.'],
        fedChunkCount: heard.fedChunkCount,
        spokenText: heard.spokenText,
        finalized: true,
      );
      expect(next.chunks, ['More text.']);
    });
  });
}
