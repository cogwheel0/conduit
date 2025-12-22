import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../../core/providers/app_providers.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../../chat/providers/context_attachments_provider.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/widgets/loading_states.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/utils/user_display_name.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../core/models/model.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/hive_boxes.dart';
import 'package:hive_ce/hive.dart';
import '../../../shared/widgets/middle_ellipsis_text.dart';

/// Defines the section types that can be collapsed in the chats drawer
enum _SectionType { pinned, recent }

class ChatsDrawer extends ConsumerStatefulWidget {
  const ChatsDrawer({super.key});

  @override
  ConsumerState<ChatsDrawer> createState() => _ChatsDrawerState();
}

class _ChatsDrawerState extends ConsumerState<ChatsDrawer> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'drawer_search');
  final ScrollController _listController = ScrollController();
  Timer? _debounce;
  String _query = '';
  bool _isLoadingConversation = false;
  String? _pendingConversationId;
  String? _dragHoverFolderId;
  bool _isDragging = false;
  bool _draggingHasFolder = false;

  // UI state providers for sections
  static final _showArchivedProvider =
      NotifierProvider<_ShowArchivedNotifier, bool>(_ShowArchivedNotifier.new);
  static final _showPinnedProvider =
      NotifierProvider<_ShowPinnedNotifier, bool>(_ShowPinnedNotifier.new);
  static final _showFoldersProvider =
      NotifierProvider<_ShowFoldersNotifier, bool>(_ShowFoldersNotifier.new);
  static final _showRecentProvider =
      NotifierProvider<_ShowRecentNotifier, bool>(_ShowRecentNotifier.new);
  static final _expandedFoldersProvider =
      NotifierProvider<_ExpandedFoldersNotifier, Map<String, bool>>(
        _ExpandedFoldersNotifier.new,
      );

  Future<void> _refreshChats() async {
    try {
      // Always refresh folders and conversations cache
      refreshConversationsCache(ref, includeFolders: true);

      if (_query.trim().isEmpty) {
        // Refresh main conversations list
        try {
          await ref.read(conversationsProvider.future);
        } catch (_) {}
      } else {
        // Refresh server-side search results
        ref.invalidate(serverSearchProvider(_query));
        try {
          await ref.read(serverSearchProvider(_query).future);
        } catch (_) {}
      }

      // Await folders as well so the list stabilizes
      try {
        await ref.read(foldersProvider.future);
      } catch (_) {}
    } catch (_) {}
  }

  // Build a lazily-constructed sliver list of conversation tiles.
  Widget _conversationsSliver(
    List<dynamic> items, {
    bool inFolder = false,
    Map<String, Model> modelsById = const <String, Model>{},
  }) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _buildTileFor(
          items[index],
          inFolder: inFolder,
          modelsById: modelsById,
        ),
        childCount: items.length,
      ),
    );
  }

  // Legacy helper removed: drawer now uses slivers with lazy delegates.

  Widget _buildRefreshableScrollableSlivers({required List<Widget> slivers}) {
    // Add padding at top and bottom for floating elements
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final paddedSlivers = <Widget>[
      // Top padding for floating search bar area (sm + search height + md)
      const SliverToBoxAdapter(
        child: SizedBox(height: Spacing.sm + 48 + Spacing.md),
      ),
      ...slivers,
      // Bottom padding for floating user tile area (xl + tile height + md + safe area)
      SliverToBoxAdapter(
        child: SizedBox(height: Spacing.xl + 52 + Spacing.md + bottomPadding),
      ),
    ];

    final scroll = CustomScrollView(
      key: const PageStorageKey<String>('chats_drawer_scroll'),
      controller: _listController,
      physics: const AlwaysScrollableScrollPhysics(),
      cacheExtent: 800,
      slivers: paddedSlivers,
    );

    final refreshableScroll = ConduitRefreshIndicator(
      onRefresh: _refreshChats,
      child: scroll,
    );

    if (Platform.isIOS) {
      return CupertinoScrollbar(
        controller: _listController,
        child: refreshableScroll,
      );
    }

    return Scrollbar(controller: _listController, child: refreshableScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _listController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    // Bottom section now only shows navigation actions
    final sidebarTheme = context.sidebarTheme;

    return Container(
      decoration: BoxDecoration(
        color: sidebarTheme.background,
        border: Border(right: BorderSide(color: sidebarTheme.border)),
      ),
      child: Stack(
        children: [
          // Main scrollable content - extends behind floating elements
          Positioned.fill(child: _buildConversationList(context)),
          // Floating top area with gradient background (matches app bar pattern)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.4, 1.0],
                  colors: [
                    sidebarTheme.background,
                    sidebarTheme.background.withValues(alpha: 0.85),
                    sidebarTheme.background.withValues(alpha: 0.0),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Small top padding
                  const SizedBox(height: Spacing.sm),
                  // Floating search bar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.inputPadding,
                    ),
                    child: _buildFloatingSearchField(context),
                  ),
                  // Gradient fade area below
                  const SizedBox(height: Spacing.md),
                ],
              ),
            ),
          ),
          // Floating bottom area with gradient background (matches chat input pattern)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.4, 1.0],
                  colors: [
                    sidebarTheme.background.withValues(alpha: 0.0),
                    sidebarTheme.background.withValues(alpha: 0.85),
                    sidebarTheme.background,
                  ],
                ),
              ),
              child: Builder(
                builder: (context) {
                  final bottomPadding = MediaQuery.of(
                    context,
                  ).viewPadding.bottom;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Gradient fade area above
                      const SizedBox(height: Spacing.xl),
                      // Floating user tile
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          Spacing.screenPadding,
                          0,
                          Spacing.screenPadding,
                          bottomPadding + Spacing.md,
                        ),
                        child: _buildFloatingBottomSection(context),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingSearchField(BuildContext context) {
    final conduitTheme = context.conduitTheme;

    return FloatingAppBarPill(
      child: Material(
        color: Colors.transparent,
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          onChanged: (_) => _onSearchChanged(),
          style: AppTypography.standard.copyWith(
            color: conduitTheme.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: AppLocalizations.of(context)!.searchConversations,
            hintStyle: AppTypography.standard.copyWith(
              color: conduitTheme.textSecondary.withValues(alpha: 0.6),
            ),
            prefixIcon: Icon(
              Platform.isIOS ? CupertinoIcons.search : Icons.search,
              color: conduitTheme.iconSecondary,
              size: IconSize.input,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: TouchTarget.minimum,
              minHeight: TouchTarget.minimum,
            ),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                      _searchFocusNode.unfocus();
                    },
                    icon: Icon(
                      Platform.isIOS
                          ? CupertinoIcons.clear_circled_solid
                          : Icons.clear,
                      color: conduitTheme.iconSecondary,
                      size: IconSize.input,
                    ),
                  )
                : null,
            suffixIconConstraints: const BoxConstraints(
              minWidth: TouchTarget.minimum,
              minHeight: TouchTarget.minimum,
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversationList(BuildContext context) {
    final theme = context.conduitTheme;

    if (_query.isEmpty) {
      final conversationsAsync = ref.watch(conversationsProvider);
      return conversationsAsync.when(
        data: (items) {
          final list = items;
          // Build a models map once for this build.
          final modelsAsync = ref.watch(modelsProvider);
          final Map<String, Model> modelsById = modelsAsync.maybeWhen(
            data: (models) => {
              for (final m in models)
                if (m.id.isNotEmpty) m.id: m,
            },
            orElse: () => const <String, Model>{},
          );

          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Text(
                  AppLocalizations.of(context)!.noConversationsYet,
                  style: AppTypography.bodyMediumStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ),
            );
          }

          // Build sections
          final pinned = list.where((c) => c.pinned == true).toList();

          // Determine which folder IDs actually exist from the API
          final foldersState = ref.watch(foldersProvider);
          final availableFolderIds = foldersState.maybeWhen(
            data: (folders) => folders.map((f) => f.id).toSet(),
            orElse: () => <String>{},
          );

          // Conversations that reference a non-existent/unknown folder should not disappear.
          // Treat those as regular until the folders list is available and contains the ID.
          final regular = list.where((c) {
            final hasFolder = (c.folderId != null && c.folderId!.isNotEmpty);
            final folderKnown =
                hasFolder && availableFolderIds.contains(c.folderId);
            return c.pinned != true &&
                c.archived != true &&
                (!hasFolder || !folderKnown);
          }).toList();

          final foldered = list.where((c) {
            final hasFolder = (c.folderId != null && c.folderId!.isNotEmpty);
            return c.pinned != true &&
                c.archived != true &&
                hasFolder &&
                availableFolderIds.contains(c.folderId);
          }).toList();

          final archived = list.where((c) => c.archived == true).toList();

          final showPinned = ref.watch(_showPinnedProvider);
          final showFolders = ref.watch(_showFoldersProvider);
          final showRecent = ref.watch(_showRecentProvider);
          final foldersEnabled = ref.watch(foldersFeatureEnabledProvider);

          final slivers = <Widget>[
            if (pinned.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    AppLocalizations.of(context)!.pinned,
                    pinned.length,
                    sectionType: _SectionType.pinned,
                  ),
                ),
              ),
              if (showPinned) ...[
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
                _conversationsSliver(pinned, modelsById: modelsById),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
            ],

            // Folders section (hidden when feature is disabled server-side)
            if (foldersEnabled) ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(child: _buildFoldersSectionHeader()),
              ),
            ],
            if (showFolders && foldersEnabled) ...[
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
              if (_isDragging && _draggingHasFolder) ...[
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                  sliver: SliverToBoxAdapter(child: _buildUnfileDropTarget()),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.sm)),
              ],
              ...ref
                  .watch(foldersProvider)
                  .when(
                    data: (folders) {
                      final grouped = <String, List<dynamic>>{};
                      for (final c in foldered) {
                        final id = c.folderId!;
                        grouped.putIfAbsent(id, () => []).add(c);
                      }

                      final expandedMap = ref.watch(_expandedFoldersProvider);

                      final out = <Widget>[];
                      for (final folder in folders) {
                        final existing =
                            grouped[folder.id] ?? const <dynamic>[];
                        final convs = _resolveFolderConversations(
                          folder,
                          existing,
                        );
                        final isExpanded =
                            expandedMap[folder.id] ?? folder.isExpanded;
                        final hasItems = convs.isNotEmpty;
                        out.add(
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.md,
                            ),
                            sliver: SliverToBoxAdapter(
                              child: _buildFolderHeader(
                                folder.id,
                                folder.name,
                                convs.length,
                                defaultExpanded: folder.isExpanded,
                              ),
                            ),
                          ),
                        );
                        if (isExpanded && hasItems) {
                          out.add(
                            const SliverToBoxAdapter(
                              child: SizedBox(height: Spacing.xs),
                            ),
                          );
                          out.add(
                            _conversationsSliver(
                              convs,
                              inFolder: true,
                              modelsById: modelsById,
                            ),
                          );
                          out.add(
                            const SliverToBoxAdapter(
                              child: SizedBox(height: Spacing.sm),
                            ),
                          );
                        } else {
                          // Only add spacing after collapsed folders
                          out.add(
                            const SliverToBoxAdapter(
                              child: SizedBox(height: Spacing.xs),
                            ),
                          );
                        }
                      }
                      return out.isEmpty
                          ? <Widget>[
                              const SliverToBoxAdapter(
                                child: SizedBox.shrink(),
                              ),
                            ]
                          : out;
                    },
                    loading: () => [
                      const SliverToBoxAdapter(child: SizedBox.shrink()),
                    ],
                    error: (e, st) => [
                      const SliverToBoxAdapter(child: SizedBox.shrink()),
                    ],
                  ),
            ],
            if (foldersEnabled)
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),

            if (regular.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    AppLocalizations.of(context)!.recent,
                    regular.length,
                    sectionType: _SectionType.recent,
                  ),
                ),
              ),
              if (showRecent) ...[
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
                _conversationsSliver(regular, modelsById: modelsById),
              ],
            ],

            if (archived.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(
                  child: _buildArchivedHeader(archived.length),
                ),
              ),
              if (ref.watch(_showArchivedProvider)) ...[
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
                _conversationsSliver(archived, modelsById: modelsById),
              ],
            ],
          ];
          return _buildRefreshableScrollableSlivers(slivers: slivers);
        },
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Text(
              AppLocalizations.of(context)!.failedToLoadChats,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    // Server-backed search
    final searchAsync = ref.watch(serverSearchProvider(_query));
    return searchAsync.when(
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: Text(
                'No results for "$_query"',
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textSecondary,
                ),
              ),
            ),
          );
        }

        final pinned = list.where((c) => c.pinned == true).toList();
        // Build a models map once for search builds too.
        final modelsAsync = ref.watch(modelsProvider);
        final Map<String, Model> modelsById = modelsAsync.maybeWhen(
          data: (models) => {
            for (final m in models)
              if (m.id.isNotEmpty) m.id: m,
          },
          orElse: () => const <String, Model>{},
        );

        // For search results, apply the same folder safety logic
        final foldersState = ref.watch(foldersProvider);
        final availableFolderIds = foldersState.maybeWhen(
          data: (folders) => folders.map((f) => f.id).toSet(),
          orElse: () => <String>{},
        );

        final regular = list.where((c) {
          final hasFolder = (c.folderId != null && c.folderId!.isNotEmpty);
          final folderKnown =
              hasFolder && availableFolderIds.contains(c.folderId);
          return c.pinned != true &&
              c.archived != true &&
              (!hasFolder || !folderKnown);
        }).toList();

        final foldered = list.where((c) {
          final hasFolder = (c.folderId != null && c.folderId!.isNotEmpty);
          return c.pinned != true &&
              c.archived != true &&
              hasFolder &&
              availableFolderIds.contains(c.folderId);
        }).toList();

        final archived = list.where((c) => c.archived == true).toList();

        final showPinned = ref.watch(_showPinnedProvider);
        final showFolders = ref.watch(_showFoldersProvider);
        final showRecent = ref.watch(_showRecentProvider);

        final slivers = <Widget>[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            sliver: SliverToBoxAdapter(
              child: _buildSectionHeader('Results', list.length),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
        ];

        if (pinned.isNotEmpty) {
          slivers.addAll([
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              sliver: SliverToBoxAdapter(
                child: _buildSectionHeader(
                  AppLocalizations.of(context)!.pinned,
                  pinned.length,
                  sectionType: _SectionType.pinned,
                ),
              ),
            ),
          ]);
          if (showPinned) {
            slivers.addAll([
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
              _conversationsSliver(pinned, modelsById: modelsById),
            ]);
          }
          slivers.add(
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
          );
        }

        // Folders section (hidden when feature is disabled server-side)
        final foldersEnabled = ref.watch(foldersFeatureEnabledProvider);
        if (foldersEnabled) {
          slivers.add(
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              sliver: SliverToBoxAdapter(child: _buildFoldersSectionHeader()),
            ),
          );
        }

        if (showFolders && foldersEnabled) {
          slivers.add(
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
          );

          if (_isDragging && _draggingHasFolder) {
            slivers.add(
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(child: _buildUnfileDropTarget()),
              ),
            );
            slivers.add(
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.sm)),
            );
          }

          final folderSlivers = ref
              .watch(foldersProvider)
              .when(
                data: (folders) {
                  final grouped = <String, List<dynamic>>{};
                  for (final c in foldered) {
                    final id = c.folderId!;
                    grouped.putIfAbsent(id, () => []).add(c);
                  }
                  final expandedMap = ref.watch(_expandedFoldersProvider);
                  final out = <Widget>[];
                  for (final folder in folders) {
                    final existing = grouped[folder.id] ?? const <dynamic>[];
                    final convs = _resolveFolderConversations(folder, existing);
                    final isExpanded =
                        expandedMap[folder.id] ?? folder.isExpanded;
                    final hasItems = convs.isNotEmpty;

                    out.add(
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.md,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: _buildFolderHeader(
                            folder.id,
                            folder.name,
                            convs.length,
                            defaultExpanded: folder.isExpanded,
                          ),
                        ),
                      ),
                    );
                    if (isExpanded && hasItems) {
                      out.add(
                        const SliverToBoxAdapter(
                          child: SizedBox(height: Spacing.xs),
                        ),
                      );
                      out.add(
                        _conversationsSliver(
                          convs,
                          inFolder: true,
                          modelsById: modelsById,
                        ),
                      );
                      out.add(
                        const SliverToBoxAdapter(
                          child: SizedBox(height: Spacing.sm),
                        ),
                      );
                    } else {
                      // Only add spacing after collapsed folders
                      out.add(
                        const SliverToBoxAdapter(
                          child: SizedBox(height: Spacing.xs),
                        ),
                      );
                    }
                  }
                  return out.isEmpty
                      ? <Widget>[
                          const SliverToBoxAdapter(child: SizedBox.shrink()),
                        ]
                      : out;
                },
                loading: () => <Widget>[
                  const SliverToBoxAdapter(child: SizedBox.shrink()),
                ],
                error: (e, st) => <Widget>[
                  const SliverToBoxAdapter(child: SizedBox.shrink()),
                ],
              );
          slivers.addAll(folderSlivers);
        }

        if (foldersEnabled) {
          slivers.add(
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
          );
        }

        if (regular.isNotEmpty) {
          slivers.add(
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              sliver: SliverToBoxAdapter(
                child: _buildSectionHeader(
                  AppLocalizations.of(context)!.recent,
                  regular.length,
                  sectionType: _SectionType.recent,
                ),
              ),
            ),
          );
          if (showRecent) {
            slivers.addAll([
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
              _conversationsSliver(regular, modelsById: modelsById),
            ]);
          }
        }

        if (archived.isNotEmpty) {
          slivers.addAll([
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              sliver: SliverToBoxAdapter(
                child: _buildArchivedHeader(archived.length),
              ),
            ),
          ]);
          if (ref.watch(_showArchivedProvider)) {
            slivers.add(
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
            );
            slivers.add(_conversationsSliver(archived, modelsById: modelsById));
          }
        }

        return _buildRefreshableScrollableSlivers(slivers: slivers);
      },
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2.0)),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Text(
            'Search failed',
            style: AppTypography.bodyMediumStyle.copyWith(
              color: context.sidebarTheme.foreground.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    String title,
    int count, {
    _SectionType? sectionType,
  }) {
    final sidebarTheme = context.sidebarTheme;

    // Get the collapsed state for the section type
    bool isExpanded = true;
    VoidCallback? onToggle;

    if (sectionType == _SectionType.pinned) {
      isExpanded = ref.watch(_showPinnedProvider);
      onToggle = () => ref.read(_showPinnedProvider.notifier).toggle();
    } else if (sectionType == _SectionType.recent) {
      isExpanded = ref.watch(_showRecentProvider);
      onToggle = () => ref.read(_showRecentProvider.notifier).toggle();
    }

    final headerContent = Row(
      children: [
        if (onToggle != null) ...[
          Icon(
            isExpanded
                ? (Platform.isIOS
                      ? CupertinoIcons.chevron_down
                      : Icons.expand_more)
                : (Platform.isIOS
                      ? CupertinoIcons.chevron_right
                      : Icons.chevron_right),
            color: sidebarTheme.foreground.withValues(alpha: 0.6),
            size: IconSize.sm,
          ),
          const SizedBox(width: Spacing.xxs),
        ],
        Text(
          title,
          style: AppTypography.labelStyle.copyWith(
            color: sidebarTheme.foreground.withValues(alpha: 0.9),
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(width: Spacing.xs),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: sidebarTheme.accent.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(AppBorderRadius.xs),
            border: Border.all(
              color: sidebarTheme.border.withValues(alpha: 0.35),
              width: BorderWidth.micro,
            ),
          ),
          child: Text(
            '$count',
            style: AppTypography.tiny.copyWith(
              color: sidebarTheme.foreground.withValues(alpha: 0.8),
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ],
    );

    if (onToggle == null) {
      return headerContent;
    }

    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(AppBorderRadius.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
        child: headerContent,
      ),
    );
  }

  /// Header for the Folders section with a create button on the right
  Widget _buildFoldersSectionHeader() {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final isExpanded = ref.watch(_showFoldersProvider);

    return Row(
      children: [
        InkWell(
          onTap: () => ref.read(_showFoldersProvider.notifier).toggle(),
          borderRadius: BorderRadius.circular(AppBorderRadius.xs),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isExpanded
                      ? (Platform.isIOS
                            ? CupertinoIcons.chevron_down
                            : Icons.expand_more)
                      : (Platform.isIOS
                            ? CupertinoIcons.chevron_right
                            : Icons.chevron_right),
                  color: sidebarTheme.foreground.withValues(alpha: 0.6),
                  size: IconSize.sm,
                ),
                const SizedBox(width: Spacing.xxs),
                Text(
                  AppLocalizations.of(context)!.folders,
                  style: AppTypography.labelStyle.copyWith(
                    color: theme.textSecondary,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: AppLocalizations.of(context)!.newFolder,
          icon: Icon(
            Platform.isIOS
                ? CupertinoIcons.folder_badge_plus
                : Icons.create_new_folder_outlined,
            color: theme.iconPrimary,
          ),
          onPressed: _promptCreateFolder,
        ),
      ],
    );
  }

  Future<void> _promptCreateFolder() async {
    final name = await ThemedDialogs.promptTextInput(
      context,
      title: AppLocalizations.of(context)!.newFolder,
      hintText: AppLocalizations.of(context)!.folderName,
      confirmText: AppLocalizations.of(context)!.create,
      cancelText: AppLocalizations.of(context)!.cancel,
    );

    if (name == null) return;
    if (name.isEmpty) return;
    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      final created = await api.createFolder(name: name);
      final folder = Folder.fromJson(Map<String, dynamic>.from(created));
      HapticFeedback.lightImpact();
      ref.read(foldersProvider.notifier).upsertFolder(folder);
      refreshConversationsCache(ref, includeFolders: true);
    } catch (e, stackTrace) {
      if (!mounted) return;
      DebugLogger.error(
        'create-folder-failed',
        scope: 'drawer',
        error: e,
        stackTrace: stackTrace,
      );
      await _showDrawerError(
        AppLocalizations.of(context)!.failedToCreateFolder,
      );
    }
  }

  Widget _buildFolderHeader(
    String folderId,
    String name,
    int count, {
    bool defaultExpanded = false,
  }) {
    final theme = context.conduitTheme;
    final expandedMap = ref.watch(_expandedFoldersProvider);
    final isExpanded = expandedMap[folderId] ?? defaultExpanded;
    final isHover = _dragHoverFolderId == folderId;
    final baseColor = theme.surfaceContainer;
    final hoverColor = theme.buttonPrimary.withValues(alpha: 0.08);
    final borderColor = isHover
        ? theme.buttonPrimary.withValues(alpha: 0.60)
        : theme.surfaceContainerHighest.withValues(alpha: 0.40);

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

    return DropRegion(
      formats: const [], // Local data only
      onDropOver: (event) {
        setState(() => _dragHoverFolderId = folderId);
        return DropOperation.move;
      },
      onDropEnter: (_) => setState(() => _dragHoverFolderId = folderId),
      onDropLeave: (_) => setState(() => _dragHoverFolderId = null),
      onPerformDrop: (event) async {
        setState(() {
          _dragHoverFolderId = null;
          _isDragging = false;
        });
        // Get local data from the drop event (serialized as Map)
        final localData = event.session.items.first.localData;
        if (localData is! Map) return;
        final conversationId = localData['id'] as String?;
        if (conversationId == null) return;
        try {
          final api = ref.read(apiServiceProvider);
          if (api == null) throw Exception('No API service');
          await api.moveConversationToFolder(conversationId, folderId);
          HapticFeedback.selectionClick();
          ref
              .read(conversationsProvider.notifier)
              .updateConversation(
                conversationId,
                (conversation) => conversation.copyWith(
                  folderId: folderId,
                  updatedAt: DateTime.now(),
                ),
              );
          refreshConversationsCache(ref, includeFolders: true);
        } catch (e, stackTrace) {
          DebugLogger.error(
            'move-conversation-failed',
            scope: 'drawer',
            error: e,
            stackTrace: stackTrace,
          );
          if (mounted) {
            await _showDrawerError(
              AppLocalizations.of(context)!.failedToMoveChat,
            );
          }
        }
      },
      child: ConduitContextMenu(
        actions: _buildFolderActions(folderId, name),
        child: Material(
          color: isHover ? hoverColor : baseColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
            side: BorderSide(color: borderColor, width: BorderWidth.thin),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppBorderRadius.small),
            onTap: () {
              final current = {...ref.read(_expandedFoldersProvider)};
              final next = !isExpanded;
              current[folderId] = next;
              ref.read(_expandedFoldersProvider.notifier).set(current);
            },
            onLongPress: null, // Handled by ConduitContextMenu
            overlayColor: WidgetStateProperty.resolveWith(overlayForStates),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: TouchTarget.listItem,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.xs,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final hasFiniteWidth = constraints.maxWidth.isFinite;
                    final textFit = hasFiniteWidth
                        ? FlexFit.tight
                        : FlexFit.loose;

                    return Row(
                      mainAxisSize: hasFiniteWidth
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      children: [
                        Icon(
                          isExpanded
                              ? (Platform.isIOS
                                    ? CupertinoIcons.folder_open
                                    : Icons.folder_open)
                              : (Platform.isIOS
                                    ? CupertinoIcons.folder
                                    : Icons.folder),
                          color: theme.iconPrimary,
                          size: IconSize.listItem,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Flexible(
                          fit: textFit,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.standard.copyWith(
                                    color: theme.textPrimary,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                              const SizedBox(width: Spacing.xs),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: context.sidebarTheme.accent.withValues(
                                    alpha: 0.7,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppBorderRadius.xs,
                                  ),
                                  border: Border.all(
                                    color: context.sidebarTheme.border
                                        .withValues(alpha: 0.35),
                                    width: BorderWidth.micro,
                                  ),
                                ),
                                child: Text(
                                  '$count',
                                  style: AppTypography.tiny.copyWith(
                                    color: context.sidebarTheme.foreground
                                        .withValues(alpha: 0.8),
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: IconButton(
                            iconSize: IconSize.xs,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            style: IconButton.styleFrom(
                              shape: const CircleBorder(),
                            ),
                            icon: Icon(
                              Platform.isIOS
                                  ? CupertinoIcons.plus_circle
                                  : Icons.add_circle_outline_rounded,
                              color: theme.iconSecondary,
                              size: IconSize.listItem,
                            ),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              _startNewChatInFolder(folderId);
                            },
                            tooltip: AppLocalizations.of(context)!.newChat,
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        Icon(
                          isExpanded
                              ? (Platform.isIOS
                                    ? CupertinoIcons.chevron_up
                                    : Icons.expand_less)
                              : (Platform.isIOS
                                    ? CupertinoIcons.chevron_down
                                    : Icons.expand_more),
                          color: theme.iconSecondary,
                          size: IconSize.listItem,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<dynamic> _resolveFolderConversations(
    Folder folder,
    List<dynamic> existing,
  ) {
    // Preserve the current conversational ordering while ensuring items from
    // the folder metadata appear even if the main list has not fetched them
    // yet. This primarily happens when chats live exclusively inside folders
    // and the conversations endpoint omits them.
    final result = <dynamic>[];

    final existingMap = <String, dynamic>{};
    for (final item in existing) {
      final id = _conversationId(item);
      if (id != null) {
        existingMap[id] = item;
      }
    }

    if (folder.conversationIds.isNotEmpty) {
      for (final convId in folder.conversationIds) {
        final existingItem = existingMap.remove(convId);
        if (existingItem != null) {
          result.add(existingItem);
        } else {
          result.add(_placeholderConversation(convId, folder.id));
        }
      }

      // Append any remaining conversations that claim this folder but are
      // missing from the folder metadata list (defensive for API drift).
      result.addAll(existingMap.values);
    } else {
      result.addAll(existingMap.values);
    }

    return result;
  }

  Conversation _placeholderConversation(
    String conversationId,
    String folderId,
  ) {
    const fallbackTitle = 'Chat';
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return Conversation(
      id: conversationId,
      title: fallbackTitle,
      createdAt: epoch,
      updatedAt: epoch,
      folderId: folderId,
      messages: const [],
    );
  }

  String? _conversationId(dynamic item) {
    if (item is Conversation) return item.id;
    try {
      final value = item.id;
      if (value is String) {
        return value;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> _showDrawerError(String message) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    await ThemedDialogs.show<void>(
      context,
      title: l10n.errorMessage,
      content: Text(
        message,
        style: AppTypography.bodyMediumStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.ok),
        ),
      ],
    );
  }

  List<ConduitContextMenuAction> _buildFolderActions(
    String folderId,
    String folderName,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.pencil,
        materialIcon: Icons.edit_rounded,
        label: l10n.rename,
        onBeforeClose: () => HapticFeedback.selectionClick(),
        onSelected: () async {
          await _renameFolder(context, folderId, folderName);
        },
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.delete,
        materialIcon: Icons.delete_rounded,
        label: l10n.delete,
        destructive: true,
        onBeforeClose: () => HapticFeedback.mediumImpact(),
        onSelected: () async {
          await _confirmAndDeleteFolder(context, folderId, folderName);
        },
      ),
    ];
  }

  void _startNewChatInFolder(String folderId) {
    // Set the pending folder ID for the new conversation
    ref.read(pendingFolderIdProvider.notifier).set(folderId);

    // Clear current conversation and start fresh
    ref.read(chat.chatMessagesProvider.notifier).clearMessages();
    ref.read(activeConversationProvider.notifier).clear();

    // Clear context attachments (web pages, YouTube, knowledge base docs)
    ref.read(contextAttachmentsProvider.notifier).clear();

    // Reset to default model for new conversations (fixes #296)
    chat.restoreDefaultModel(ref);

    // Close drawer using the responsive layout (same pattern as _selectConversation)
    if (mounted) {
      final mediaQuery = MediaQuery.maybeOf(context);
      final isTablet =
          mediaQuery != null && mediaQuery.size.shortestSide >= 600;
      if (!isTablet) {
        ResponsiveDrawerLayout.of(context)?.close();
      }
    }
  }

  Future<void> _renameFolder(
    BuildContext context,
    String folderId,
    String currentName,
  ) async {
    final newName = await ThemedDialogs.promptTextInput(
      context,
      title: AppLocalizations.of(context)!.rename,
      hintText: AppLocalizations.of(context)!.folderName,
      initialValue: currentName,
      confirmText: AppLocalizations.of(context)!.save,
      cancelText: AppLocalizations.of(context)!.cancel,
    );

    if (newName == null) return;
    if (newName.isEmpty || newName == currentName) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      await api.updateFolder(folderId, name: newName);
      HapticFeedback.selectionClick();
      ref
          .read(foldersProvider.notifier)
          .updateFolder(
            folderId,
            (folder) =>
                folder.copyWith(name: newName, updatedAt: DateTime.now()),
          );
      refreshConversationsCache(ref, includeFolders: true);
    } catch (e, stackTrace) {
      if (!mounted) return;
      DebugLogger.error(
        'rename-folder-failed',
        scope: 'drawer',
        error: e,
        stackTrace: stackTrace,
      );
      await _showDrawerError('Failed to rename folder');
    }
  }

  Future<void> _confirmAndDeleteFolder(
    BuildContext context,
    String folderId,
    String folderName,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.deleteFolderTitle,
      message: l10n.deleteFolderMessage,
      confirmText: l10n.delete,
      isDestructive: true,
    );
    if (!mounted) return;
    if (!confirmed) return;

    final deleteFolderError = l10n.failedToDeleteFolder;
    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      await api.deleteFolder(folderId);
      HapticFeedback.mediumImpact();
      ref.read(foldersProvider.notifier).removeFolder(folderId);
      refreshConversationsCache(ref, includeFolders: true);
    } catch (e, stackTrace) {
      if (!mounted) return;
      DebugLogger.error(
        'delete-folder-failed',
        scope: 'drawer',
        error: e,
        stackTrace: stackTrace,
      );
      await _showDrawerError(deleteFolderError);
    }
  }

  Widget _buildUnfileDropTarget() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isHover = _dragHoverFolderId == '__UNFILE__';
    return DropRegion(
      formats: const [], // Local data only
      onDropOver: (event) {
        setState(() => _dragHoverFolderId = '__UNFILE__');
        return DropOperation.move;
      },
      onDropEnter: (_) => setState(() => _dragHoverFolderId = '__UNFILE__'),
      onDropLeave: (_) => setState(() => _dragHoverFolderId = null),
      onPerformDrop: (event) async {
        setState(() {
          _dragHoverFolderId = null;
          _isDragging = false;
        });
        // Get local data from the drop event (serialized as Map)
        final localData = event.session.items.first.localData;
        if (localData is! Map) return;
        final conversationId = localData['id'] as String?;
        if (conversationId == null) return;
        try {
          final api = ref.read(apiServiceProvider);
          if (api == null) throw Exception('No API service');
          await api.moveConversationToFolder(conversationId, null);
          HapticFeedback.selectionClick();
          ref
              .read(conversationsProvider.notifier)
              .updateConversation(
                conversationId,
                (conversation) => conversation.copyWith(
                  folderId: null,
                  updatedAt: DateTime.now(),
                ),
              );
          refreshConversationsCache(ref, includeFolders: true);
        } catch (e, stackTrace) {
          DebugLogger.error(
            'unfile-conversation-failed',
            scope: 'drawer',
            error: e,
            stackTrace: stackTrace,
          );
          if (mounted) {
            await _showDrawerError(l10n.failedToMoveChat);
          }
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isHover
              ? theme.buttonPrimary.withValues(alpha: 0.08)
              : theme.surfaceContainer.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          border: Border.all(
            color: isHover
                ? theme.buttonPrimary.withValues(alpha: 0.5)
                : theme.dividerColor.withValues(alpha: 0.5),
            width: BorderWidth.standard,
          ),
        ),
        padding: const EdgeInsets.all(Spacing.sm),
        child: Row(
          children: [
            Icon(
              Platform.isIOS
                  ? CupertinoIcons.folder_badge_minus
                  : Icons.folder_off_outlined,
              color: theme.iconPrimary,
              size: IconSize.small,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'Drop here to remove from folder',
                style: AppTypography.bodySmallStyle.copyWith(
                  color: theme.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTileFor(
    dynamic conv, {
    bool inFolder = false,
    Map<String, Model> modelsById = const <String, Model>{},
  }) {
    // Only rebuild this tile when its own selected state changes.
    final isActive = ref.watch(
      activeConversationProvider.select((c) => c?.id == conv.id),
    );
    final title = conv.title?.isEmpty == true ? 'Chat' : (conv.title ?? 'Chat');
    final theme = context.conduitTheme;
    final bool isLoadingSelected =
        (_pendingConversationId == conv.id) &&
        (ref.watch(chat.isLoadingConversationProvider) == true);
    final bool isPinned = conv.pinned == true;

    // Check if folders feature is enabled to enable drag
    final foldersEnabled = ref.watch(foldersFeatureEnabledProvider);
    final dragEnabled = foldersEnabled && !isLoadingSelected;

    final tileWidget = _ConversationTile(
      title: title,
      pinned: isPinned,
      selected: isActive,
      isLoading: isLoadingSelected,
      onTap: _isLoadingConversation
          ? null
          : () => _selectConversation(context, conv.id),
    );

    final contextMenuTile = ConduitContextMenu(
      actions: buildConversationActions(
        context: context,
        ref: ref,
        conversation: conv,
      ),
      child: Padding(
        padding: EdgeInsets.only(left: inFolder ? Spacing.sm : 0),
        child: tileWidget,
      ),
    );

    // Wrap with drag support if folders are enabled
    Widget tile;
    if (dragEnabled) {
      tile = DragItemWidget(
        allowedOperations: () => [DropOperation.move],
        canAddItemToExistingSession: true,
        dragItemProvider: (request) async {
          // Set drag state when drag starts
          HapticFeedback.lightImpact();
          final hasFolder =
              (conv.folderId != null && (conv.folderId as String).isNotEmpty);
          setState(() {
            _isDragging = true;
            _draggingHasFolder = hasFolder;
          });

          // Listen for drag completion to reset state
          void onDragCompleted() {
            if (mounted) {
              setState(() {
                _dragHoverFolderId = null;
                _isDragging = false;
                _draggingHasFolder = false;
              });
            }
            request.session.dragCompleted.removeListener(onDragCompleted);
          }

          request.session.dragCompleted.addListener(onDragCompleted);

          // Provide drag data with conversation info as serializable Map
          final item = DragItem(localData: {'id': conv.id, 'title': title});
          return item;
        },
        dragBuilder: (context, child) {
          // Custom drag preview
          return Opacity(
            opacity: 0.9,
            child: _ConversationDragFeedback(
              title: title,
              pinned: isPinned,
              theme: theme,
            ),
          );
        },
        child: DraggableWidget(child: contextMenuTile),
      );
    } else {
      tile = contextMenuTile;
    }

    return RepaintBoundary(child: tile);
  }

  Widget _buildArchivedHeader(int count) {
    final theme = context.conduitTheme;
    final show = ref.watch(_showArchivedProvider);
    return Material(
      color: show ? theme.navigationSelectedBackground : theme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        side: BorderSide(
          color: show
              ? theme.navigationSelected
              : theme.surfaceContainerHighest.withValues(alpha: 0.40),
          width: BorderWidth.thin,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        onTap: () => ref.read(_showArchivedProvider.notifier).set(!show),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return theme.buttonPrimary.withValues(alpha: Alpha.buttonPressed);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return theme.buttonPrimary.withValues(alpha: Alpha.hover);
          }
          return Colors.transparent;
        }),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.xs,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final hasFiniteWidth = constraints.maxWidth.isFinite;
                final textFit = hasFiniteWidth ? FlexFit.tight : FlexFit.loose;
                return Row(
                  mainAxisSize: hasFiniteWidth
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  children: [
                    Icon(
                      Platform.isIOS
                          ? CupertinoIcons.archivebox
                          : Icons.archive_rounded,
                      color: theme.iconPrimary,
                      size: IconSize.listItem,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Flexible(
                      fit: textFit,
                      child: Text(
                        AppLocalizations.of(context)!.archived,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.standard.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      '$count',
                      style: AppTypography.standard.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      show
                          ? (Platform.isIOS
                                ? CupertinoIcons.chevron_up
                                : Icons.expand_less)
                          : (Platform.isIOS
                                ? CupertinoIcons.chevron_down
                                : Icons.expand_more),
                      color: theme.iconSecondary,
                      size: IconSize.listItem,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _selectConversation(BuildContext context, String id) async {
    if (_isLoadingConversation) return;
    setState(() => _isLoadingConversation = true);
    // Keep a reference only if needed in the future; currently unused.
    // Capture a provider container detached from this widget's lifecycle so
    // we can continue to read/write providers after the drawer is closed.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      // Mark global loading to show skeletons in chat
      container.read(chat.isLoadingConversationProvider.notifier).set(true);
      _pendingConversationId = id;

      // Immediately clear current chat to show loading skeleton in the chat view
      container.read(activeConversationProvider.notifier).clear();
      container.read(chat.chatMessagesProvider.notifier).clearMessages();

      // Clear any pending folder selection when selecting an existing conversation
      container.read(pendingFolderIdProvider.notifier).clear();

      // Close the slide drawer for faster perceived performance
      // (only on mobile; keep tablet drawer unless user toggles it)
      if (mounted) {
        final mediaQuery = MediaQuery.maybeOf(context);
        final isTablet =
            mediaQuery != null && mediaQuery.size.shortestSide >= 600;
        if (!isTablet) {
          ResponsiveDrawerLayout.of(context)?.close();
        }
      }

      // Load the full conversation details in the background
      final api = container.read(apiServiceProvider);
      if (api != null) {
        final full = await api.getConversation(id);
        container.read(activeConversationProvider.notifier).set(full);
      } else {
        // Fallback: use the lightweight item to update the active conversation
        container
            .read(activeConversationProvider.notifier)
            .set(
              (await container.read(
                conversationsProvider.future,
              )).firstWhere((c) => c.id == id),
            );
      }

      // Clear loading after data is ready
      container.read(chat.isLoadingConversationProvider.notifier).set(false);
      _pendingConversationId = null;
    } catch (_) {
      container.read(chat.isLoadingConversationProvider.notifier).set(false);
      _pendingConversationId = null;
    } finally {
      if (mounted) setState(() => _isLoadingConversation = false);
    }
  }

  Widget _buildFloatingBottomSection(BuildContext context) {
    final conduitTheme = context.conduitTheme;
    final authUser = ref.watch(currentUserProvider2);
    final asyncUser = ref.watch(currentUserProvider);
    final user = asyncUser.maybeWhen(
      data: (value) => value ?? authUser,
      orElse: () => authUser,
    );
    final api = ref.watch(apiServiceProvider);
    final notesEnabled = ref.watch(notesFeatureEnabledProvider);

    String initialFor(String name) {
      if (name.isEmpty) return 'U';
      final ch = name.characters.first;
      return ch.toUpperCase();
    }

    final displayName = deriveUserDisplayName(user);
    final initial = initialFor(displayName);
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);

    if (user == null) return const SizedBox.shrink();

    return FloatingAppBarPill(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppBorderRadius.avatar),
                border: Border.all(
                  color: conduitTheme.buttonPrimary.withValues(alpha: 0.25),
                  width: BorderWidth.thin,
                ),
              ),
              clipBehavior: Clip.hardEdge,
              child: UserAvatar(
                size: 36,
                imageUrl: avatarUrl,
                fallbackText: initial,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: conduitTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
            // Notes icon (hidden when feature is disabled)
            if (notesEnabled)
              IconButton(
                tooltip: AppLocalizations.of(context)!.notes,
                onPressed: () {
                  Navigator.of(context).maybePop();
                  context.pushNamed(RouteNames.notes);
                },
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Platform.isIOS
                      ? CupertinoIcons.doc_text
                      : Icons.note_alt_outlined,
                  color: conduitTheme.iconPrimary,
                  size: IconSize.medium,
                ),
              ),
            IconButton(
              tooltip: AppLocalizations.of(context)!.manage,
              onPressed: () {
                Navigator.of(context).maybePop();
                context.pushNamed(RouteNames.profile);
              },
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Platform.isIOS
                    ? CupertinoIcons.settings
                    : Icons.settings_rounded,
                color: conduitTheme.iconPrimary,
                size: IconSize.medium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShowArchivedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

class _ShowPinnedNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.drawerShowPinned, defaultValue: true)
        as bool;
  }

  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.drawerShowPinned, state);
  }
}

class _ShowFoldersNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.drawerShowFolders, defaultValue: true)
        as bool;
  }

  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.drawerShowFolders, state);
  }
}

class _ShowRecentNotifier extends Notifier<bool> {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.preferences);

  @override
  bool build() {
    return _box.get(PreferenceKeys.drawerShowRecent, defaultValue: true)
        as bool;
  }

  void toggle() {
    state = !state;
    _box.put(PreferenceKeys.drawerShowRecent, state);
  }
}

class _ExpandedFoldersNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => {};

  void set(Map<String, bool> value) => state = Map<String, bool>.from(value);
}

class _ConversationDragFeedback extends StatelessWidget {
  final String title;
  final bool pinned;
  final ConduitThemeExtension theme;

  const _ConversationDragFeedback({
    required this.title,
    required this.pinned,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(AppBorderRadius.small);
    final borderColor = theme.surfaceContainerHighest.withValues(alpha: 0.40);

    return Material(
      color: Colors.transparent,
      elevation: Elevation.low,
      borderRadius: borderRadius,
      child: Container(
        constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.xs,
        ),
        decoration: BoxDecoration(
          color: theme.surfaceContainer,
          borderRadius: borderRadius,
          border: Border.all(color: borderColor, width: BorderWidth.thin),
        ),
        child: _ConversationTileContent(
          title: title,
          pinned: pinned,
          selected: false,
          isLoading: false,
        ),
      ),
    );
  }
}

class _ConversationTileContent extends StatelessWidget {
  final String title;
  final bool pinned;
  final bool selected;
  final bool isLoading;

  const _ConversationTileContent({
    required this.title,
    required this.pinned,
    required this.selected,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    // Enhanced typography with better visual hierarchy
    final textStyle = AppTypography.standard.copyWith(
      color: selected ? theme.textPrimary : theme.textSecondary,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      height: 1.4,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasFiniteWidth = constraints.maxWidth.isFinite;
        final textFit = hasFiniteWidth ? FlexFit.tight : FlexFit.loose;

        final trailingWidgets = <Widget>[];

        if (pinned) {
          trailingWidgets.addAll([
            const SizedBox(width: Spacing.sm),
            Container(
              padding: const EdgeInsets.all(Spacing.xxs),
              decoration: BoxDecoration(
                color: theme.buttonPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppBorderRadius.xs),
              ),
              child: Icon(
                Platform.isIOS
                    ? CupertinoIcons.pin_fill
                    : Icons.push_pin_rounded,
                color: theme.buttonPrimary.withValues(alpha: 0.7),
                size: IconSize.xs,
              ),
            ),
          ]);
        }

        if (isLoading) {
          trailingWidgets.addAll([
            const SizedBox(width: Spacing.sm),
            SizedBox(
              width: IconSize.sm,
              height: IconSize.sm,
              child: CircularProgressIndicator(
                strokeWidth: BorderWidth.medium,
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.loadingIndicator,
                ),
              ),
            ),
          ]);
        }

        return Row(
          mainAxisSize: hasFiniteWidth ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Flexible(
              fit: textFit,
              child: MiddleEllipsisText(
                title,
                style: textStyle,
                semanticsLabel: title,
              ),
            ),
            ...trailingWidgets,
          ],
        );
      },
    );
  }
}

class _ConversationTile extends StatefulWidget {
  final String title;
  final bool pinned;
  final bool selected;
  final bool isLoading;
  final VoidCallback? onTap;

  const _ConversationTile({
    required this.title,
    required this.pinned,
    required this.selected,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final borderRadius = BorderRadius.circular(AppBorderRadius.sm);

    // Use opaque backgrounds for proper context menu snapshot rendering
    final Color baseBackground = sidebarTheme.background;

    final Color background = widget.selected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            baseBackground,
          )
        : (_isHovered
              ? Color.alphaBlend(
                  theme.buttonPrimary.withValues(alpha: 0.05),
                  baseBackground,
                )
              : baseBackground);

    // Border styling
    final Color borderColor = widget.selected
        ? theme.buttonPrimary.withValues(alpha: 0.4)
        : Colors.transparent;

    Color? overlayForStates(Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return theme.buttonPrimary.withValues(alpha: Alpha.buttonPressed);
      }
      return Colors.transparent;
    }

    return Semantics(
      selected: widget.selected,
      button: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(
            horizontal: Spacing.xs,
            vertical: Spacing.xxs,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: borderRadius,
            border: widget.selected
                ? Border.all(color: borderColor, width: BorderWidth.regular)
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: borderRadius,
            child: InkWell(
              borderRadius: borderRadius,
              onTap: widget.isLoading ? null : widget.onTap,
              overlayColor: WidgetStateProperty.resolveWith(overlayForStates),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: TouchTarget.listItem,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md,
                    vertical: Spacing.sm,
                  ),
                  child: _ConversationTileContent(
                    title: widget.title,
                    pinned: widget.pinned,
                    selected: widget.selected,
                    isLoading: widget.isLoading,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Bottom quick actions widget removed as design now shows only profile card
