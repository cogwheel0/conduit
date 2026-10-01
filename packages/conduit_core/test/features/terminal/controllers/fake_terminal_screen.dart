import 'package:conduit_core/features/terminal/controllers/terminal_screen.dart';

/// Records what the session writes; a stand-in for the xterm adapters.
final class FakeTerminalScreen implements TerminalScreen {
  final StringBuffer written = StringBuffer();
  int clears = 0;
  void Function(String data)? output;
  void Function(int columns, int rows)? resized;

  @override
  int columns = 80;

  @override
  int rows = 24;

  @override
  void write(String data) => written.write(data);

  @override
  void clear() {
    clears++;
    written.clear();
  }

  @override
  set onOutput(void Function(String data)? handler) => output = handler;

  @override
  set onResize(void Function(int columns, int rows)? handler) =>
      resized = handler;
}
