import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/note.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_scroll_physics.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/utils/locale_display_formatters.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../navigation/providers/sidebar_providers.dart';
import '../../navigation/providers/sidebar_tab_scroll_registry.dart';
import '../../navigation/models/sidebar_navigation_model.dart';
import '../../navigation/widgets/drawer_section_notifiers.dart';
import '../../navigation/widgets/conversation_tile.dart';
import '../providers/notes_providers.dart';
import '../utils/note_context_actions.dart';

/// Chevron for notes list section headers — matches chats drawer disclosure.
IconData _notesListDisclosureIcon(bool isExpanded) {
  if (Platform.isIOS) {
    return isExpanded
        ? CupertinoIcons.chevron_down
        : CupertinoIcons.chevron_right;
  }
  return isExpanded ? Icons.expand_more : Icons.chevron_right_rounded;
}

/// Simplified notes list for the sidebar Notes tab.
class NotesListTab extends ConsumerStatefulWidget {
  const NotesListTab({super.key});

  @override
  ConsumerState<NotesListTab> createState() => _NotesListTabState();
}

class _NotesListTabState extends ConsumerState<NotesListTab>
    with
        AutomaticKeepAliveClientMixin,
        SidebarTabScrollRegistration<NotesListTab> {
  static final _noteRoutePattern = RegExp(r'^/notes/(.+)$');

  String? _activeNoteId;
  bool _isRefreshingEmptyState = false;
  final ScrollController _scrollController = ScrollController();

  @override
  SidebarTabId get sidebarTabId => SidebarTabId.notes;

  @override
  ScrollController get sidebarScrollController => _scrollController;

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
    _scrollController.dispose();
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

  Future<void> _onNoteTap(Note note) async {
    NavigationService.router.go('/notes/${note.id}');
    closeSidebarDrawerIfOverlay(context);
  }

  Future<void> _deleteNote(Note note) =>
      confirmAndDeleteNote(context, ref, note);

  Future<void> _togglePin(Note note) => toggleNotePin(context, ref, note);

  Future<void> _refreshNotes({bool includeHaptic = false}) async {
    if (includeHaptic) {
      ConduitHaptics.lightImpact();
    }
    await ref.read(notesListProvider.notifier).refresh();
  }

  Future<void> _refreshEmptyStateNotes() async {
    if (_isRefreshingEmptyState) return;
    setState(() => _isRefreshingEmptyState = true);
    try {
      await _refreshNotes();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'empty-state-refresh-failed',
        scope: 'notes/sidebar',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) {
        setState(() => _isRefreshingEmptyState = false);
      }
    }
  }

  Widget _buildEmptyState(String message) {
    final theme = context.conduitTheme;
    final refreshLabel = MaterialLocalizations.of(
      context,
    ).refreshIndicatorSemanticLabel;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: AppTypography.sidebarSupportingStyle.copyWith(
                color: theme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              text: refreshLabel,
              icon: Platform.isIOS ? CupertinoIcons.refresh : Icons.refresh,
              onPressed: () => unawaited(_refreshEmptyStateNotes()),
              isSecondary: true,
              isCompact: true,
              isLoading: _isRefreshingEmptyState,
            ),
          ],
        ),
      ),
    );
  }

  List<ConduitContextMenuAction> _buildNoteActions(Note note) {
    return buildNoteContextMenuActions(
      context: context,
      ref: ref,
      note: note,
      onEdit: _onNoteTap,
      onTogglePin: _togglePin,
      onDelete: _deleteNote,
    );
  }

  Widget _buildNotesPinnedHeader(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final expanded = ref.watch(notesShowPinnedProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(notesShowPinnedProvider.notifier).toggle(),
        child: Row(
          children: [
            Icon(
              _notesListDisclosureIcon(expanded),
              color: theme.iconSecondary,
              size: IconSize.listItem,
            ),
            const SizedBox(width: Spacing.xxs),
            Text(
              l10n.pinned,
              style: AppTypography.labelStyle.copyWith(
                color: theme.textSecondary,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesRecentHeader(AppLocalizations l10n) {
    final theme = context.conduitTheme;
    final expanded = ref.watch(notesShowRecentProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(notesShowRecentProvider.notifier).toggle(),
        child: Row(
          children: [
            Icon(
              _notesListDisclosureIcon(expanded),
              color: theme.iconSecondary,
              size: IconSize.listItem,
            ),
            const SizedBox(width: Spacing.xxs),
            Text(
              l10n.recent,
              style: AppTypography.labelStyle.copyWith(
                color: theme.textSecondary,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesListItem({
    required int index,
    required AppLocalizations l10n,
    required List<Note> pinnedNotes,
    required List<Note> otherNotes,
    required bool hasPinnedSection,
    required bool hasRecentSection,
    required bool needsSectionGap,
    required bool showPinned,
    required bool showRecent,
  }) {
    var cursor = 0;

    if (hasPinnedSection) {
      if (index == cursor) {
        return _buildNotesPinnedHeader(l10n);
      }
      cursor++;
      if (showPinned) {
        final pinnedEnd = cursor + pinnedNotes.length;
        if (index < pinnedEnd) {
          final note = pinnedNotes[index - cursor];
          return _NoteListTile(
            note: note,
            selected: note.id == _activeNoteId,
            onTap: () => _onNoteTap(note),
            actions: _buildNoteActions(note),
          );
        }
        cursor = pinnedEnd;
      }
    }

    if (needsSectionGap) {
      if (index == cursor) {
        return const SizedBox(height: Spacing.md);
      }
      cursor++;
    }

    if (hasRecentSection) {
      if (index == cursor) {
        return _buildNotesRecentHeader(l10n);
      }
      cursor++;
      if (showRecent) {
        final recentEnd = cursor + otherNotes.length;
        if (index < recentEnd) {
          final note = otherNotes[index - cursor];
          return _NoteListTile(
            note: note,
            selected: note.id == _activeNoteId,
            onTap: () => _onNoteTap(note),
            actions: _buildNoteActions(note),
          );
        }
      }
    }

    assert(false, 'notes list item index out of range: $index');
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final searchController = ref.watch(sidebarSearchFieldControllerProvider);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: searchController,
      builder: (context, value, _) {
        final query = value.text.trim();
        final notes = query.isEmpty
            ? ref.watch(notesListProvider)
            : ref.watch(filteredNotesProvider(query));

        return notes.when(
          data: (noteList) {
            if (noteList.isEmpty) {
              return _buildEmptyState(
                query.isEmpty ? l10n.noNotesYet : l10n.noNotesFound,
              );
            }
            final pinnedNotes = noteList
                .where((note) => note.isPinned)
                .toList(growable: false);
            final otherNotes = noteList
                .where((note) => !note.isPinned)
                .toList(growable: false);
            final hasPinnedSection = pinnedNotes.isNotEmpty;
            final showPinned = ref.watch(notesShowPinnedProvider);
            final showRecent = ref.watch(notesShowRecentProvider);
            final needsSectionGap = hasPinnedSection && otherNotes.isNotEmpty;
            final hasRecentSection = otherNotes.isNotEmpty;

            var itemCount = 0;
            if (hasPinnedSection) {
              itemCount += 1;
              if (showPinned) {
                itemCount += pinnedNotes.length;
              }
            }
            if (needsSectionGap) {
              itemCount += 1;
            }
            if (hasRecentSection) {
              itemCount += 1;
              if (showRecent) {
                itemCount += otherNotes.length;
              }
            }

            final list = ListView.builder(
              controller: _scrollController,
              primary: false,
              padding: EdgeInsets.only(
                top: sidebarTabContentTopPadding(context),
                bottom: sidebarTabContentBottomPadding(context),
              ),
              physics: platformAlwaysScrollablePhysics(context),
              itemCount: itemCount,
              itemBuilder: (context, index) {
                return _buildNotesListItem(
                  index: index,
                  l10n: l10n,
                  pinnedNotes: pinnedNotes,
                  otherNotes: otherNotes,
                  hasPinnedSection: hasPinnedSection,
                  hasRecentSection: hasRecentSection,
                  needsSectionGap: needsSectionGap,
                  showPinned: showPinned,
                  showRecent: showRecent,
                );
              },
            );
            final refreshable = RefreshIndicator.adaptive(
              edgeOffset: sidebarRefreshIndicatorEdgeOffset(context),
              onRefresh: () => _refreshNotes(includeHaptic: true),
              child: list,
            );
            final primary = PrimaryScrollController(
              controller: _scrollController,
              child: refreshable,
            );
            return context.usesCupertinoChrome
                ? CupertinoScrollbar(
                    controller: _scrollController,
                    child: primary,
                  )
                : Scrollbar(controller: _scrollController, child: primary);
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(child: Text(l10n.failedToLoadNotes)),
        );
      },
    );
  }
}

class _NoteListTile extends StatelessWidget {
  const _NoteListTile({
    required this.note,
    required this.selected,
    required this.onTap,
    required this.actions,
  });

  final Note note;
  final bool selected;
  final VoidCallback onTap;
  final List<ConduitContextMenuAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final title = note.title.isEmpty ? l10n.untitled : note.title;
    final preview = note.listPreviewMarkdown.replaceAll('\n', ' ').trim();
    final timeAgo = LocaleDisplayFormatters.compactRelativeTime(
      context,
      note.updatedDateTime,
    );

    return ConduitContextMenu(
      actions: actions,
      previewBuilder: buildConversationTileContextPreview,
      child: ChatStyleSidebarTile(
        key: ValueKey<String>('note-sidebar-row-${note.id}'),
        selected: selected,
        onTap: onTap,
        semanticLabel: [
          title,
          if (note.isPinned) l10n.pinned,
          if (preview.isNotEmpty) preview,
        ].join('. '),
        tintKey: ValueKey<String>('note-sidebar-selected-${note.id}'),
        pressedKey: ValueKey<String>('note-sidebar-pressed-${note.id}'),
        child: UtilityRow(
          title: title,
          subtitle: preview.isEmpty ? null : preview,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (note.isPinned) ...[
                Icon(UiUtils.pinIcon, size: 14, color: theme.buttonPrimary),
                const SizedBox(width: 6),
              ],
              Text(
                timeAgo,
                style: AppTypography.sidebarSupportingStyle.copyWith(
                  color: theme.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
