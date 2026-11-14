/// The folder icons the app offers: Open WebUI-compatible shortcode aliases,
/// saved as a folder's `meta.icon`, with the emoji and SF Symbol each draws
/// as, and what any other saved icon draws as. Shared by every host.
library;

import 'package:conduit_core/utils/emoji_shortcodes.dart';

/// A curated server-compatible folder icon choice.
class FolderIconOption {
  const FolderIconOption({
    required this.alias,
    required this.emoji,
    required this.semanticLabel,
    required this.sfSymbol,
  });

  /// OpenWebUI-compatible shortcode alias saved on the folder model.
  final String alias;

  /// Emoji shown in Flutter for the alias.
  final String emoji;

  /// Accessibility label for assistive technologies.
  final String semanticLabel;

  /// SF Symbol used by native iOS pickers for this option.
  final String sfSymbol;
}

/// Common folder icon aliases that map cleanly to OpenWebUI shortcodes.
const List<FolderIconOption> folderIconOptions = <FolderIconOption>[
  FolderIconOption(
    alias: 'file_folder',
    emoji: '📁',
    semanticLabel: 'Folder',
    sfSymbol: 'folder',
  ),
  FolderIconOption(
    alias: 'open_file_folder',
    emoji: '📂',
    semanticLabel: 'Open folder',
    sfSymbol: 'folder.fill',
  ),
  FolderIconOption(
    alias: 'briefcase',
    emoji: '💼',
    semanticLabel: 'Briefcase',
    sfSymbol: 'briefcase',
  ),
  FolderIconOption(
    alias: 'books',
    emoji: '📚',
    semanticLabel: 'Books',
    sfSymbol: 'books.vertical',
  ),
  FolderIconOption(
    alias: 'memo',
    emoji: '📝',
    semanticLabel: 'Memo',
    sfSymbol: 'note.text',
  ),
  FolderIconOption(
    alias: 'card_index_dividers',
    emoji: '🗂️',
    semanticLabel: 'Dividers',
    sfSymbol: 'rectangle.stack',
  ),
  FolderIconOption(
    alias: 'hammer_and_wrench',
    emoji: '🛠️',
    semanticLabel: 'Tools',
    sfSymbol: 'wrench.and.screwdriver',
  ),
  FolderIconOption(
    alias: 'toolbox',
    emoji: '🧰',
    semanticLabel: 'Toolbox',
    sfSymbol: 'cube.box',
  ),
  FolderIconOption(
    alias: 'sparkles',
    emoji: '✨',
    semanticLabel: 'Sparkles',
    sfSymbol: 'sparkles',
  ),
  FolderIconOption(
    alias: 'brain',
    emoji: '🧠',
    semanticLabel: 'Brain',
    sfSymbol: 'brain.head.profile',
  ),
  FolderIconOption(
    alias: 'rocket',
    emoji: '🚀',
    semanticLabel: 'Rocket',
    sfSymbol: 'paperplane',
  ),
  FolderIconOption(
    alias: 'dart',
    emoji: '🎯',
    semanticLabel: 'Target',
    sfSymbol: 'target',
  ),
];

/// Trims a stored icon alias and treats empty strings as unset.
String? normalizeFolderIconAlias(String? alias) {
  if (alias == null) {
    return null;
  }
  final trimmed = alias.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Returns the configured option for a saved icon alias, if known.
FolderIconOption? folderIconOptionForAlias(String? alias) {
  final normalized = normalizeFolderIconAlias(alias);
  if (normalized == null) {
    return null;
  }

  for (final option in folderIconOptions) {
    if (option.alias == normalized) {
      return option;
    }
  }
  return null;
}

bool _looksLikeRenderedGlyph(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return false;
  }
  return !RegExp(r'^[a-z0-9_:+-]+$', caseSensitive: false).hasMatch(normalized);
}

/// The emoji drawn for a saved icon alias: a curated option's, any other
/// shortcode Open WebUI knows (a folder's icon chosen on the web, such as
/// `fire`), or a glyph saved as is. Null for no icon or an unknown name,
/// which show the platform folder icon.
String? folderIconEmoji(String? alias) {
  final normalized = normalizeFolderIconAlias(alias);
  if (normalized == null) {
    return null;
  }
  return folderIconOptionForAlias(normalized)?.emoji ??
      emojiForShortcode(normalized) ??
      (_looksLikeRenderedGlyph(normalized) ? normalized : null);
}

/// A saved icon alias that none of [folderIconOptions] is, but that still
/// draws an emoji (one chosen on the web), so an icon picker can offer it
/// as the folder's current choice. Null otherwise.
String? customFolderIconAlias(String? alias) {
  final normalized = normalizeFolderIconAlias(alias);
  if (normalized == null || folderIconOptionForAlias(normalized) != null) {
    return null;
  }
  return folderIconEmoji(normalized) == null ? null : normalized;
}

/// The label an icon picker gives [alias], a [customFolderIconAlias]: its
/// emoji, followed by the shortcode Open WebUI names it with, if any.
String customFolderIconLabel(String alias) {
  final emoji = folderIconEmoji(alias) ?? alias;
  return emoji == alias ? emoji : '$emoji $alias';
}
