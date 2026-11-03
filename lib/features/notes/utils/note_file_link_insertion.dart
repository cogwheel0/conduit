import 'package:fleather/fleather.dart';

import 'package:conduit_core/features/notes/utils/note_page_data.dart';

/// Adds a link to each of [links] at the end of [controller]'s document, each
/// on a line of its own, the way an Open WebUI 0.12.5 note attaches a file.
///
/// Goes through the controller, so the editor shows the change and the
/// selection stays where it was.
void appendNoteFileLinksToDocument(
  FleatherController controller,
  Iterable<NoteFileLink> links,
) {
  for (final link in links) {
    final document = controller.document;
    // Before the line break every document ends with.
    final index = document.length - 1;
    final prefix = document.toPlainText().trim().isEmpty ? '' : '\n';
    controller.replaceText(index, 0, '$prefix${link.name}');
    controller.formatText(
      index + prefix.length,
      link.name.length,
      ParchmentAttribute.link.fromString('/api/v1/files/${link.id}/content'),
    );
  }
}
