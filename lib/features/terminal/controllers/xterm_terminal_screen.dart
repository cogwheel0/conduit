import 'package:conduit_core/features/terminal/controllers/terminal_screen.dart';
import 'package:xterm/xterm.dart';

/// The core's [TerminalScreen] over xterm: the [terminal] buffer the session
/// writes into, and the [controller] (selection) `TerminalView` renders with.
final class XtermTerminalScreen implements TerminalScreen {
  XtermTerminalScreen({int maxLines = 5000})
    : terminal = Terminal(maxLines: maxLines);

  final Terminal terminal;
  final TerminalController controller = TerminalController();

  @override
  int get columns => terminal.viewWidth;

  @override
  int get rows => terminal.viewHeight;

  @override
  void write(String data) => terminal.write(data);

  @override
  void clear() {
    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);
  }

  @override
  set onOutput(void Function(String data)? handler) =>
      terminal.onOutput = handler;

  @override
  set onResize(void Function(int columns, int rows)? handler) =>
      terminal.onResize = handler == null
      ? null
      : (width, height, pixelWidth, pixelHeight) => handler(width, height);
}
