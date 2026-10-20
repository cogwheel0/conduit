/// One edit of a dictation run: replace [deleteLength] characters at [start]
/// with [insert], leaving the caret at [caret].
class NoteDictationEdit {
  const NoteDictationEdit({
    required this.start,
    required this.deleteLength,
    required this.insert,
  });

  final int start;
  final int deleteLength;
  final String insert;

  int get caret => start + insert.length;
}

/// Dictation into a note.
///
/// A recognizer reports the cumulative transcript, so each update replaces
/// the run the previous one inserted, at the same anchor, and the rest of the
/// document (and its formatting) stays as it was.
class NoteDictationRun {
  NoteDictationRun({required this.anchor});

  /// A run anchored at the selection: at its start when text is selected,
  /// else at the caret. [textLength] is the document's text length without
  /// its final line break, which is not editable.
  factory NoteDictationRun.at({
    required int selectionBase,
    required int selectionExtent,
    required int textLength,
  }) {
    final selected = selectionBase != selectionExtent;
    final anchor = selected
        ? (selectionBase < selectionExtent ? selectionBase : selectionExtent)
        : selectionBase;
    return NoteDictationRun(anchor: anchor.clamp(0, textLength));
  }

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Where the run starts in the document.
  final int anchor;

  /// How many characters the run holds now.
  int get length => _length;
  int _length = 0;

  /// The edit that makes the run [transcript] in a document whose text is
  /// [plain]; a space is added first when the text before the anchor does not
  /// end in one.
  NoteDictationEdit update(String plain, String transcript) {
    final needsLeadingSpace =
        anchor > 0 &&
        anchor <= plain.length &&
        !_whitespace.hasMatch(plain[anchor - 1]);
    final insert = needsLeadingSpace ? ' $transcript' : transcript;
    final edit = NoteDictationEdit(
      start: anchor,
      deleteLength: _length,
      insert: insert,
    );
    _length = insert.length;
    return edit;
  }
}
