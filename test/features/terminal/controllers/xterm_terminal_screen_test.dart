import 'package:checks/checks.dart';
import 'package:conduit/features/terminal/controllers/xterm_terminal_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a resize reports the new grid size to the session', () {
    final screen = XtermTerminalScreen();
    final reported = <(int, int)>[];
    final seenDuringCallback = <(int, int)>[];
    screen.onResize = (columns, rows) {
      reported.add((columns, rows));
      seenDuringCallback.add((screen.columns, screen.rows));
    };

    screen.terminal.resize(50, 20);

    check(reported).deepEquals([(50, 20)]);
    // xterm updates its view size only after the callback: reading the
    // screen there gave the previous size, which the session used to send.
    check(seenDuringCallback).deepEquals([(80, 24)]);
    check((screen.columns, screen.rows)).equals((50, 20));
  });
}
