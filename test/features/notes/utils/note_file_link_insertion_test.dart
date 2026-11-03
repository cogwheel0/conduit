import 'package:conduit/features/notes/utils/note_document_codec.dart';
import 'package:conduit/features/notes/utils/note_file_link_insertion.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a link added to a note comes out as the markdown the server reads', () {
    final controller = FleatherController(
      document: documentFromMarkdown('hello'),
    );
    addTearDown(controller.dispose);

    appendNoteFileLinksToDocument(controller, const [
      NoteFileLink(id: 'f1', name: 'Rec.m4a'),
    ]);

    final markdown = markdownFromDocument(controller.document);
    expect(noteFileLinksInMarkdown(markdown), const [
      NoteFileLink(id: 'f1', name: 'Rec.m4a'),
    ]);
    expect(markdown, startsWith('hello'));
    // The link sits on a line of its own, after the text.
    expect(
      markdown.trimRight(),
      endsWith('\n[Rec.m4a](/api/v1/files/f1/content)'),
    );
  });

  test('links added to an empty note start on its first line', () {
    final controller = FleatherController(document: documentFromMarkdown(''));
    addTearDown(controller.dispose);

    appendNoteFileLinksToDocument(controller, const [
      NoteFileLink(id: 'a', name: 'A'),
      NoteFileLink(id: 'b', name: 'B'),
    ]);

    final markdown = markdownFromDocument(controller.document);
    expect(markdown.trimLeft(), startsWith('[A](/api/v1/files/a/content)'));
    expect(noteFileLinksInMarkdown(markdown).map((link) => link.id), [
      'a',
      'b',
    ]);
  });

  test('a link removed from the markdown leaves the rest of the note', () {
    final controller = FleatherController(
      document: documentFromMarkdown('hello'),
    );
    addTearDown(controller.dispose);
    appendNoteFileLinksToDocument(controller, const [
      NoteFileLink(id: 'f1', name: 'Rec.m4a'),
    ]);

    final removed = removeNoteFileLinks(
      markdownFromDocument(controller.document),
      'f1',
    );

    expect(noteFileLinksInMarkdown(removed), isEmpty);
    expect(documentFromMarkdown(removed).toPlainText().trim(), 'hello');
  });
}
