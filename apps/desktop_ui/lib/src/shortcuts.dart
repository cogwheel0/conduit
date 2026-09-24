/// The keyboard layer (WP-3.7).
///
/// Deliberately free of `package:web`: a chord, the table and the matching
/// rules are values and pure functions, so the behaviour that is easy to get
/// wrong -- "does Ctrl+K fire the macOS binding", "does this swallow a
/// keystroke meant for the composer" -- is testable on the VM. The browser
/// only contributes the event, through [ShortcutDispatcher].
library;

/// What a shortcut does. One per binding, resolved by the page that owns the
/// affected control rather than by the engine.
enum ShortcutAction {
  newChat,
  openPalette,
  focusComposer,
  focusModelPicker,
  stopGenerating,
  openSettings,
  showShortcuts,
  copyLastResponse,
  copyLastCodeBlock,
  allowRequest,
  denyRequest,
  dictate,
  toggleSidebar,
  toggleSidePane,
}

/// A chord, as the user would describe it.
///
/// [primary] is Cmd on macOS and Ctrl everywhere else -- the same physical
/// gesture, which is why the table names one modifier rather than two.
class KeyStroke {
  const KeyStroke(
    this.key, {
    this.primary = false,
    this.shift = false,
    this.alt = false,
  });

  /// `KeyboardEvent.key`, lower-cased. `'k'`, `'.'`, `'escape'`.
  final String key;
  final bool primary;
  final bool shift;
  final bool alt;

  @override
  bool operator ==(Object other) =>
      other is KeyStroke &&
      other.key == key &&
      other.primary == primary &&
      other.shift == shift &&
      other.alt == alt;

  @override
  int get hashCode => Object.hash(key, primary, shift, alt);

  @override
  String toString() => describeStroke(this, isMac: false);
}

class Shortcut {
  const Shortcut(this.action, this.stroke, {this.whileTyping = false});

  final ShortcutAction action;
  final KeyStroke stroke;

  /// Whether the binding fires with the caret in a field.
  ///
  /// Off by default, and that default is the whole safety story: a bare
  /// letter bound to an action would otherwise eat a character out of the
  /// message someone is typing. Only chords that cannot be mistaken for
  /// typing turn it on.
  final bool whileTyping;
}

/// Open WebUI's defaults, for the actions this app can carry out today.
///
/// Section 5.2 lists more -- temporary chat, regenerate, tool
/// approve/deny, edit last message. Each waits on a feature that does not
/// exist yet (M4, and edit-and-branch in WP-3.2), and a shortcut
/// overlay that advertises a key doing nothing is worse than one that is
/// short: the user presses it, nothing happens, and they stop trusting the
/// list. They join this table with their features.
const List<Shortcut> defaultShortcuts = <Shortcut>[
  Shortcut(
    ShortcutAction.newChat,
    KeyStroke('o', primary: true, shift: true),
    whileTyping: true,
  ),
  // The command palette (WP-3.1), which is also where search lives: it
  // finds conversations as well as commands, so a separate "focus the
  // sidebar search" chord would be a second way to do half of this.
  Shortcut(
    ShortcutAction.openPalette,
    KeyStroke('k', primary: true),
    whileTyping: true,
  ),
  // Shift+Esc rather than Esc: plain Esc stops a running turn, and the two
  // are pressed in the same situation.
  Shortcut(
    ShortcutAction.focusComposer,
    KeyStroke('escape', shift: true),
    whileTyping: true,
  ),
  Shortcut(
    ShortcutAction.focusModelPicker,
    KeyStroke('m', primary: true, shift: true),
    whileTyping: true,
  ),
  // The one binding that has to work from inside the composer, because
  // that is where the hand already is when an answer runs long.
  Shortcut(
    ShortcutAction.stopGenerating,
    KeyStroke('escape'),
    whileTyping: true,
  ),
  Shortcut(
    ShortcutAction.openSettings,
    KeyStroke('.', primary: true),
    whileTyping: true,
  ),
  Shortcut(
    ShortcutAction.showShortcuts,
    KeyStroke('/', primary: true),
    whileTyping: true,
  ),
  Shortcut(
    ShortcutAction.copyLastResponse,
    KeyStroke('c', primary: true, shift: true),
    whileTyping: true,
  ),
  // Answer the server's waiting request (WP-3.6). Alt as well as the
  // accelerator, so neither can be pressed by accident while typing.
  // Allowing a tool to run should take a deliberate chord.
  Shortcut(
    ShortcutAction.allowRequest,
    KeyStroke('enter', primary: true, alt: true),
    whileTyping: true,
  ),
  Shortcut(
    ShortcutAction.denyRequest,
    KeyStroke('backspace', primary: true, alt: true),
    whileTyping: true,
  ),
  Shortcut(
    ShortcutAction.copyLastCodeBlock,
    KeyStroke(';', primary: true, shift: true),
    whileTyping: true,
  ),
  // Dictation (M8): start, and stop to transcribe.
  Shortcut(
    ShortcutAction.dictate,
    KeyStroke('l', primary: true, shift: true),
    whileTyping: true,
  ),
  // The workspace frames: Open WebUI's sidebar
  // chord, and VS Code's for the pane on the other side.
  Shortcut(
    ShortcutAction.toggleSidebar,
    KeyStroke('s', primary: true, shift: true),
    whileTyping: true,
  ),
  Shortcut(
    ShortcutAction.toggleSidePane,
    KeyStroke('b', primary: true, alt: true),
    whileTyping: true,
  ),
];

