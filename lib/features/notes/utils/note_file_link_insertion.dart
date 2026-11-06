import 'package:fleather/fleather.dart';
import 'package:flutter/services.dart' show TextSelection;

import 'package:conduit_core/features/notes/utils/note_file_cards.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';

/// Puts a card for each of [files] into [controller]'s document, each on a
/// line of its own, at [index] or, without one, at the end: the way an Open
/// WebUI 0.12.5 note attaches a file. Returns the index after the last card.
///
/// Goes through the controller, so the editor shows the change, and the
/// selection is carried along: a cursor at [index] ends up after the cards,
/// so typing goes on where it was.
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
    final selection = controller.selection;
    final before = controller.document.length;
    controller.replaceText(at, 0, noteFileEmbed(id: file.id, name: file.name));
    final text = controller.document.toPlainText();
    final card = text.indexOf(EmbedNode.kObjectReplacementCharacter, at);
    if (card >= 0) {
      // A new line takes the style of the one it follows: a card in a code
      // block, list, quote or heading would be written back as no
      // attachment, so its line is plain.
      controller
        ..formatText(card, 0, ParchmentAttribute.block.unset)
        ..formatText(card, 0, ParchmentAttribute.heading.unset);
    }
    _carrySelection(
      controller,
      selection,
      at: at,
      change: controller.document.length - before,
    );
    // Past the card and the line break it ends with.
    at = card < 0 ? at : (card + 2).clamp(0, controller.document.length - 1);
  }
  return at;
}

/// Takes the cards for file [id] out of [controller]'s document, carrying
/// the selection along; true when there were any.
bool removeNoteFileCardsInEditor(FleatherController controller, String id) {
  // Last first, so the offsets still to go stay where they were.
  final offsets = noteFileCardOffsets(controller.document, id);
  for (final offset in offsets) {
    // A card is one character. Handing the moved selection over with the
    // edit keeps it inside the shorter document, and records the edit in
    // the undo history, which an Undo would otherwise apply out of place.
    controller.replaceText(
      offset,
      1,
      '',
      selection: _carried(controller.selection, at: offset, change: -1),
    );
  }
  return offsets.isNotEmpty;
}

/// Moves [selection], taken before [change] characters were put in at [at]
/// (or, for a negative [change], taken out there), to where its text is now.
void _carrySelection(
  FleatherController controller,
  TextSelection selection, {
  required int at,
  required int change,
}) {
  final moved = _carried(selection, at: at, change: change);
  if (moved != selection) {
    controller.updateSelection(moved, source: ChangeSource.local);
  }
}

/// [selection] moved past [change] characters put in at [at], or taken out
/// there for a negative [change].
TextSelection _carried(
  TextSelection selection, {
  required int at,
  required int change,
}) {
  if (!selection.isValid || change == 0) return selection;
  int carry(int offset) {
    if (offset < at) return offset;
    // A range that ends where the text goes in stays as it was, rather than
    // taking the new text in; a cursor there moves past it.
    if (change > 0 &&
        offset == at &&
        !selection.isCollapsed &&
        offset == selection.end) {
      return offset;
    }
    final moved = offset + change;
    return moved < at ? at : moved;
  }

  return selection.copyWith(
    baseOffset: carry(selection.baseOffset),
    extentOffset: carry(selection.extentOffset),
  );
}
