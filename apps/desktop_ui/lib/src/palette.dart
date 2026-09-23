/// What the command palette offers, and how it narrows (WP-3.1).
///
/// Pure, like the shortcut table: the component renders this and the
/// keyboard layer carries it out, and neither is where "which commands
/// match `set`" is decided.
library;

/// Something the palette can do other than open a conversation.
///
/// Notes, knowledge and files join this list with their milestones. A
/// command that leads nowhere is worse than a short list, for the same
/// reason the shortcut table only binds what exists.
enum PaletteCommand {
  newChat,
  newTemporaryChat,
  chooseModel,
  openSettings,
  showShortcuts,
}

/// One row: a command, or a conversation to open.
sealed class PaletteItem {
  const PaletteItem(this.label);

  final String label;
}

final class PaletteCommandItem extends PaletteItem {
  const PaletteCommandItem(this.command, super.label, {this.shortcut});

  final PaletteCommand command;

  /// The chord that does the same thing, shown so the palette teaches it.
  final String? shortcut;
}

final class PaletteChatItem extends PaletteItem {
  const PaletteChatItem(this.chatId, super.label, {this.snippet});

  final String chatId;

  /// Where the match was, when the match was in the conversation rather
  /// than in its title.
  final String? snippet;
}

/// The commands whose label contains every word of [query].
///
/// Words rather than the whole string, and in any order: "new temp" and
/// "temporary new" both mean the same command, and a palette that needs
/// its labels quoted exactly is one that gets abandoned for the mouse.
List<PaletteCommandItem> matchCommands(
  String query,
  List<PaletteCommandItem> commands,
) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return commands;
  return commands
      .where((item) {
        final label = item.label.toLowerCase();
        return words.every(label.contains);
      })
      .toList(growable: false);
}

/// The highlighted row after an arrow key, wrapping at both ends.
///
/// Wrapping because the list is short and the row most often wanted after
/// the first is the last -- the oldest recent conversation, the bottom
/// command.
int movePaletteIndex(int index, int count, {required bool down}) {
  if (count == 0) return 0;
  final next = down ? index + 1 : index - 1;
  return next % count;
}
