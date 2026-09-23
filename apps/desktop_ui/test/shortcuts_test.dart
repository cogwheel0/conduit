@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/shortcuts.dart';
import 'package:test/test.dart';

void main() {
  group('resolveShortcut', () {
    test('matches a chord exactly', () {
      expect(
        resolveShortcut(const KeyStroke('k', primary: true), typing: false),
        ShortcutAction.openPalette,
      );
    });

    test('a chord with an extra modifier is a different chord', () {
      // Cmd+Shift+K is not Cmd+K. Treating it as one means a binding added
      // later can never have the shifted variant.
      expect(
        resolveShortcut(
          const KeyStroke('k', primary: true, shift: true),
          typing: false,
        ),
        isNull,
      );
    });

    test('an unbound key resolves to nothing', () {
      expect(resolveShortcut(const KeyStroke('q'), typing: false), isNull);
    });

    group('while typing', () {
      test('modified chords still fire', () {
        // The point of Cmd+K is reaching the palette from the composer.
        expect(
          resolveShortcut(const KeyStroke('k', primary: true), typing: true),
          ShortcutAction.openPalette,
        );
      });

      test('Esc reaches the running turn from inside the composer', () {
        // Where the hand already is when an answer runs long.
        expect(
          resolveShortcut(const KeyStroke('escape'), typing: true),
          ShortcutAction.stopGenerating,
        );
      });

      test('a binding without whileTyping is suppressed', () {
        const table = <Shortcut>[
          Shortcut(ShortcutAction.newChat, KeyStroke('n')),
        ];
        expect(
          resolveShortcut(const KeyStroke('n'), typing: false, table: table),
          ShortcutAction.newChat,
        );
        // Otherwise the letter never reaches the message being written.
        expect(
          resolveShortcut(const KeyStroke('n'), typing: true, table: table),
          isNull,
        );
      });
    });

    test('every default binding is reachable and unique', () {
      // A duplicate chord makes one of the two dead, and the loser is
      // whichever happens to be second in the list.
      final seen = <KeyStroke>{};
      for (final shortcut in defaultShortcuts) {
        expect(
          seen.add(shortcut.stroke),
          isTrue,
          reason: '${shortcut.stroke} is bound twice',
        );
        expect(
          resolveShortcut(shortcut.stroke, typing: false),
          shortcut.action,
        );
      }
    });
  });

  group('describeStroke', () {
    test('uses the platform accelerator', () {
      const stroke = KeyStroke('o', primary: true, shift: true);
      expect(describeStroke(stroke, isMac: true), '⌘⇧O');
      expect(describeStroke(stroke, isMac: false), 'Ctrl+Shift+O');
    });

    test('names the keys that have no glyph', () {
      expect(describeStroke(const KeyStroke('escape'), isMac: false), 'Esc');
    });
  });

  group('sendsMessage', () {
    test('Enter sends', () {
      expect(
        sendsMessage(key: 'Enter', shift: false, isComposing: false),
        isTrue,
      );
    });

    test('Shift+Enter breaks the line', () {
      expect(
        sendsMessage(key: 'Enter', shift: true, isComposing: false),
        isFalse,
      );
    });

    test('Enter closing an IME candidate is not a send', () {
      // Otherwise half a Japanese sentence ships the moment the first
      // candidate is accepted.
      expect(
        sendsMessage(key: 'Enter', shift: false, isComposing: true),
        isFalse,
      );
    });
  });

  group('lastCodeBlock', () {
    test('returns the last of several', () {
      const reply = '''
Before.

```dart
void first() {}
```

Between.

```sh
echo second
```

After.
''';
      expect(lastCodeBlock(reply), 'echo second');
    });

    test('a block still streaming counts', () {
      // It is the one on screen, and the one the user is reaching for.
      expect(lastCodeBlock('Here:\n\n```dart\nvoid half('), 'void half(');
    });

    test('a tilde fence does not close a backtick fence', () {
      expect(
        lastCodeBlock('```\nkept\n~~~\nalso kept\n```'),
        'kept\n~~~\nalso kept',
      );
    });

    test('no fence at all is null', () {
      expect(lastCodeBlock('Just prose, with `inline code`.'), isNull);
    });
  });
}
