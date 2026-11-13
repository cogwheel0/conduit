import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/utils/emoji_shortcodes.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/models/folder_icons.dart';

export 'package:conduit_core/models/folder_icons.dart';

String localizedFolderIconLabel(
  AppLocalizations l10n,
  FolderIconOption option,
) {
  return switch (option.alias) {
    'file_folder' => l10n.folderIconFolder,
    'open_file_folder' => l10n.folderIconOpenFolder,
    'briefcase' => l10n.folderIconBriefcase,
    'books' => l10n.folderIconBooks,
    'memo' => l10n.folderIconMemo,
    'card_index_dividers' => l10n.folderIconDividers,
    'hammer_and_wrench' => l10n.folderIconTools,
    'toolbox' => l10n.folderIconToolbox,
    'sparkles' => l10n.folderIconSparkles,
    'brain' => l10n.folderIconBrain,
    'rocket' => l10n.folderIconRocket,
    'dart' => l10n.folderIconTarget,
    _ => option.semanticLabel,
  };
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
    final l10n = AppLocalizations.of(context)!;
    final option = folderIconOptionForAlias(iconAlias);
    final displayValue = folderIconEmoji(iconAlias);

    if (displayValue != null) {
      return Semantics(
        label: option == null
            ? l10n.folderIconGeneric
            : localizedFolderIconLabel(l10n, option),
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
