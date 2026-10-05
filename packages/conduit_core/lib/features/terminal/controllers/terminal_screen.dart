/// The terminal emulator a [TerminalSessionController] drives.
///
/// The app backs it with xterm's `Terminal` (the escape-sequence parser and
/// buffer) and renders that buffer with xterm's `TerminalView`. The core cannot
/// depend on xterm itself: the package declares a Flutter SDK dependency, so
/// a pure-Dart package cannot resolve it.
abstract interface class TerminalScreen {
  /// Columns and rows the emulator currently lays its grid out at.
  int get columns;
  int get rows;

  /// Feeds remote PTY output (escape sequences included) to the emulator.
  void write(String data);

  /// Empties the buffer and homes the cursor.
  void clear();

  /// Called with bytes the emulator wants to send to the PTY (keystrokes,
  /// pastes, terminal replies). Null detaches.
  set onOutput(void Function(String data)? handler);

  /// Called when the grid changes size, with the new size. Adapters pass the
  /// new values through: xterm's `Terminal.resize` calls its `onResize`
  /// before it updates `viewWidth`/`viewHeight`, so [columns] and [rows]
  /// still hold the old size at that point. Null detaches.
  set onResize(void Function(int columns, int rows)? handler);
}
