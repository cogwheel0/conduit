@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/palette.dart';
import 'package:test/test.dart';

void main() {
  const commands = <PaletteCommandItem>[
    PaletteCommandItem(PaletteCommand.newChat, 'New Chat'),
    PaletteCommandItem(PaletteCommand.newTemporaryChat, 'New temporary chat'),
    PaletteCommandItem(PaletteCommand.openSettings, 'Settings'),
  ];

  List<PaletteCommand> match(String query) => matchCommands(
    query,
    commands,
  ).map((item) => item.command).toList(growable: false);

  group('matchCommands', () {
    test('an empty query offers everything', () {
      expect(match('  '), hasLength(3));
    });

    test('ignores case', () {
      expect(match('SETT'), <PaletteCommand>[PaletteCommand.openSettings]);
    });

    test('every word must match, in any order', () {
      expect(match('temp new'), <PaletteCommand>[
        PaletteCommand.newTemporaryChat,
      ]);
      expect(match('new'), <PaletteCommand>[
        PaletteCommand.newChat,
        PaletteCommand.newTemporaryChat,
      ]);
    });

    test('a word that matches nothing rules the command out', () {
      expect(match('new zebra'), isEmpty);
    });
  });

  group('movePaletteIndex', () {
    test('moves and wraps at both ends', () {
      expect(movePaletteIndex(0, 3, down: true), 1);
      expect(movePaletteIndex(2, 3, down: true), 0);
      expect(movePaletteIndex(0, 3, down: false), 2);
    });

    test('an empty list stays at zero', () {
      expect(movePaletteIndex(0, 0, down: true), 0);
    });
  });
}
