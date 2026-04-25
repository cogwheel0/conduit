import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/models/note.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/widgets/error_boundary.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/utils/ui_utils.dart';
import '../providers/notes_providers.dart';

/// Page displaying the list of all notes with search and time grouping.
class NotesListPage extends ConsumerStatefulWidget {
  const NotesListPage({super.key});

  @override
  ConsumerState<NotesListPage> createState() => _NotesListPageState();
}

class _NotesListPageState extends ConsumerState<NotesListPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'notes_search');
  final ScrollController _scrollController = ScrollController();
  Timer? _debounce;
  String _query = '';

  // Section expansion state
  final Map<TimeRange, bool> _expandedSections = {};

  @override
  void initState() {
    super.initState();
    // Default all sections to expanded
    for (final range in TimeRange.values) {
      _expandedSections[range] = true;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = _searchController.text.trim());
    });
  }

  Future<void> _refreshNotes() async {
    ConduitHaptics.lightImpact();
    await ref.read(notesListProvider.notifier).refresh();
  }

  Future<void> _createNewNote() async {
    ConduitHaptics.lightImpact();

    final dateFormat = DateFormat('yyyy-MM-dd');
    final defaultTitle = dateFormat.format(DateTime.now());

    final note = await ref
        .read(noteCreatorProvider.notifier)
        .createNote(title: defaultTitle);

    if (note != null && mounted) {
      context.goNamed(RouteNames.noteEditor, pathParameters: {'id': note.id});
    }
  }

  Future<void> _deleteNote(Note note) async {
    final l10n = AppLocalizations.of(context)!;

    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deleteNoteTitle,
      message: l10n.deleteNoteMessage(
        note.title.isEmpty ? l10n.untitled : note.title,
      ),
      confirmText: l10n.delete,
      isDestructive: true,
    );

    if (confirmed && mounted) {
      ConduitHaptics.mediumImpact();
      await ref.read(noteDeleterProvider.notifier).deleteNote(note.id);
    }
  }

  Future<void> _togglePin(Note note) async {
    final updated = await ref
        .read(notePinTogglerProvider.notifier)
        .togglePin(note);
    if (updated == null || !mounted) {
      return;
    }

    ConduitHaptics.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    // Check if notes feature is enabled - redirect to chat if disabled
    final notesEnabled = ref.watch(notesFeatureEnabledProvider);
    if (!notesEnabled) {
      // Redirect back to chat on next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.go('/chat');
        }
      });
      // Show empty scaffold while redirecting
      return const AdaptiveScaffold();
    }

    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final l10n = AppLocalizations.of(context)!;

    return ErrorBoundary(
      child: Scaffold(
        backgroundColor: context.conduitTheme.surfaceBackground,
        extendBodyBehindAppBar: true,
        appBar: FloatingAppBar(
          leading: canPop ? const FloatingAppBarBackButton() : null,
          title: FloatingAppBarTitle(
            text: l10n.notes,
            icon: Platform.isIOS
                ? CupertinoIcons.doc_text_fill
                : Icons.notes_rounded,
          ),
          bottomHeight: 64,
          bottom: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.inputPadding,
              Spacing.xs,
              Spacing.inputPadding,
              Spacing.sm,
            ),
            child: _buildFloatingSearchField(context),
          ),
        ),
        body: _buildBody(context),
        floatingActionButton: _buildFAB(context),
      ),
    );
  }

  Widget _buildFloatingSearchField(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ConduitGlassSearchField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      hintText: l10n.searchNotes,
      onChanged: (_) => _onSearchChanged(),
      query: _query,
      onClear: () {
        _searchController.clear();
        setState(() => _query = '');
        _searchFocusNode.unfocus();
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    final notesAsync = ref.watch(notesListProvider);

    return notesAsync.when(
      data: (notes) => _buildNotesList(context, notes),
      loading: () => _buildLoading(context),
      error: (error, stack) => _buildError(context, error),
    );
  }

  Widget _buildNotesList(BuildContext context, List<Note> allNotes) {
    final notes = _query.isEmpty
        ? allNotes
        : ref.watch(filteredNotesProvider(_query));

    if (notes.isEmpty) {
      return _buildEmptyState(context);
    }

    final pinnedNotes = notes
        .where((note) => note.isPinned)
        .toList(growable: false);
    final unpinnedNotes = notes
        .where((note) => !note.isPinned)
        .toList(growable: false);

    // Group notes by time range
    final grouped = <TimeRange, List<Note>>{};
    for (final note in unpinnedNotes) {
      final range = getTimeRangeForTimestamp(note.updatedDateTime);
      grouped.putIfAbsent(range, () => []).add(note);
    }

    // Build slivers
    final slivers = <Widget>[];

    if (pinnedNotes.isNotEmpty) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          sliver: SliverToBoxAdapter(
            child: _buildPinnedSectionHeader(context, pinnedNotes.length),
          ),
        ),
      );
      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildNoteCard(context, pinnedNotes[index]),
              childCount: pinnedNotes.length,
            ),
          ),
        ),
      );
      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
      );
    }

    for (final range in TimeRange.values) {
      final rangeNotes = grouped[range];
      if (rangeNotes != null && rangeNotes.isNotEmpty) {
        // Section header
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            sliver: SliverToBoxAdapter(
              child: _buildSectionHeader(context, range, rangeNotes.length),
            ),
          ),
        );

        // Notes in section
        if (_expandedSections[range] ?? true) {
          slivers.add(
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
          );
          slivers.add(
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _buildNoteCard(context, rangeNotes[index]),
                  childCount: rangeNotes.length,
                ),
              ),
            ),
          );
        }

        slivers.add(
          const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
        );
      }
    }

    // Add bottom padding for FAB
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 80)));

    return _buildRefreshableScrollView(slivers);
  }

  Widget _buildRefreshableScrollView(List<Widget> slivers) {
    // Add top padding for floating app bar and search bar
    final topPadding = MediaQuery.of(context).padding.top;
    // App bar height: kToolbarHeight + search bar (48) + padding (xs + sm)
    final appBarHeight = kTextTabBarHeight + 48 + Spacing.xs + Spacing.sm;
    final paddedSlivers = <Widget>[
      SliverToBoxAdapter(child: SizedBox(height: topPadding + appBarHeight)),
      ...slivers,
    ];

    return ConduitRefreshIndicator(
      onRefresh: _refreshNotes,
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: paddedSlivers,
      ),
    );
  }

  Widget _buildPinnedSectionHeader(BuildContext context, int count) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: Spacing.sm,
        horizontal: Spacing.xs,
      ),
      child: Row(
        children: [
          Icon(
            UiUtils.pinIcon,
            color: sidebarTheme.foreground.withValues(alpha: 0.55),
            size: IconSize.sm,
          ),
          const SizedBox(width: Spacing.xs),
          Text(
            l10n.pinned,
            style: AppTypography.labelStyle.copyWith(
              color: sidebarTheme.foreground.withValues(alpha: 0.8),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.buttonPrimary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppBorderRadius.pill),
            ),
            child: Text(
              '$count',
              style: AppTypography.labelMediumStyle.copyWith(
                color: theme.buttonPrimary.withValues(alpha: 0.9),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, TimeRange range, int count) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final l10n = AppLocalizations.of(context)!;
    final isExpanded = _expandedSections[range] ?? true;

    String label;
    switch (range) {
      case TimeRange.today:
        label = l10n.today;
      case TimeRange.yesterday:
        label = l10n.yesterday;
      case TimeRange.previousSevenDays:
        label = l10n.previous7Days;
      case TimeRange.previousThirtyDays:
        label = l10n.previous30Days;
      case TimeRange.older:
        label = l10n.older;
    }

    return InkWell(
      onTap: () {
        ConduitHaptics.selectionClick();
        setState(() => _expandedSections[range] = !isExpanded);
      },
      borderRadius: BorderRadius.circular(AppBorderRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: Spacing.sm,
          horizontal: Spacing.xs,
        ),
        child: Row(
          children: [
            AnimatedRotation(
              turns: isExpanded ? 0.25 : 0,
              duration: AnimationDuration.fast,
              curve: Curves.easeOutCubic,
              child: Icon(
                Platform.isIOS
                    ? CupertinoIcons.chevron_right
                    : Icons.chevron_right_rounded,
                color: sidebarTheme.foreground.withValues(alpha: 0.5),
                size: IconSize.sm,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Text(
              label,
              style: AppTypography.labelStyle.copyWith(
                color: sidebarTheme.foreground.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.buttonPrimary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppBorderRadius.pill),
              ),
              child: Text(
                '$count',
                style: AppTypography.labelMediumStyle.copyWith(
                  color: theme.buttonPrimary.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteCard(BuildContext context, Note note) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final l10n = AppLocalizations.of(context)!;

    final timeFormat = DateFormat.jm();
    final dateFormat = DateFormat.MMMd();
    final isToday = _isToday(note.updatedDateTime);
    final timeText = isToday
        ? timeFormat.format(note.updatedDateTime)
        : dateFormat.format(note.updatedDateTime);

    final title = note.title.isEmpty ? l10n.untitled : note.title;
    final preview = note.markdownContent.replaceAll('\n', ' ').trim();
    final hasContent = preview.isNotEmpty;

    Color? overlayForStates(Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return theme.buttonPrimary.withValues(alpha: Alpha.buttonPressed);
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return theme.buttonPrimary.withValues(alpha: Alpha.hover);
      }
      return Colors.transparent;
    }

    // Compute opaque background for proper context menu snapshot rendering
    final cardBackground = Color.alphaBlend(
      sidebarTheme.accent.withValues(alpha: 0.5),
      sidebarTheme.background,
    );

    return ConduitContextMenu(
      actions: _buildNoteActions(context, note),
      child: Padding(
        padding: const EdgeInsets.only(bottom: Spacing.sm),
        child: Material(
          color: cardBackground,
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              border: Border.all(
                color: sidebarTheme.border.withValues(alpha: 0.15),
                width: BorderWidth.thin,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppBorderRadius.card),
              overlayColor: WidgetStateProperty.resolveWith(overlayForStates),
              onTap: () {
                ConduitHaptics.selectionClick();
                context.goNamed(
                  RouteNames.noteEditor,
                  pathParameters: {'id': note.id},
                );
              },
              onLongPress: null, // Handled by ConduitContextMenu
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Note icon
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: sidebarTheme.accent,
                        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                        border: Border.all(
                          color: sidebarTheme.border.withValues(alpha: 0.2),
                          width: BorderWidth.thin,
                        ),
                      ),
                      child: Icon(
                        Platform.isIOS
                            ? CupertinoIcons.doc_text_fill
                            : Icons.description_rounded,
                        color: sidebarTheme.foreground.withValues(alpha: 0.6),
                        size: IconSize.md,
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    // Content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Title
                          Row(
                            children: [
                              Expanded(
                                child: MiddleEllipsisText(
                                  title,
                                  style: AppTypography.bodyMediumStyle.copyWith(
                                    color: sidebarTheme.foreground,
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              if (note.isPinned) ...[
                                const SizedBox(width: Spacing.xs),
                                Icon(
                                  UiUtils.pinIcon,
                                  color: theme.buttonPrimary,
                                  size: 14,
                                ),
                              ],
                            ],
                          ),
                          if (hasContent) ...[
                            const SizedBox(height: Spacing.xxs),
                            Text(
                              preview,
                              style: AppTypography.bodySmallStyle.copyWith(
                                color: sidebarTheme.foreground.withValues(
                                  alpha: 0.6,
                                ),
                                height: 1.4,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: Spacing.sm),
                          // Metadata row
                          Row(
                            children: [
                              Icon(
                                Platform.isIOS
                                    ? CupertinoIcons.clock
                                    : Icons.schedule_rounded,
                                color: sidebarTheme.foreground.withValues(
                                  alpha: 0.4,
                                ),
                                size: 12,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                timeText,
                                style: AppTypography.labelMediumStyle.copyWith(
                                  color: sidebarTheme.foreground.withValues(
                                    alpha: 0.5,
                                  ),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (note.user != null &&
                                  note.user!.name != null) ...[
                                const SizedBox(width: Spacing.sm),
                                Text(
                                  '·',
                                  style: AppTypography.labelMediumStyle
                                      .copyWith(
                                        color: sidebarTheme.foreground
                                            .withValues(alpha: 0.3),
                                      ),
                                ),
                                const SizedBox(width: Spacing.sm),
                                Flexible(
                                  child: Text(
                                    note.user!.name!,
                                    style: AppTypography.labelMediumStyle
                                        .copyWith(
                                          color: sidebarTheme.foreground
                                              .withValues(alpha: 0.5),
                                          fontWeight: FontWeight.w500,
                                        ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  List<ConduitContextMenuAction> _buildNoteActions(
    BuildContext context,
    Note note,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.pencil,
        materialIcon: Icons.edit_rounded,
        label: l10n.edit,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          context.pushNamed(
            RouteNames.noteEditor,
            pathParameters: {'id': note.id},
          );
        },
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.doc_on_clipboard,
        materialIcon: Icons.copy_rounded,
        label: l10n.copy,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          await Clipboard.setData(ClipboardData(text: note.markdownContent));
          if (!context.mounted) return;
          AdaptiveSnackBar.show(
            context,
            message: l10n.noteCopiedToClipboard,
            type: AdaptiveSnackBarType.success,
            duration: const Duration(seconds: 2),
          );
        },
      ),
      ConduitContextMenuAction(
        cupertinoIcon: note.isPinned
            ? CupertinoIcons.pin_slash
            : CupertinoIcons.pin,
        materialIcon: note.isPinned ? UiUtils.unpinIcon : UiUtils.pinIcon,
        label: note.isPinned ? l10n.unpin : l10n.pin,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async => _togglePin(note),
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.delete,
        materialIcon: Icons.delete_rounded,
        label: l10n.delete,
        destructive: true,
        onBeforeClose: () => ConduitHaptics.mediumImpact(),
        onSelected: () async => _deleteNote(note),
      ),
    ];
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final l10n = AppLocalizations.of(context)!;
    final isSearchActive = _query.isNotEmpty;
    final topPadding = MediaQuery.of(context).padding.top;
    final appBarHeight = kTextTabBarHeight + 48 + Spacing.xs + Spacing.sm;

    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Spacing.xxl,
          topPadding + appBarHeight,
          Spacing.xxl,
          Spacing.xxl,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: sidebarTheme.accent.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppBorderRadius.lg),
              ),
              child: Icon(
                isSearchActive
                    ? (Platform.isIOS
                          ? CupertinoIcons.search
                          : Icons.search_off_rounded)
                    : (Platform.isIOS
                          ? CupertinoIcons.doc_text
                          : Icons.note_add_rounded),
                size: 32,
                color: sidebarTheme.foreground.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: Spacing.lg),
            Text(
              isSearchActive ? l10n.noNotesFound : l10n.noNotesYet,
              style: AppTypography.bodyLargeStyle.copyWith(
                color: sidebarTheme.foreground.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              isSearchActive
                  ? l10n.tryDifferentSearch
                  : l10n.createFirstNoteHint,
              style: AppTypography.bodySmallStyle.copyWith(
                color: sidebarTheme.foreground.withValues(alpha: 0.5),
              ),
              textAlign: TextAlign.center,
            ),
            if (!isSearchActive) ...[
              const SizedBox(height: Spacing.lg),
              AdaptiveButton.child(
                onPressed: _createNewNote,
                color: theme.buttonPrimary,
                style: AdaptiveButtonStyle.filled,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.lg,
                  vertical: Spacing.md,
                ),
                borderRadius: BorderRadius.circular(AppBorderRadius.button),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Platform.isIOS ? CupertinoIcons.add : Icons.add_rounded,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(l10n.createNote),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final topPadding = MediaQuery.of(context).padding.top;
    final appBarHeight = kTextTabBarHeight + 48 + Spacing.xs + Spacing.sm;
    return Padding(
      padding: EdgeInsets.only(top: topPadding + appBarHeight),
      child: Center(child: ImprovedLoadingState(message: l10n.loadingNotes)),
    );
  }

  Widget _buildError(BuildContext context, Object error) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final l10n = AppLocalizations.of(context)!;
    final topPadding = MediaQuery.of(context).padding.top;
    final appBarHeight = kTextTabBarHeight + 48 + Spacing.xs + Spacing.sm;

    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Spacing.xxl,
          topPadding + appBarHeight,
          Spacing.xxl,
          Spacing.xxl,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: sidebarTheme.accent.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppBorderRadius.lg),
              ),
              child: Icon(
                Platform.isIOS
                    ? CupertinoIcons.exclamationmark_triangle
                    : Icons.error_outline_rounded,
                size: 32,
                color: theme.error,
              ),
            ),
            const SizedBox(height: Spacing.md),
            Text(
              l10n.failedToLoadNotes,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: sidebarTheme.foreground.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.lg),
            AdaptiveButton.child(
              onPressed: _refreshNotes,
              color: sidebarTheme.foreground.withValues(alpha: 0.8),
              style: AdaptiveButtonStyle.bordered,
              borderRadius: BorderRadius.circular(AppBorderRadius.button),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Platform.isIOS
                        ? CupertinoIcons.refresh
                        : Icons.refresh_rounded,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Text(l10n.retry),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFAB(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;

    return AdaptiveFloatingActionButton(
      onPressed: _createNewNote,
      backgroundColor: theme.buttonPrimary,
      foregroundColor: theme.buttonPrimaryText,
      tooltip: l10n.createNote,
      child: Icon(Platform.isIOS ? CupertinoIcons.add : Icons.add_rounded),
    );
  }
}
