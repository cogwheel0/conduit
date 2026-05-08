import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../../../core/utils/debug_logger.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import 'conversation_tile.dart';
import 'create_folder_dialog.dart';
import 'folder_tree_guides.dart';
import 'drawer_section_notifiers.dart';
import 'folder_icon.dart';
import '../providers/sidebar_providers.dart';

/// Chevron / expand icon for section headers — matches folder row disclosure.
IconData _chatsDrawerDisclosureIcon(bool isExpanded) {
  if (Platform.isIOS) {
    return isExpanded
        ? CupertinoIcons.chevron_down
        : CupertinoIcons.chevron_right;
  }
  return isExpanded ? Icons.expand_more : Icons.chevron_right_rounded;
}

/// Defines the section types that can be collapsed in the chats drawer
enum _SectionType { pinned, recent }

class ChatsDrawer extends ConsumerStatefulWidget {
  const ChatsDrawer({super.key});

  @override
  ConsumerState<ChatsDrawer> createState() => _ChatsDrawerState();
}

class _ChatsDrawerState extends ConsumerState<ChatsDrawer>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late final TextEditingController _sidebarSearchController;
  final ScrollController _listController = ScrollController();
  Timer? _debounce;
  String _query = '';
  bool _isLoadingConversation = false;
  String? _pendingConversationId;
  bool _isLoadingMoreConversations = false;

  @override
  void initState() {
    super.initState();
    _listController.addListener(_onListScrolled);
    _sidebarSearchController = ref.read(sidebarSearchFieldControllerProvider);
    _sidebarSearchController.addListener(_onSearchChanged);
  }

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

  void _onListScrolled() {
    unawaited(_maybeLoadMoreConversations());
  }

  void _queuePaginationCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_maybeLoadMoreConversations());
    });
  }

  Future<void> _maybeLoadMoreConversations() async {
    if (!mounted || _query.isNotEmpty || _isLoadingMoreConversations) {
      return;
    }
    if (!_listController.hasClients) {
      return;
    }

    final conversationsAsync = ref.read(conversationsProvider);
    if (!conversationsAsync.hasValue || conversationsAsync.isLoading) {
      return;
    }

    final notifier = ref.read(conversationsProvider.notifier);
    if (!notifier.hasMoreRegularChats() ||
        notifier.isLoadingMoreRegularChats()) {
      return;
    }
    if (ref.read(apiServiceProvider) == null) {
      return;
    }

    final position = _listController.position;
    final distanceToBottom = position.maxScrollExtent - position.pixels;
    final shouldLoadMore =
        position.maxScrollExtent <= 0 || distanceToBottom <= 240;
    if (!shouldLoadMore) {
      return;
    }

    setState(() => _isLoadingMoreConversations = true);
    try {
      await notifier.loadMore();
    } catch (_) {
      // The provider logs and preserves the current drawer state on failures.
    } finally {
      if (mounted) {
        setState(() => _isLoadingMoreConversations = false);
      }
    }
  }

  // Build a lazily-constructed sliver list of conversation tiles.
  Widget _conversationsSliver(
    List<dynamic> items, {
    List<bool> ancestorHasMoreSiblings = const <bool>[],
    bool foldersEnabled = false,
    List<Folder> folders = const <Folder>[],
  }) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _buildTileFor(
          items[index],
          ancestorHasMoreSiblings: ancestorHasMoreSiblings,
          showHierarchyBranch: ancestorHasMoreSiblings.isNotEmpty,
          hasMoreSiblings: index < items.length - 1,
          foldersEnabled: foldersEnabled,
          folders: folders,
        ),
        childCount: items.length,
      ),
    );
  }

  // Legacy helper removed: drawer now uses slivers with lazy delegates.

  Widget _buildRefreshableScrollableSlivers({required List<Widget> slivers}) {
    // Top inset matches Notes tab pinned header row (`EdgeInsets` top 8).
    // Bottom inset keeps the last row clear of the native bottom tab bar.
    final paddedSlivers = <Widget>[
      SliverToBoxAdapter(
        child: SizedBox(height: sidebarTabContentTopPadding(context)),
      ),
      ...slivers,
      // Bottom padding for the tab bar and a little breathing room.
      SliverToBoxAdapter(
        child: SizedBox(height: sidebarTabContentBottomPadding(context)),
      ),
    ];

    final scroll = CustomScrollView(
      key: const PageStorageKey<String>('chats_drawer_scroll'),
      controller: _listController,
      physics: const AlwaysScrollableScrollPhysics(),
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

  Widget _buildPaginationFooter() {
    final theme = context.conduitTheme;
    final showSpinner = _isLoadingMoreConversations;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Center(
          child: showSpinner
              ? SizedBox(
                  width: IconSize.sm,
                  height: IconSize.sm,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.loadingIndicator,
                    ),
                  ),
                )
              : const SizedBox(height: Spacing.md),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _listController.removeListener(_onListScrolled);
    _sidebarSearchController.removeListener(_onSearchChanged);
    _listController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = _sidebarSearchController.text.trim());
    });
  }

  void _setFolderExpanded(String folderId, bool isExpanded) {
    final current = {...ref.read(expandedFoldersProvider)};
    current[folderId] = isExpanded;
    ref.read(expandedFoldersProvider.notifier).set(current);
  }

  void _openFolderPage(String folderId) {
    if (NavigationService.currentFolderId == folderId) {
      return;
    }

    ConduitHaptics.selectionClick();
    ref.read(pendingFolderIdProvider.notifier).clear();
    NavigationService.router.goNamed(
      RouteNames.folder,
      pathParameters: {'id': folderId},
    );

    if (mounted) {
      final mediaQuery = MediaQuery.maybeOf(context);
      final isTablet =
          mediaQuery != null && mediaQuery.size.shortestSide >= 600;
      if (!isTablet) {
        ResponsiveDrawerLayout.of(context)?.close();
      }
    }
  }

  String? _normalizeParentId(String? parentId) {
    if (parentId == null || parentId.isEmpty) {
      return null;
    }
    return parentId;
  }

  List<Widget> _buildFolderSectionSlivers({
    required List<Folder> folders,
    Map<String, List<dynamic>> folderConversationFallbacks =
        const <String, List<dynamic>>{},
    bool fetchFromServerForFolders = true,
  }) {
    final foldersById = <String, Folder>{
      for (final folder in folders) folder.id: folder,
    };

    final childFoldersByParentId = <String?, List<Folder>>{};
    for (final folder in folders) {
      final parentId = _normalizeParentId(folder.parentId);
      final resolvedParentId =
          parentId != null && foldersById.containsKey(parentId)
          ? parentId
          : null;
      childFoldersByParentId
          .putIfAbsent(resolvedParentId, () => <Folder>[])
          .add(folder);
    }

    for (final childFolders in childFoldersByParentId.values) {
      childFolders.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    }

    final rootFolders = childFoldersByParentId[null] ?? const <Folder>[];
    final slivers = <Widget>[];

    for (var rootIndex = 0; rootIndex < rootFolders.length; rootIndex++) {
      final folder = rootFolders[rootIndex];
      slivers.addAll(
        _buildFolderBranchSlivers(
          folder: folder,
          allFolders: folders,
          childFoldersByParentId: childFoldersByParentId,
          folderConversationFallbacks: folderConversationFallbacks,
          fetchFromServerForFolders: fetchFromServerForFolders,
          depth: 0,
          hasMoreSiblings: rootIndex < rootFolders.length - 1,
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildFolderBranchSlivers({
    required Folder folder,
    required List<Folder> allFolders,
    required Map<String?, List<Folder>> childFoldersByParentId,
    Map<String, List<dynamic>> folderConversationFallbacks =
        const <String, List<dynamic>>{},
    bool fetchFromServerForFolders = true,
    required int depth,
    required bool hasMoreSiblings,
    List<bool> ancestorHasMoreSiblings = const <bool>[],
    Set<String> visitedFolderIds = const <String>{},
    bool suppressTrailingConversationGap = false,
  }) {
    if (visitedFolderIds.contains(folder.id)) {
      return const <Widget>[];
    }

    final nextVisitedFolderIds = {...visitedFolderIds, folder.id};
    final childFolders = childFoldersByParentId[folder.id] ?? const <Folder>[];
    final isExpanded =
        ref.watch(expandedFoldersProvider)[folder.id] ?? folder.isExpanded;
    final fallbackConversations =
        folderConversationFallbacks[folder.id] ?? const <dynamic>[];
    final placeholderConversations = fallbackConversations.isNotEmpty
        ? fallbackConversations
        : _placeholderConversationsForFolder(folder);
    final folderConversationsAsync = !fetchFromServerForFolders || !isExpanded
        ? null
        : ref.watch(folderConversationSummariesProvider(folder.id));
    final conversations =
        folderConversationsAsync?.maybeWhen(
          data: (loadedConversations) => loadedConversations.isNotEmpty
              ? loadedConversations
              : placeholderConversations,
          orElse: () => placeholderConversations,
        ) ??
        placeholderConversations;
    final isFolderLoading =
        fetchFromServerForFolders &&
        (folderConversationsAsync?.isLoading == true);
    final nextAncestorHasMoreSiblings = [
      ...ancestorHasMoreSiblings,
      hasMoreSiblings,
    ];
    final slivers = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.md),
        sliver: SliverToBoxAdapter(
          child: _buildFolderHeader(
            folder: folder,
            allFolders: allFolders,
            depth: depth,
            hasMoreSiblings: hasMoreSiblings,
            ancestorHasMoreSiblings: ancestorHasMoreSiblings,
          ),
        ),
      ),
    ];

    final hasExpandableContent =
        childFolders.isNotEmpty || conversations.isNotEmpty || isFolderLoading;
    if (!isExpanded || !hasExpandableContent) {
      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
      );
      return slivers;
    }

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)));

    final hasTrailingChildContent = isFolderLoading || conversations.isNotEmpty;
    for (var index = 0; index < childFolders.length; index++) {
      final childFolder = childFolders[index];
      final isLastChildFolder = index == childFolders.length - 1;
      slivers.addAll(
        _buildFolderBranchSlivers(
          folder: childFolder,
          allFolders: allFolders,
          childFoldersByParentId: childFoldersByParentId,
          folderConversationFallbacks: folderConversationFallbacks,
          fetchFromServerForFolders: fetchFromServerForFolders,
          depth: depth + 1,
          hasMoreSiblings:
              index < childFolders.length - 1 || hasTrailingChildContent,
          ancestorHasMoreSiblings: nextAncestorHasMoreSiblings,
          visitedFolderIds: nextVisitedFolderIds,
          suppressTrailingConversationGap:
              isLastChildFolder && hasTrailingChildContent,
        ),
      );
    }

    if (childFolders.isNotEmpty && hasTrailingChildContent) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.md),
          sliver: SliverToBoxAdapter(
            child: FolderTreeIntergroupGap(
              ancestorHasMoreSiblings: nextAncestorHasMoreSiblings,
            ),
          ),
        ),
      );
    }

    if (isFolderLoading && conversations.isEmpty) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.md),
          sliver: SliverPadding(
            padding: EdgeInsets.only(
              left:
                  (nextAncestorHasMoreSiblings.length + 1) *
                  FolderTreeHierarchyNode.segmentWidth,
            ),
            sliver: const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                child: Center(
                  child: SizedBox(
                    width: IconSize.sm,
                    height: IconSize.sm,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else if (conversations.isNotEmpty) {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.md),
          sliver: _conversationsSliver(
            conversations,
            ancestorHasMoreSiblings: nextAncestorHasMoreSiblings,
            foldersEnabled: true,
            folders: allFolders,
          ),
        ),
      );
      if (!suppressTrailingConversationGap) {
        slivers.add(
          const SliverToBoxAdapter(child: SizedBox(height: Spacing.sm)),
        );
      }
    }

    return slivers;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildConversationList(context);
  }

  Widget _buildConversationList(BuildContext context) {
    final theme = context.conduitTheme;

    if (_query.isEmpty) {
      final conversationsAsync = ref.watch(conversationsProvider);
      return conversationsAsync.when(
        data: (items) {
          final list = items;
          final conversationsNotifier = ref.read(
            conversationsProvider.notifier,
          );
          final hasMoreRegularChats =
              conversationsNotifier.hasMoreRegularChats() ||
              _isLoadingMoreConversations;
          final foldersEnabled = ref.watch(foldersFeatureEnabledProvider);
          final foldersState = ref.watch(foldersProvider);
          final folders = foldersState.maybeWhen(
            data: (folders) => folders,
            orElse: () => const <Folder>[],
          );
          final hasVisibleFolders = foldersEnabled && folders.isNotEmpty;

          if (list.isEmpty && !hasVisibleFolders) {
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
          final availableFolderIds = folders.map((f) => f.id).toSet();

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
          final folderConversationFallbacks = <String, List<dynamic>>{};
          for (final conversation in foldered) {
            final folderId = conversation.folderId;
            if (folderId != null && folderId.isNotEmpty) {
              folderConversationFallbacks
                  .putIfAbsent(folderId, () => <dynamic>[])
                  .add(conversation);
            }
          }

          final archived = list.where((c) => c.archived == true).toList();

          final showPinned = ref.watch(showPinnedProvider);
          final showFolders = ref.watch(showFoldersProvider);
          final showRecent = ref.watch(showRecentProvider);

          final slivers = <Widget>[
            if (pinned.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    AppLocalizations.of(context)!.pinned,
                    sectionType: _SectionType.pinned,
                  ),
                ),
              ),
              if (showPinned) ...[
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
                _conversationsSliver(
                  pinned,
                  foldersEnabled: foldersEnabled,
                  folders: folders,
                ),
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
              ...foldersState.when(
                data: (folders) => _buildFolderSectionSlivers(
                  folders: folders,
                  folderConversationFallbacks: folderConversationFallbacks,
                ),
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
                    sectionType: _SectionType.recent,
                  ),
                ),
              ),
              if (showRecent) ...[
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
                _conversationsSliver(
                  regular,
                  foldersEnabled: foldersEnabled,
                  folders: folders,
                ),
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
              if (ref.watch(showArchivedProvider)) ...[
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
                _conversationsSliver(
                  archived,
                  foldersEnabled: foldersEnabled,
                  folders: folders,
                ),
              ],
            ],
            if (hasMoreRegularChats) _buildPaginationFooter(),
          ];
          if (hasMoreRegularChats) {
            _queuePaginationCheck();
          }
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

        // For search results, apply the same folder safety logic
        final foldersEnabled = ref.watch(foldersFeatureEnabledProvider);
        final foldersState = ref.watch(foldersProvider);
        final folders = foldersState.maybeWhen(
          data: (folders) => folders,
          orElse: () => const <Folder>[],
        );
        final availableFolderIds = folders.map((f) => f.id).toSet();

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
        final folderSearchResults = <String, List<dynamic>>{};
        for (final conversation in foldered) {
          final folderId = conversation.folderId;
          if (folderId != null && folderId.isNotEmpty) {
            folderSearchResults
                .putIfAbsent(folderId, () => <dynamic>[])
                .add(conversation);
          }
        }

        final archived = list.where((c) => c.archived == true).toList();

        final showPinned = ref.watch(showPinnedProvider);
        final showFolders = ref.watch(showFoldersProvider);
        final showRecent = ref.watch(showRecentProvider);

        final slivers = <Widget>[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            sliver: SliverToBoxAdapter(
              child: _buildSectionHeader('Results', count: list.length),
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
                  sectionType: _SectionType.pinned,
                ),
              ),
            ),
          ]);
          if (showPinned) {
            slivers.addAll([
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
              _conversationsSliver(
                pinned,
                foldersEnabled: foldersEnabled,
                folders: folders,
              ),
            ]);
          }
          slivers.add(
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
          );
        }

        // Folders section (hidden when feature is disabled server-side)
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

          final folderSlivers = foldersState.when(
            data: (folders) => _buildFolderSectionSlivers(
              folders: folders,
              folderConversationFallbacks: folderSearchResults,
              fetchFromServerForFolders: false,
            ),
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
                  sectionType: _SectionType.recent,
                ),
              ),
            ),
          );
          if (showRecent) {
            slivers.addAll([
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
              _conversationsSliver(
                regular,
                foldersEnabled: foldersEnabled,
                folders: folders,
              ),
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
          if (ref.watch(showArchivedProvider)) {
            slivers.add(
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
            );
            slivers.add(
              _conversationsSliver(
                archived,
                foldersEnabled: foldersEnabled,
                folders: folders,
              ),
            );
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
    String title, {
    _SectionType? sectionType,
    int? count,
  }) {
    // Get the collapsed state for the section type
    bool isExpanded = true;
    VoidCallback? onToggle;

    if (sectionType == _SectionType.pinned) {
      isExpanded = ref.watch(showPinnedProvider);
      onToggle = () => ref.read(showPinnedProvider.notifier).toggle();
    } else if (sectionType == _SectionType.recent) {
      isExpanded = ref.watch(showRecentProvider);
      onToggle = () => ref.read(showRecentProvider.notifier).toggle();
    }

    final theme = context.conduitTheme;
    final titleStyle = AppTypography.labelStyle.copyWith(
      color: theme.textSecondary,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.none,
    );
    final headerContent = Row(
      children: [
        if (onToggle != null) ...[
          Icon(
            _chatsDrawerDisclosureIcon(isExpanded),
            color: theme.iconSecondary,
            size: IconSize.listItem,
          ),
          const SizedBox(width: Spacing.xxs),
        ],
        Text(title, style: titleStyle),
        if (count != null) ...[
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
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ],
    );

    if (onToggle == null) {
      return headerContent;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
        child: headerContent,
      ),
    );
  }

  /// Header for the Folders section with a create button on the right
  Widget _buildFoldersSectionHeader() {
    final theme = context.conduitTheme;
    final isExpanded = ref.watch(showFoldersProvider);

    return Row(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ref.read(showFoldersProvider.notifier).toggle(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _chatsDrawerDisclosureIcon(isExpanded),
                  color: theme.iconSecondary,
                  size: IconSize.listItem,
                ),
                const SizedBox(width: Spacing.xxs),
                Text(
                  AppLocalizations.of(context)!.folders,
                  style: AppTypography.labelStyle.copyWith(
                    color: theme.textSecondary,
                    fontWeight: FontWeight.w700,
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
          onPressed: () =>
              CreateFolderDialog.show(context, ref, onError: _showDrawerError),
        ),
      ],
    );
  }

  Widget _buildFolderHeader({
    required Folder folder,
    required List<Folder> allFolders,
    required int depth,
    required bool hasMoreSiblings,
    required List<bool> ancestorHasMoreSiblings,
  }) {
    final folderId = folder.id;
    final name = folder.name;
    final theme = context.conduitTheme;
    final routeListenable = NavigationService.router.routeInformationProvider;

    return ValueListenableBuilder<RouteInformation>(
      valueListenable: routeListenable,
      builder: (context, routeInformation, child) {
        final expandedMap = ref.watch(expandedFoldersProvider);
        final isExpanded = expandedMap[folderId] ?? folder.isExpanded;
        final isCurrentFolder = NavigationService.currentFolderId == folderId;
        final baseColor = isCurrentFolder
            ? theme.navigationSelectedBackground
            : theme.surfaceContainer;
        final borderColor = isCurrentFolder
            ? theme.navigationSelected.withValues(alpha: 0.7)
            : theme.surfaceContainerHighest.withValues(alpha: 0.40);

        final rowContent = GestureDetector(
          behavior: HitTestBehavior.opaque,
          key: ValueKey<String>('folder-open-$folderId'),
          onTap: () => _openFolderPage(folderId),
          onLongPress: null, // Handled by ConduitContextMenu
          child: Container(
            decoration: BoxDecoration(
              color: baseColor,
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
              border: Border.all(color: borderColor, width: BorderWidth.thin),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: TouchTarget.listItem,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.xs,
                ),
                child: Row(
                  children: [
                    FolderIconGlyph(
                      iconAlias: folder.meta?['icon']?.toString(),
                      isOpen: isExpanded,
                      size: IconSize.listItem,
                      color: theme.iconPrimary,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.sidebarTitleStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: isCurrentFolder
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: IconButton(
                        key: ValueKey<String>('folder-expand-$folderId'),
                        iconSize: IconSize.xs,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        style: IconButton.styleFrom(
                          shape: const CircleBorder(),
                        ),
                        icon: Icon(
                          _chatsDrawerDisclosureIcon(isExpanded),
                          color: theme.iconSecondary,
                          size: IconSize.listItem,
                        ),
                        onPressed: () {
                          ConduitHaptics.selectionClick();
                          _setFolderExpanded(folderId, !isExpanded);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final hierarchyWrapped = depth == 0
            ? rowContent
            : FolderTreeHierarchyNode(
                key: ValueKey<String>('tree-guides-folder-$folderId'),
                ancestorHasMoreSiblings: ancestorHasMoreSiblings,
                showBranch: true,
                hasMoreSiblings: hasMoreSiblings,
                child: rowContent,
              );

        return ConduitContextMenu(
          actions: _buildFolderActions(folder, allFolders),
          child: hierarchyWrapped,
        );
      },
    );
  }

  List<Conversation> _placeholderConversationsForFolder(Folder folder) {
    return folder.conversationIds
        .map(
          (conversationId) =>
              _placeholderConversation(conversationId, folder.id),
        )
        .toList(growable: false);
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
        AdaptiveButton(
          onPressed: () => Navigator.of(context).pop(),
          label: l10n.ok,
          style: AdaptiveButtonStyle.plain,
        ),
      ],
    );
  }

  List<ConduitContextMenuAction> _buildFolderActions(
    Folder folder,
    List<Folder> folders,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final folderId = folder.id;
    final folderName = folder.name;
    final moveTargets = _folderMoveTargets(folder, folders);
    final canMove =
        _normalizeParentId(folder.parentId) != null || moveTargets.isNotEmpty;

    return [
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.folder_badge_plus,
        materialIcon: Icons.create_new_folder_outlined,
        label: l10n.newFolder,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          _setFolderExpanded(folderId, true);
          await CreateFolderDialog.show(
            context,
            ref,
            onError: _showDrawerError,
            parentId: folderId,
          );
        },
      ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.pencil,
        materialIcon: Icons.edit_rounded,
        label: l10n.rename,
        onBeforeClose: () => ConduitHaptics.selectionClick(),
        onSelected: () async {
          await _renameFolder(context, folderId, folderName);
        },
      ),
      if (canMove)
        ConduitContextMenuAction(
          cupertinoIcon: CupertinoIcons.folder,
          materialIcon: Icons.drive_file_move_outline,
          label: 'Move',
          onBeforeClose: () => ConduitHaptics.selectionClick(),
          onSelected: () async {
            await _moveFolder(folder, folders);
          },
        ),
      ConduitContextMenuAction(
        cupertinoIcon: CupertinoIcons.delete,
        materialIcon: Icons.delete_rounded,
        label: l10n.delete,
        destructive: true,
        onBeforeClose: () => ConduitHaptics.mediumImpact(),
        onSelected: () async {
          await _confirmAndDeleteFolder(context, folderId, folderName);
        },
      ),
    ];
  }

  List<Folder> _folderMoveTargets(Folder folder, List<Folder> folders) {
    final foldersById = <String, Folder>{
      for (final candidate in folders) candidate.id: candidate,
    };
    final currentParentId = _normalizeParentId(folder.parentId);

    final targets = folders
        .where((candidate) {
          if (candidate.id == folder.id) {
            return false;
          }
          if (candidate.id == currentParentId) {
            return false;
          }
          return !_isFolderDescendant(
            folderId: candidate.id,
            ancestorId: folder.id,
            foldersById: foldersById,
          );
        })
        .toList(growable: false);

    return targets
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  bool _isFolderDescendant({
    required String folderId,
    required String ancestorId,
    required Map<String, Folder> foldersById,
  }) {
    var cursor = _normalizeParentId(foldersById[folderId]?.parentId);
    final visited = <String>{};
    while (cursor != null && visited.add(cursor)) {
      if (cursor == ancestorId) {
        return true;
      }
      cursor = _normalizeParentId(foldersById[cursor]?.parentId);
    }
    return false;
  }

  Future<void> _moveFolder(Folder folder, List<Folder> folders) async {
    final target = await _showFolderMoveSheet(folder, folders);
    if (!mounted || target == null) return;

    final nextParentId = target.parentId;
    if (_normalizeParentId(folder.parentId) == nextParentId) {
      return;
    }

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      await api.updateFolderParent(folder.id, nextParentId);
      if (!mounted) return;

      ConduitHaptics.selectionClick();
      ref
          .read(foldersProvider.notifier)
          .updateFolder(
            folder.id,
            (current) => current.copyWith(
              parentId: nextParentId,
              updatedAt: DateTime.now(),
            ),
          );
      if (nextParentId != null) {
        _setFolderExpanded(nextParentId, true);
      }
      refreshConversationsCache(ref, includeFolders: true);
    } catch (e, stackTrace) {
      if (!mounted) return;
      DebugLogger.error(
        'move-folder-failed',
        scope: 'drawer',
        error: e,
        stackTrace: stackTrace,
      );
      await _showDrawerError('Failed to move folder');
    }
  }

  Future<_FolderMoveTarget?> _showFolderMoveSheet(
    Folder folder,
    List<Folder> folders,
  ) {
    final currentParentId = _normalizeParentId(folder.parentId);
    final moveTargets = _folderMoveTargets(folder, folders);

    return ThemedSheets.showSurface<_FolderMoveTarget>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = sheetContext.conduitTheme;
        final maxListHeight = MediaQuery.sizeOf(sheetContext).height * 0.62;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Move folder',
              style: AppTypography.headlineSmallStyle.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: Spacing.md),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: ListView(
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.zero,
                children: [
                  if (currentParentId != null)
                    _FolderMoveTargetTile(
                      icon: Platform.isIOS
                          ? CupertinoIcons.folder_badge_minus
                          : Icons.folder_off_outlined,
                      label: 'Top level',
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(const _FolderMoveTarget(parentId: null)),
                    ),
                  for (final target in moveTargets)
                    _FolderMoveTargetTile(
                      icon: Platform.isIOS
                          ? CupertinoIcons.folder
                          : Icons.folder_outlined,
                      label: target.name,
                      onTap: () => Navigator.of(
                        sheetContext,
                      ).pop(_FolderMoveTarget(parentId: target.id)),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
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
      ConduitHaptics.selectionClick();
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
      ConduitHaptics.mediumImpact();
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

  Widget _buildTileFor(
    dynamic conv, {
    List<bool> ancestorHasMoreSiblings = const <bool>[],
    bool showHierarchyBranch = false,
    bool hasMoreSiblings = false,
    bool foldersEnabled = false,
    List<Folder> folders = const <Folder>[],
  }) {
    // Only rebuild this tile when its own selected state changes.
    final isActive = ref.watch(
      activeConversationProvider.select((c) => c?.id == conv.id),
    );
    final title = conv.title?.isEmpty == true ? 'Chat' : (conv.title ?? 'Chat');
    final bool isLoadingSelected =
        (_pendingConversationId == conv.id) &&
        (ref.watch(chat.isLoadingConversationProvider) == true);
    final bool isPinned = conv.pinned == true;

    final tileWidget = ConversationTile(
      key: ValueKey<String>('drawer-chat-${conv.id}'),
      title: title,
      pinned: isPinned,
      selected: isActive,
      isLoading: isLoadingSelected,
      onTap: _isLoadingConversation
          ? null
          : () => _selectConversation(context, conv.id),
    );

    final wrappedTile = showHierarchyBranch
        ? FolderTreeHierarchyNode(
            key: ValueKey<String>('tree-guides-chat-${conv.id}'),
            ancestorHasMoreSiblings: ancestorHasMoreSiblings,
            showBranch: true,
            hasMoreSiblings: hasMoreSiblings,
            child: tileWidget,
          )
        : tileWidget;

    final tile = ConduitContextMenu(
      actions: buildConversationActionsWithFolders(
        context: context,
        ref: ref,
        conversation: conv,
        foldersEnabled: foldersEnabled,
        folders: folders,
      ),
      child: wrappedTile,
    );

    return tile;
  }

  Widget _buildArchivedHeader(int count) {
    final theme = context.conduitTheme;
    final show = ref.watch(showArchivedProvider);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ref.read(showArchivedProvider.notifier).set(!show),
      child: Container(
        decoration: BoxDecoration(
          color: show
              ? theme.navigationSelectedBackground
              : theme.surfaceContainer,
          borderRadius: BorderRadius.circular(AppBorderRadius.small),
          border: Border.all(
            color: show
                ? theme.navigationSelected
                : theme.surfaceContainerHighest.withValues(alpha: 0.40),
            width: BorderWidth.thin,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.xs,
            ),
            child: Row(
              children: [
                Icon(
                  Platform.isIOS
                      ? CupertinoIcons.archivebox
                      : Icons.archive_rounded,
                  color: theme.iconPrimary,
                  size: IconSize.listItem,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context)!.archived,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sidebarTitleStyle.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  '$count',
                  style: AppTypography.sidebarSupportingStyle.copyWith(
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

    // Selecting a real conversation exits temporary mode
    container.read(temporaryChatEnabledProvider.notifier).set(false);

    try {
      // Mark global loading to show skeletons in chat
      container.read(chat.isLoadingConversationProvider.notifier).set(true);
      _pendingConversationId = id;

      // Immediately clear current chat to show loading skeleton in the chat view
      container.read(activeConversationProvider.notifier).clear();
      container.read(chat.chatMessagesProvider.notifier).clearMessages();

      // Clear any pending folder selection when selecting an existing conversation
      container.read(pendingFolderIdProvider.notifier).clear();

      // Navigate to chat route (needed when sidebar is open from
      // a non-chat page like notes editor or channel page).
      NavigationService.router.go(Routes.chat);

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
}

class _FolderMoveTarget {
  const _FolderMoveTarget({required this.parentId});

  final String? parentId;
}

class _FolderMoveTargetTile extends StatelessWidget {
  const _FolderMoveTargetTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: TouchTarget.listItem),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.sm,
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.iconPrimary, size: IconSize.listItem),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sidebarTitleStyle.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Bottom quick actions widget removed as design now shows only profile card
// Notifier classes extracted to drawer_section_notifiers.dart
// Conversation tile widgets extracted to conversation_tile.dart
// Create folder dialog extracted to create_folder_dialog.dart

// (classes removed - see drawer_section_notifiers.dart)
