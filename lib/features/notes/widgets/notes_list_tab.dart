import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/models/note.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
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
  static final _noteRoutePattern = RegExp(r'^/notes/(.+)$');

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _activeNoteId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _activeNoteId = _parseNoteId(_currentPath);
    NavigationService.router.routeInformationProvider.addListener(
      _onRouteChanged,
    );
  }

  @override
  void dispose() {
    NavigationService.router.routeInformationProvider.removeListener(
      _onRouteChanged,
    );
    _searchController.dispose();
    super.dispose();
  }

  String get _currentPath =>
      NavigationService.router.routeInformationProvider.value.uri.path;

  static String? _parseNoteId(String location) =>
      _noteRoutePattern.firstMatch(location)?.group(1);

  void _onRouteChanged() {
    final newId = _parseNoteId(_currentPath);
    if (newId != _activeNoteId) {
      setState(() => _activeNoteId = newId);
    }
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value.trim());
  }

  Future<void> _onNoteTap(Note note) async {
    NavigationService.router.go('/notes/${note.id}');
    final isTablet = MediaQuery.of(context).size.shortestSide >= 600;
    if (!isTablet) {
      ResponsiveDrawerLayout.of(context)?.close();
    }
  }

  Future<void> _createNote() async {
    ConduitHaptics.lightImpact();
    final dateFormat = DateFormat('yyyy-MM-dd');
    final defaultTitle = dateFormat.format(DateTime.now());
    final note = await ref
        .read(noteCreatorProvider.notifier)
        .createNote(title: defaultTitle);
    if (note != null && mounted) {
      NavigationService.router.go('/notes/${note.id}');
      final isTablet = MediaQuery.of(context).size.shortestSide >= 600;
      if (!isTablet) {
        ResponsiveDrawerLayout.of(context)?.close();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final notes = _query.isEmpty
        ? ref.watch(notesListProvider)
        : AsyncValue.data(ref.watch(filteredNotesProvider(_query)));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: ConduitGlassSearchField(
                  controller: _searchController,
                  hintText: l10n.searchNotes,
                  onChanged: _onSearchChanged,
                  query: _query,
                  onClear: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                ),
              ),
              const SizedBox(width: 8),
              FloatingAppBarIconButton(
                icon: UiUtils.newNoteIcon,
                onTap: _createNote,
              ),
            ],
          ),
        ),
        Expanded(
          child: notes.when(
            data: (noteList) {
              if (noteList.isEmpty) {
                return Center(
                  child: Text(
                    _query.isEmpty ? l10n.noNotesYet : l10n.noNotesFound,
                    style: TextStyle(color: theme.textSecondary),
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: () async {
                  ConduitHaptics.lightImpact();
                  await ref.read(notesListProvider.notifier).refresh();
                },
                child: ListView.builder(
                  itemCount: noteList.length,
                  padding: EdgeInsets.zero,
                  itemBuilder: (context, index) {
                    final note = noteList[index];
                    return _NoteListTile(
                      note: note,
                      selected: note.id == _activeNoteId,
                      onTap: () => _onNoteTap(note),
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(child: Text(l10n.failedToLoadNotes)),
          ),
        ),
      ],
    );
  }
}

class _NoteListTile extends StatelessWidget {
  const _NoteListTile({
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final Note note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final title = note.title.isEmpty ? l10n.untitled : note.title;
    final preview = note.markdownContent.isNotEmpty
        ? note.markdownContent.replaceAll('\n', ' ').trim()
        : '';
    final timeAgo = _formatTime(note.updatedDateTime);

    final background = selected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            theme.surfaceContainer,
          )
        : theme.surfaceContainer;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyMediumStyle.copyWith(
                            color: theme.textPrimary,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        timeAgo,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  if (preview.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
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
