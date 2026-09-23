/// The notes editor (M5), as a port.
///
/// Quill lives in the browser, and the pages that use it are tested on the
/// VM where it does not exist -- the same reason [WindowCommandsPort] is a
/// port. The page asks for an editor in an element and hears every edit as
/// the whole document, in Quill's ops; what the editor is stays here.
abstract interface class NoteEditorPort {
  /// Starts an editor in the element with [hostId], showing [ops].
  ///
  /// [onChange] hears the whole document after each edit the user makes,
  /// not edits made through [NoteEditorSession.replace].
  NoteEditorSession open(
    String hostId, {
    required List<Map<String, dynamic>> ops,
    required String placeholder,
    required void Function(List<Map<String, dynamic>> ops) onChange,
  });
}

abstract interface class NoteEditorSession {
  /// The document as it is now, in Quill's ops.
  List<Map<String, dynamic>> contents();

  /// Shows [ops] instead, without reporting it as an edit: the note as the
  /// daemon saved it, or as another window changed it.
  void replace(List<Map<String, dynamic>> ops);

  void focus();

  /// Takes the editor out of its element.
  void close();
}

/// Records what the page asked of it. The default outside a browser.
final class RecordingNoteEditor implements NoteEditorPort {
  final List<RecordingNoteSession> sessions = <RecordingNoteSession>[];

  RecordingNoteSession get last => sessions.last;

  @override
  NoteEditorSession open(
    String hostId, {
    required List<Map<String, dynamic>> ops,
    required String placeholder,
    required void Function(List<Map<String, dynamic>> ops) onChange,
  }) {
    final session = RecordingNoteSession(hostId, ops, onChange);
    sessions.add(session);
    return session;
  }
}

final class RecordingNoteSession implements NoteEditorSession {
  RecordingNoteSession(this.hostId, this.ops, this._onChange);

  final String hostId;
  List<Map<String, dynamic>> ops;
  final void Function(List<Map<String, dynamic>> ops) _onChange;
  bool closed = false;
  int focused = 0;

  /// What the user typing would do.
  void type(List<Map<String, dynamic>> next) {
    ops = next;
    _onChange(next);
  }

  @override
  List<Map<String, dynamic>> contents() => ops;

  @override
  void replace(List<Map<String, dynamic>> ops) => this.ops = ops;

  @override
  void focus() => focused++;

  @override
  void close() => closed = true;
}
