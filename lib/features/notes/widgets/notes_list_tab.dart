import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/models/note.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../providers/notes_providers.dart';

/// Simplified notes list for the sidebar Notes tab.
class NotesListTab extends ConsumerStatefulWidget {
  const NotesListTab({super.key});

  @override
  ConsumerState<NotesListTab> createState() => _NotesListTabState();
}

class _NotesListTabState extends ConsumerState<NotesListTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value.trim());
  }

  Future<void> _onNoteTap(Note note) async {
    ResponsiveDrawerLayout.of(context)?.close();
    if (mounted) {
      context.pushNamed(
        RouteNames.noteEditor,
        pathParameters: {'id': note.id},
      );
    }
  }

  Future<void> _createNote() async {
    HapticFeedback.lightImpact();
    final dateFormat = DateFormat('yyyy-MM-dd');
    final defaultTitle = dateFormat.format(DateTime.now());
    final note = await ref
        .read(noteCreatorProvider.notifier)
        .createNote(title: defaultTitle);
    if (note != null && mounted) {
      ResponsiveDrawerLayout.of(context)?.close();
      context.pushNamed(
        RouteNames.noteEditor,
        pathParameters: {'id': note.id},
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = context.conduitTheme;
    final notes = _query.isEmpty
        ? ref.watch(notesListProvider)
        : AsyncValue.data(
            ref.watch(filteredNotesProvider(_query)),
          );

    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: ConduitGlassSearchField(
                controller: _searchController,
                hintText: 'Search notes...',
                onChanged: _onSearchChanged,
                query: _query,
                onClear: () {
                  _searchController.clear();
                  _onSearchChanged('');
                },
              ),
            ),
            Expanded(
              child: notes.when(
                data: (noteList) {
                  if (noteList.isEmpty) {
                    return Center(
                      child: Text(
                        _query.isEmpty ? 'No notes yet' : 'No matching notes',
                        style: TextStyle(color: theme.textSecondary),
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: () async {
                      HapticFeedback.lightImpact();
                      await ref.read(notesListProvider.notifier).refresh();
                    },
                    child: ListView.builder(
                      itemCount: noteList.length,
                      padding: const EdgeInsets.only(bottom: 80),
                      itemBuilder: (context, index) {
                        final note = noteList[index];
                        return _NoteListTile(
                          note: note,
                          onTap: () => _onNoteTap(note),
                        );
                      },
                    ),
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (err, _) =>
                    const Center(child: Text('Failed to load notes')),
              ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            heroTag: 'notes_fab',
            onPressed: _createNote,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

class _NoteListTile extends StatelessWidget {
  const _NoteListTile({required this.note, required this.onTap});

  final Note note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final title = note.title.isEmpty ? 'Untitled' : note.title;
    final preview = note.markdownContent.isNotEmpty
        ? note.markdownContent.replaceAll('\n', ' ').trim()
        : '';
    final timeAgo = _formatTime(note.updatedDateTime);

    return ListTile(
      leading: Icon(Icons.note_outlined, color: theme.textSecondary),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: preview.isNotEmpty
          ? Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.textSecondary),
            )
          : null,
      trailing: Text(
        timeAgo,
        style: TextStyle(fontSize: 12, color: theme.textSecondary),
      ),
      onTap: onTap,
    );
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return DateFormat('MMM d').format(dt);
  }
}
