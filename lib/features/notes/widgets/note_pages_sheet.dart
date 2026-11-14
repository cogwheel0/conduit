import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/notes/utils/note_page_entries.dart';
import 'package:flutter/widgets.dart';

export 'package:conduit_core/features/notes/utils/note_page_entries.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/utility/utility_rows.dart';

/// Lists [entries] as a tree, [currentId] checked, and returns the page the
/// user picks, or null.
Future<String?> showNotePagesSheet(
  BuildContext context, {
  required List<NotePageEntry> entries,
  required String currentId,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveSelectionSheet<String>(
    context: context,
    builder: (sheetContext) => AdaptiveSelectionSheet(
      title: l10n.notePages,
      description: l10n.notePagesDescription,
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = entry.id == currentId;
        final theme = context.conduitTheme;
        return Padding(
          key: ValueKey<String>('note-page-${entry.id}'),
          padding: EdgeInsets.only(left: Spacing.lg * entry.depth),
          child: UtilityRow(
            title: entry.title,
            selected: selected,
            semanticLabel: entry.path,
            onTap: () => Navigator.of(sheetContext).pop(entry.id),
            trailing: selected
                ? Icon(
                    Icons.check,
                    color: theme.buttonPrimary,
                    size: IconSize.medium,
                  )
                : null,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.xs,
            ),
          ),
        );
      },
    ),
  );
}
