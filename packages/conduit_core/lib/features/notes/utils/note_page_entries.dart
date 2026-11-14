import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:conduit_core/models/note.dart';

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
