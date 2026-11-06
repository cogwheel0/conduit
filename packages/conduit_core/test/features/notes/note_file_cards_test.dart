import 'package:checks/checks.dart';
import 'package:conduit_core/features/notes/utils/note_file_cards.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:test/test.dart';

const a = NoteFileLink(id: 'a', name: 'Rec A.m4a');
const b = NoteFileLink(id: 'b', name: 'B.pdf');
const linkA = '[Rec A.m4a](/api/v1/files/a/content)';
const linkB = '[B.pdf](/api/v1/files/b/content)';

void main() {
  test('a file link on a line of its own reads as a card', () {
    final doc = noteDocumentFromMarkdown('intro\n\n$linkA\n\noutro');
    check(noteFileCardsIn(doc)).deepEquals([a]);
    check(doc.toPlainText()).not((it) => it.contains('Rec A.m4a'));
  });

  test('a link inside a sentence, an image or a web link stays text', () {
    final doc = noteDocumentFromMarkdown(
      'see $linkA here\n\n[site](https://example.com)\n\n'
      '![pic](/api/v1/files/i/content)',
    );
    check(noteFileCardsIn(doc)).isEmpty();
  });

  test('two links to one file, apart on a line, stay links with their own '
      'labels', () {
    const md = '[first](/api/v1/files/a/content) [second](/api/v1/files/a/content)';
    final doc = noteDocumentFromMarkdown(md);
    check(noteFileCardsIn(doc)).isEmpty();
    final markdown = noteMarkdownFromDocument(doc);
    check(markdown).contains('[first](/api/v1/files/a/content)');
    check(markdown).contains('[second](/api/v1/files/a/content)');
  });

  test('cards write back as the links they were read from', () {
    const md = 'intro\n\n$linkA\n\n$linkB\n\noutro';
    final markdown = noteMarkdownFromDocument(noteDocumentFromMarkdown(md));
    check(noteFileLinksInMarkdown(markdown)).deepEquals([a, b]);
    check(markdown).contains('intro');
    check(markdown).contains('outro');
    check(markdown.indexOf(linkA) < markdown.indexOf('outro')).isTrue();
    // Reading it again gives the same cards.
    check(noteFileCardsIn(noteDocumentFromMarkdown(markdown)))
        .deepEquals([a, b]);
  });

  test('finds the cards of a file, last first', () {
    final doc = noteDocumentFromMarkdown('$linkA\n\nx\n\n$linkB\n\n$linkA');
    final offsets = noteFileCardOffsets(doc, 'a');
    check(offsets).length.equals(2);
    check(offsets.first > offsets.last).isTrue();
    check(noteFileCardOffsets(doc, 'c')).isEmpty();
  });

  test('a card takes its link\'s line and adds no blank lines', () {
    for (final md in [
      'intro\n\n$linkA\n\noutro',
      '$linkA\n\noutro',
      'intro\n\n$linkA',
      linkA,
    ]) {
      final once = noteMarkdownFromDocument(noteDocumentFromMarkdown(md));
      final twice = noteMarkdownFromDocument(noteDocumentFromMarkdown(once));
      check(because: md, once.trim()).equals(md.trim());
      check(because: md, twice).equals(once);
    }
  });

  test('a link in a list or under a heading stays a link', () {
    final doc = noteDocumentFromMarkdown('- $linkA\n\n## $linkB');
    check(noteFileCardsIn(doc)).isEmpty();
  });

  test('a link written as code stays code', () {
    final doc = noteDocumentFromMarkdown('`$linkA`');
    check(noteFileCardsIn(doc)).isEmpty();
  });
}
