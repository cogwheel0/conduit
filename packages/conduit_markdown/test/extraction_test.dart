import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:test/test.dart';

/// Guards the extraction itself.
///
/// The parsers' detailed behaviour is covered by the Flutter app's suite,
/// which still exercises them through the renderer. What is new — and what
/// these check — is that they work standalone: no Flutter binding, no
/// `dart:io`, nothing that the desktop renderer cannot provide.
void main() {
  group('preprocessor', () {
    test('normalizes without a Flutter binding', () {
      // The point is that this runs at all under plain `dart test`. Before
      // the extraction these lived under lib/shared/widgets and could only
      // be exercised with flutter_test.
      expect(ConduitMarkdownPreprocessor.normalize(''), isEmpty);
      final normalized = ConduitMarkdownPreprocessor.normalize('**bold**');
      expect(normalized, contains('bold'));
    });

    test('strips link reference definitions', () {
      final stripped = ConduitMarkdownPreprocessor.stripLinkReferenceDefinitions(
        'text\n\n[ref]: https://example.com\n',
      );
      expect(stripped, isNot(contains('https://example.com')));
      expect(stripped, contains('text'));
    });
  });

  group('citations', () {
    test('extracts source ids from bracket runs', () {
      expect(CitationParser.extractSourceIds('see [1] and [2,3]'), [1, 2, 3]);
    });

    test('returns nothing when there are no citations', () {
      expect(CitationParser.extractSourceIds('plain text'), isEmpty);
    });
  });

  group('reasoning', () {
    test('splits a think block out of surrounding prose', () {
      final segments = ReasoningParser.segments('before<think>why</think>after');
      expect(segments, isNotNull);
      expect(segments!.length, greaterThan(1));
    });

    test('formats durations', () {
      expect(ReasoningParser.formatDuration(65), isNotEmpty);
    });
  });

  group('message segments', () {
    test('tags each segment kind exactly once', () {
      final text = MessageSegment.text('hello');
      expect(text.isText, isTrue);
      expect(text.isTool, isFalse);
      expect(text.isReasoning, isFalse);
    });
  });
}
