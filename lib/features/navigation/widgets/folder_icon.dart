import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// A curated server-compatible folder icon choice.
class FolderIconOption {
  const FolderIconOption({
    required this.alias,
    required this.emoji,
    required this.semanticLabel,
  });

  /// OpenWebUI-compatible shortcode alias saved on the folder model.
  final String alias;

  /// Emoji shown in Flutter for the alias.
  final String emoji;

  /// Accessibility label for assistive technologies.
  final String semanticLabel;
}

/// Common folder icon aliases that map cleanly to OpenWebUI shortcodes.
const List<FolderIconOption> folderIconOptions = <FolderIconOption>[
  FolderIconOption(alias: 'file_folder', emoji: '📁', semanticLabel: 'Folder'),
  FolderIconOption(
    alias: 'open_file_folder',
    emoji: '📂',
    semanticLabel: 'Open folder',
  ),
  FolderIconOption(alias: 'briefcase', emoji: '💼', semanticLabel: 'Briefcase'),
  FolderIconOption(alias: 'books', emoji: '📚', semanticLabel: 'Books'),
  FolderIconOption(alias: 'memo', emoji: '📝', semanticLabel: 'Memo'),
  FolderIconOption(
    alias: 'card_index_dividers',
    emoji: '🗂️',
    semanticLabel: 'Dividers',
  ),
  FolderIconOption(
    alias: 'hammer_and_wrench',
    emoji: '🛠️',
    semanticLabel: 'Tools',
  ),
  FolderIconOption(alias: 'toolbox', emoji: '🧰', semanticLabel: 'Toolbox'),
  FolderIconOption(alias: 'sparkles', emoji: '✨', semanticLabel: 'Sparkles'),
  FolderIconOption(alias: 'brain', emoji: '🧠', semanticLabel: 'Brain'),
  FolderIconOption(alias: 'rocket', emoji: '🚀', semanticLabel: 'Rocket'),
  FolderIconOption(alias: 'dart', emoji: '🎯', semanticLabel: 'Target'),
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

/// Renders a saved folder icon alias or falls back to the platform folder icon.
class FolderIconGlyph extends StatelessWidget {
  const FolderIconGlyph({
    super.key,
    this.iconAlias,
    this.isOpen = false,
    required this.size,
    this.color,
    this.textStyle,
  });

  final String? iconAlias;
  final bool isOpen;
  final double size;
  final Color? color;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final normalized = normalizeFolderIconAlias(iconAlias);
    final option = folderIconOptionForAlias(normalized);

    if (option != null ||
        (normalized != null && _looksLikeRenderedGlyph(normalized))) {
      final displayValue = option?.emoji ?? normalized!;
      return Semantics(
        label: option?.semanticLabel ?? 'Folder icon',
        child: Text(
          displayValue,
          style:
              textStyle?.copyWith(fontSize: size, color: color, height: 1) ??
              TextStyle(fontSize: size, color: color, height: 1),
        ),
      );
    }

    return Icon(
      isOpen
          ? (Platform.isIOS ? CupertinoIcons.folder_open : Icons.folder_open)
          : (Platform.isIOS ? CupertinoIcons.folder : Icons.folder),
      size: size,
      color: color,
    );
  }
}
