import 'package:conduit/features/notes/utils/note_file_link_insertion.dart';
import 'package:conduit_core/features/notes/utils/note_file_cards.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_test/flutter_test.dart';

const rec = NoteFileLink(id: 'f1', name: 'Rec.m4a');
const doc = NoteFileLink(id: 'f2', name: 'Doc.pdf');

void main() {
  test('a card added to a note writes back as the link the server reads', () {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown('hello'),
    );
    addTearDown(controller.dispose);

    insertNoteFileCardsInEditor(controller, const [rec]);

    final markdown = noteMarkdownFromDocument(controller.document);
    expect(noteFileLinksInMarkdown(markdown), const [rec]);
    expect(markdown, startsWith('hello'));
    expect(
      markdown.trimRight(),
      endsWith('\n[Rec.m4a](/api/v1/files/f1/content)'),
    );
  });

  test('cards go in at the cursor, in order, each on its own line', () {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown('first\n\nsecond'),
    );
    addTearDown(controller.dispose);

    insertNoteFileCardsInEditor(controller, const [rec, doc], index: 6);

    expect(noteFileCardsIn(controller.document), const [rec, doc]);
    final markdown = noteMarkdownFromDocument(controller.document);
    expect(markdown.indexOf('first'), lessThan(markdown.indexOf('Rec.m4a')));
    expect(markdown.indexOf('Doc.pdf'), lessThan(markdown.indexOf('second')));
  });

  test('a removed card leaves the rest of the note', () {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown(
        'hello\n\n[Rec.m4a](/api/v1/files/f1/content)\n\nbye',
      ),
    );
    addTearDown(controller.dispose);

    expect(removeNoteFileCardsInEditor(controller, 'f1'), isTrue);
    expect(removeNoteFileCardsInEditor(controller, 'f1'), isFalse);

    final markdown = noteMarkdownFromDocument(controller.document);
    expect(noteFileLinksInMarkdown(markdown), isEmpty);
    expect(markdown, contains('hello'));
    expect(markdown, contains('bye'));
  });

  for (final md in ['```\ncode\n```', '- item', '# Heading', '> quote']) {
    test('a card added after "$md" is a line of its own', () {
      final controller = FleatherController(
        document: noteDocumentFromMarkdown(md),
      );
      addTearDown(controller.dispose);

      insertNoteFileCardsInEditor(controller, const [rec]);

      final markdown = noteMarkdownFromDocument(controller.document);
      expect(noteFileLinksInMarkdown(markdown), const [rec], reason: markdown);
      expect(
        markdown.trimRight(),
        endsWith('\n[Rec.m4a](/api/v1/files/f1/content)'),
        reason: markdown,
      );
      // Read again, it is a card again.
      expect(noteFileCardsIn(noteDocumentFromMarkdown(markdown)), const [rec]);
    });
  }
}
