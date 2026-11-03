import 'package:fleather/fleather.dart';

import 'package:conduit_core/features/notes/utils/note_file_cards.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';

/// Puts a card for each of [files] into [controller]'s document, each on a
/// line of its own, at [index] or, without one, at the end: the way an Open
/// WebUI 0.12.5 note attaches a file. Returns the index after the last card.
///
/// Goes through the controller, so the editor shows the change and the
/// selection is carried along.
int insertNoteFileCardsInEditor(
  FleatherController controller,
  Iterable<NoteFileLink> files, {
  int? index,
}) {
  var at = (index ?? controller.document.length - 1).clamp(
    0,
    controller.document.length - 1,
  );
  for (final file in files) {
    controller.replaceText(at, 0, noteFileEmbed(id: file.id, name: file.name));
    final text = controller.document.toPlainText();
    final card = text.indexOf(EmbedNode.kObjectReplacementCharacter, at);
    // Past the card and the line break it ends with.
    at = card < 0 ? at : (card + 2).clamp(0, controller.document.length - 1);
  }
  return at;
}

/// Takes the cards for file [id] out of [controller]'s document; true when
/// there were any.
bool removeNoteFileCardsInEditor(FleatherController controller, String id) {
  final offsets = noteFileCardOffsets(controller.document, id);
  for (final offset in offsets) {
    controller.replaceText(offset, 1, '');
  }
  return offsets.isNotEmpty;
}