/// The action [pressed] invokes, or null if it invokes none.
///
/// [typing] is whether the event came from a field the user is editing.
ShortcutAction? resolveShortcut(
  KeyStroke pressed, {
  required bool typing,
  List<Shortcut> table = defaultShortcuts,
}) {
  for (final shortcut in table) {
    if (shortcut.stroke != pressed) continue;
    if (typing && !shortcut.whileTyping) return null;
    return shortcut.action;
  }
  return null;
}

/// How the chord is written on this platform.
///
/// Mac users read `⌘⇧O`; everyone else reads `Ctrl+Shift+O`. Showing the
/// wrong one in the overlay makes the whole list look like it belongs to a
/// different application.
String describeStroke(KeyStroke stroke, {required bool isMac}) {
  final parts = <String>[
    if (stroke.primary) isMac ? '⌘' : 'Ctrl',
    if (stroke.shift) isMac ? '⇧' : 'Shift',
    if (stroke.alt) isMac ? '⌥' : 'Alt',
    _describeKey(stroke.key),
  ];
  return isMac ? parts.join() : parts.join('+');
}

String _describeKey(String key) => switch (key) {
  'escape' => 'Esc',
  'enter' => 'Enter',
  'backspace' => 'Backspace',
  'arrowup' => '↑',
  'arrowdown' => '↓',
  ' ' => 'Space',
  _ => key.length == 1 ? key.toUpperCase() : key,
};

/// Whether this keydown in the composer means "send".
///
/// Enter sends and Shift+Enter breaks the line, which is what every chat
/// client does and therefore what the hand expects. [isComposing] is the
/// one that is easy to miss: while an IME is open, Enter commits the
/// candidate, and sending there would ship half a Japanese sentence.
bool sendsMessage({
  required String key,
  required bool shift,
  required bool isComposing,
}) => key == 'Enter' && !shift && !isComposing;

/// The text of the last fenced code block in [markdown], or null.
///
/// Scanned rather than parsed: the transcript renderer has the AST, but the
/// copy shortcut runs over whatever is on screen including a turn that is
/// still streaming, and re-parsing every message on a keypress to find a
/// fence is work for an answer a regex-free scan gets right.
///
/// An unterminated fence -- which is what a half-streamed block looks like --
/// counts, because that is exactly the block someone reaches for.
String? lastCodeBlock(String markdown) {
  final lines = markdown.split('\n');
  String? fence;
  var start = 0;
  String? last;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    final isFence = trimmed.startsWith('```') || trimmed.startsWith('~~~');
    if (!isFence) continue;
    final marker = trimmed.substring(0, 3);
    if (fence == null) {
      fence = marker;
      start = i + 1;
    } else if (marker == fence) {
      last = lines.sublist(start, i).join('\n');
      fence = null;
    }
  }
  // Still open at the end of the text: the block is being written right now.
  if (fence != null && start < lines.length) {
    last = lines.sublist(start).join('\n');
  }
  return last;
}

/// [stroke] as stored, e.g. `mod+shift+o` (WP-9.4).
String encodeStroke(KeyStroke stroke) => <String>[
  if (stroke.primary) 'mod',
  if (stroke.shift) 'shift',
  if (stroke.alt) 'alt',
  stroke.key,
].join('+');

/// The inverse of [encodeStroke]; null for anything it did not write.
KeyStroke? decodeStroke(String encoded) {
  // The key itself may be `+`, which ends the string after its separator.
  final plus = encoded.endsWith('++');
  final parts = (plus ? encoded.substring(0, encoded.length - 2) : encoded)
      .split('+')
      .where((part) => part.isNotEmpty)
      .toList();
  final key = plus ? '+' : (parts.isEmpty ? '' : parts.removeLast());
  if (key.isEmpty || key.length > 12) return null;
  final modifiers = parts.toSet();
  if (!modifiers.every(const {'mod', 'shift', 'alt'}.contains)) return null;
  return KeyStroke(
    key,
    primary: modifiers.contains('mod'),
    shift: modifiers.contains('shift'),
    alt: modifiers.contains('alt'),
  );
}

/// [defaultShortcuts] with the user's own keys, by action name, in place
/// of the defaults. An override that cannot be read keeps the default.
List<Shortcut> applyShortcutOverrides(Map<String, String> overrides) =>
    <Shortcut>[
      for (final shortcut in defaultShortcuts)
        switch (overrides[shortcut.action.name]) {
          final String encoded? when decodeStroke(encoded) != null => Shortcut(
            shortcut.action,
            decodeStroke(encoded)!,
            // A chord keeps working while typing; a bare key must not, or it
            // would eat that letter out of every message.
            whileTyping:
                decodeStroke(encoded)!.primary || decodeStroke(encoded)!.alt,
          ),
          _ => shortcut,
        },
    ];

/// The action in [table] other than [action] that [stroke] already fires.
ShortcutAction? shortcutConflict(
  List<Shortcut> table,
  ShortcutAction action,
  KeyStroke stroke,
) {
  for (final shortcut in table) {
    if (shortcut.action != action && shortcut.stroke == stroke) {
      return shortcut.action;
    }
  }
  return null;
}
