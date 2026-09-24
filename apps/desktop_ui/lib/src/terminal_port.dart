/// The terminal, as a port.
///
/// xterm.js and the shell's socket live in the browser, and the page that
/// shows them is tested on the VM -- the same reason [NoteEditorPort] is a
/// port. The page asks for a terminal in an element for a handle the daemon
/// gave it, and hears how the connection is doing.
abstract interface class TerminalViewPort {
  /// Draws a terminal in the element with [hostId] and connects it to
  /// `WS /terminal/{handle}`, a new shell.
  TerminalViewSession open(
    String hostId, {
    required String handle,
    required void Function(TerminalLinkState state) onState,
  });
}

enum TerminalLinkState { connecting, connected, disconnected, failed }

abstract interface class TerminalViewSession {
  /// Resizes the terminal to its element, after the element changed size
  /// in a way it cannot see -- going full screen, a panel closing.
  void fit();

  void focus();

  /// Copies the selection. False when nothing is selected.
  Future<bool> copy();

  /// Types the clipboard into the shell.
  Future<void> paste();

  /// Closes the shell and takes the terminal out of its element.
  void close();
}

/// Records what the page asked of it. The default outside a browser.
final class RecordingTerminalView implements TerminalViewPort {
  final List<RecordingTerminalViewSession> sessions =
      <RecordingTerminalViewSession>[];

  RecordingTerminalViewSession get last => sessions.last;

  @override
  TerminalViewSession open(
    String hostId, {
    required String handle,
    required void Function(TerminalLinkState state) onState,
  }) {
    final session = RecordingTerminalViewSession(hostId, handle, onState);
    sessions.add(session);
    onState(TerminalLinkState.connecting);
    return session;
  }
}

final class RecordingTerminalViewSession implements TerminalViewSession {
  RecordingTerminalViewSession(this.hostId, this.handle, this.report);

  final String hostId;
  final String handle;

  /// What the socket would say; a test calls it.
  final void Function(TerminalLinkState state) report;
  int fitted = 0;
  int focused = 0;
  int pasted = 0;
  bool closed = false;
  bool hasSelection = false;

  @override
  void fit() => fitted++;

  @override
  void focus() => focused++;

  @override
  Future<bool> copy() async => hasSelection;

  @override
  Future<void> paste() async => pasted++;

  @override
  void close() => closed = true;
}
