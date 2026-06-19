import 'package:checks/checks.dart';
import 'package:conduit/features/notes/utils/note_document_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('documentFromMarkdown', () {
    test('returns an empty document for blank input', () {
      check(documentFromMarkdown('').toPlainText().trim()).isEmpty();
      check(documentFromMarkdown('   \n  ').toPlainText().trim()).isEmpty();
    });

    test('preserves plain paragraph text', () {
      final doc = documentFromMarkdown('Just some plain text');
      check(doc.toPlainText()).contains('Just some plain text');
    });

    test('never throws on unusual input', () {
      // Unbalanced markers / stray syntax must fall back gracefully.
      for (final input in ['**unterminated', '> ', '[x](', '```', '#']) {
        check(documentFromMarkdown(input).toPlainText()).isNotNull();
      }
    });
  });

  group('markdown round-trips', () {
    String roundTrip(String md) =>
        markdownFromDocument(documentFromMarkdown(md));

    test('headings survive', () {
      check(roundTrip('# Heading one')).contains('# Heading one');
    });

    test('bold survives', () {
      check(roundTrip('Some **bold** text')).contains('**bold**');
    });

    test('italic survives', () {
      final out = roundTrip('Some *italic* text');
      check(out.contains('*italic*') || out.contains('_italic_')).isTrue();
    });

    test('strikethrough survives', () {
      check(roundTrip('A ~~struck~~ word')).contains('~~struck~~');
    });

    test('inline code survives', () {
      check(roundTrip('Call `foo()` now')).contains('`foo()`');
    });

    test('bullet lists survive', () {
      final out = roundTrip('- first\n- second');
      check(out).contains('first');
      check(out).contains('second');
      // The encoder may emit either '-' or '*' bullet markers.
      check(out.contains('- ') || out.contains('* ')).isTrue();
    });

    test('block quotes survive', () {
      check(roundTrip('> quoted line')).contains('> quoted line');
    });

    test('links survive', () {
      check(roundTrip('See [docs](https://example.com)'))
          .contains('[docs](https://example.com)');
    });
  });

  group('htmlFromDocument', () {
    test('emits HTML tags for formatted content', () {
      final html = htmlFromDocument(documentFromMarkdown('# Title'));
      check(html.toLowerCase()).contains('<h1');
    });

    test('emits paragraph markup for plain text', () {
      final html = htmlFromDocument(documentFromMarkdown('hello world'));
      check(html.toLowerCase()).contains('hello world');
    });

    test('returns a string for empty documents', () {
      check(htmlFromDocument(documentFromMarkdown(''))).isA<String>();
    });
  });
}
