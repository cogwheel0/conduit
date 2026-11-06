import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:conduit_core/models/note.dart';
import 'package:flutter/widgets.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/utility/utility_rows.dart';

/// A page of a note as the Pages sheet lists it: its title, the path of
/// titles down to it, and how deep it is nested.
class NotePageEntry {
  const NotePageEntry({
    required this.id,
    required this.title,
    required this.path,
    required this.depth,
  });

  final String id;
  final String title;
  final String path;
  final int depth;
}

/// The pages of a note in the order the server keeps them, each parent before
/// its subpages. The main page carries the note's title ([noteTitle]) while
/// it has not been renamed on its own.
List<NotePageEntry> notePageEntries(List<NotePage> pages, String noteTitle) {
  final paths = <String, String>{};
  final depths = <String, int>{};
  return [
    for (final page in pages)
      () {
        final title = page.id == kNoteMainPageId && page.inheritNoteTitle
            ? noteTitle
            : page.title;
        final parentPath = paths[page.parentId];
        final path = parentPath == null ? title : '$parentPath / $title';
        final depth = page.parentId == null
            ? 0
            : (depths[page.parentId] ?? -1) + 1;
        paths[page.id] = path;
        depths[page.id] = depth;
        return NotePageEntry(
          id: page.id,
          title: title,
          path: path,
          depth: depth,
        );
      }(),
  ];
}

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
