import 'package:conduit/features/notes/utils/note_file_link_insertion.dart';
import 'package:conduit_core/features/notes/utils/note_file_cards.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter/services.dart' show TextSelection;
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

  test('a selection that ends where cards go in does not take them in', () {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown('hello world'),
    );
    addTearDown(controller.dispose);
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );

    insertNoteFileCardsInEditor(controller, const [rec], index: 5);
    final selection = controller.selection;
    // Typing replaces the selected word, not the card after it.
    controller.replaceText(
      selection.start,
      selection.end - selection.start,
      'hi',
      selection: TextSelection.collapsed(offset: selection.start + 2),
    );

    expect(controller.selection.isValid, isTrue);
    expect(noteFileCardsIn(controller.document), const [rec]);
    expect(controller.document.toPlainText(), startsWith('hi\n'));
  });

  test('typing goes on after cards put in at the cursor mid-sentence', () {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown('hello world'),
    );
    addTearDown(controller.dispose);
    controller.updateSelection(const TextSelection.collapsed(offset: 5));

    insertNoteFileCardsInEditor(controller, const [rec, doc], index: 5);
    final cursor = controller.selection.baseOffset;
    controller.replaceText(
      cursor,
      0,
      '!',
      selection: TextSelection.collapsed(offset: cursor + 1),
    );

    final text = controller.document.toPlainText();
    expect(text.indexOf('!'), greaterThan(text.lastIndexOf('￼')));
    expect(text, contains('! world'));
    expect(text, startsWith('hello\n'));
  });

  test('a selection after a removed card keeps its text', () {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown(
        'hello\n\n[Rec.m4a](/api/v1/files/f1/content)\n\nbye',
      ),
    );
    addTearDown(controller.dispose);
    final bye = controller.document.toPlainText().indexOf('bye');
    controller.updateSelection(
      TextSelection(baseOffset: bye, extentOffset: bye + 3),
    );

    removeNoteFileCardsInEditor(controller, 'f1');

    final selection = controller.selection;
    expect(
      controller.document.toPlainText().substring(
        selection.start,
        selection.end,
      ),
      'bye',
    );
  });

  test('a cursor at the end stays inside the note when a card goes', () {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown(
        'hello\n\n[Rec.m4a](/api/v1/files/f1/content)',
      ),
    );
    addTearDown(controller.dispose);
    final end = controller.document.length - 1;
    controller.updateSelection(TextSelection.collapsed(offset: end));

    removeNoteFileCardsInEditor(controller, 'f1');

    expect(controller.selection.baseOffset, controller.document.length - 1);
  });

  test('undo after a card was removed brings the card back, and nothing '
      'else', () async {
    final controller = FleatherController(
      document: noteDocumentFromMarkdown(
        'hello\n\n[Rec.m4a](/api/v1/files/f1/content)\n\nbye',
      ),
    );
    addTearDown(controller.dispose);
    // An edit typed first, which the undo history holds.
    final end = controller.document.length - 1;
    controller.replaceText(
      end,
      0,
      '!',
      selection: TextSelection.collapsed(offset: end + 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));

    removeNoteFileCardsInEditor(controller, 'f1');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    controller.undo();

    expect(noteFileCardsIn(controller.document), const [rec]);
    final text = controller.document.toPlainText();
    expect(text, startsWith('hello\n'));
    expect(text, contains('bye!'));
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
