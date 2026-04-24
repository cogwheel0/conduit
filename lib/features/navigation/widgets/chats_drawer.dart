import 'dart:async';
import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../chat/providers/chat_providers.dart' as chat;
import '../../chat/providers/context_attachments_provider.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/widgets/conduit_loading.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../core/models/model.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import 'conversation_tile.dart';
import 'create_folder_dialog.dart';
import 'drawer_section_notifiers.dart';

/// Defines the section types that can be collapsed in the chats drawer
enum _SectionType { pinned, recent }

class ChatsDrawer extends ConsumerStatefulWidget {
  const ChatsDrawer({super.key});

  @override
  ConsumerState<ChatsDrawer> createState() => _ChatsDrawerState();
}

class _ChatsDrawerState extends ConsumerState<ChatsDrawer>
    with AutomaticKeepAliveClientMixin {
  static const String _conversationDragType = 'conversation';
  static const String _folderDragType = 'folder';
  static const String _rootDropTargetId = '__ROOT__';

  @override
  bool get wantKeepAlive => true;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'drawer_search');
  final ScrollController _listController = ScrollController();
  Timer? _debounce;
  String _query = '';
  bool _isLoadingConversation = false;
  String? _pendingConversationId;
  String? _dragHoverFolderId;
  bool _isDragging = false;
  bool _canDropToRoot = false;
  bool _isLoadingMoreConversations = false;

  @override
  void initState() {
    super.initState();
    _listController.addListener(_onListScrolled);
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
    if (!notifier.hasMoreRegularChats || notifier.isLoadingMoreRegularChats) {
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
    double leadingIndent = 0,
    Map<String, Model> modelsById = const <String, Model>{},
  }) {
    final sliver = SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) => _buildTileFor(
          items[index],
          leadingIndent: leadingIndent,
          modelsById: modelsById,
        ),
        childCount: items.length,
      ),
    );

    if (leadingIndent == 0) {
      return sliver;
    }

    return SliverPadding(
      padding: EdgeInsets.only(left: leadingIndent),
      sliver: sliver,
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

  double _folderIndent(int depth) => Spacing.md + (depth * Spacing.md);

  void _setFolderExpanded(String folderId, bool isExpanded) {
    final current = {...ref.read(expandedFoldersProvider)};
    current[folderId] = isExpanded;
    ref.read(expandedFoldersProvider.notifier).set(current);
  }

  Map<String, Object?> _buildConversationDragPayload(
    dynamic conversation,
    String title,
  ) {
    return {
      'type': _conversationDragType,
      'id': _conversationId(conversation),
      'title': title,
      'folderId': conversation.folderId,
    };
  }

  Map<String, Object?> _buildFolderDragPayload(Folder folder) {
    return {
      'type': _folderDragType,
      'id': folder.id,
      'parentId': folder.parentId,
    };
  }

  String? _dragPayloadType(Object? localData) {
    if (localData is! Map) return null;
    final type = localData['type'];
    return type is String && type.isNotEmpty ? type : null;
  }

  String? _dragPayloadId(Object? localData) {
    if (localData is! Map) return null;
    final id = localData['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  bool _isFolderPayload(Object? localData) =>
      _dragPayloadType(localData) == _folderDragType;

  String? _normalizeParentId(String? parentId) {
    if (parentId == null || parentId.isEmpty) {
      return null;
    }
    return parentId;
  }

  bool _canReparentFolder({
    required String folderId,
    required String? nextParentId,
    required Map<String, Folder> foldersById,
  }) {
    final folder = foldersById[folderId];
    if (folder == null) {
      return false;
    }

    final normalizedCurrentParentId = _normalizeParentId(folder.parentId);
    final normalizedNextParentId = _normalizeParentId(nextParentId);

    if (normalizedCurrentParentId == normalizedNextParentId) {
      return false;
    }
    if (normalizedNextParentId == folderId) {
      return false;
    }

    var cursor = normalizedNextParentId;
    final visitedFolderIds = <String>{};
    while (cursor != null && visitedFolderIds.add(cursor)) {
      if (cursor == folderId) {
        return false;
      }
      cursor = _normalizeParentId(foldersById[cursor]?.parentId);
    }

    return true;
  }

  DropOperation _folderDropOperationFor({
    required Object? localData,
    required String? targetParentId,
    required Map<String, Folder> foldersById,
  }) {
    final dragId = _dragPayloadId(localData);
    if (dragId == null) {
      return DropOperation.none;
    }

    if (_isFolderPayload(localData)) {
      final canDrop = _canReparentFolder(
        folderId: dragId,
        nextParentId: targetParentId,
        foldersById: foldersById,
      );
      return canDrop ? DropOperation.move : DropOperation.none;
    }

    return DropOperation.move;
  }

  List<Widget> _buildFolderSectionSlivers({
    required List<Folder> folders,
    required Map<String, Model> modelsById,
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

    final cachedItemCounts = <String, int>{};
    final rootFolders = childFoldersByParentId[null] ?? const <Folder>[];
    final slivers = <Widget>[];

    for (final folder in rootFolders) {
      slivers.addAll(
        _buildFolderBranchSlivers(
          folder: folder,
          foldersById: foldersById,
          childFoldersByParentId: childFoldersByParentId,
          cachedItemCounts: cachedItemCounts,
          modelsById: modelsById,
          folderConversationFallbacks: folderConversationFallbacks,
          fetchFromServerForFolders: fetchFromServerForFolders,
          depth: 0,
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildFolderBranchSlivers({
    required Folder folder,
    required Map<String, Folder> foldersById,
    required Map<String?, List<Folder>> childFoldersByParentId,
    required Map<String, int> cachedItemCounts,
    required Map<String, Model> modelsById,
    Map<String, List<dynamic>> folderConversationFallbacks =
        const <String, List<dynamic>>{},
    bool fetchFromServerForFolders = true,
    required int depth,
    Set<String> visitedFolderIds = const <String>{},
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
    final conversations = folderConversationsAsync?.maybeWhen(
          data: (loadedConversations) => loadedConversations.isNotEmpty
              ? loadedConversations
              : placeholderConversations,
          orElse: () => placeholderConversations,
        ) ??
        placeholderConversations;
    final isFolderLoading =
        fetchFromServerForFolders && (folderConversationsAsync?.isLoading == true);
    final itemCount = _folderTreeItemCount(
      folder: folder,
      childFoldersByParentId: childFoldersByParentId,
      cachedItemCounts: cachedItemCounts,
      folderConversationFallbacks: folderConversationFallbacks,
      fetchFromServerForFolders: fetchFromServerForFolders,
      visitedFolderIds: visitedFolderIds,
    );
    final slivers = <Widget>[
      SliverPadding(
        padding: EdgeInsets.only(left: _folderIndent(depth), right: Spacing.md),
        sliver: SliverToBoxAdapter(
          child: _buildFolderHeader(
            folder: folder,
            itemCount: itemCount,
            foldersById: foldersById,
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

    for (final childFolder in childFolders) {
      slivers.addAll(
        _buildFolderBranchSlivers(
          folder: childFolder,
          foldersById: foldersById,
          childFoldersByParentId: childFoldersByParentId,
          cachedItemCounts: cachedItemCounts,
          modelsById: modelsById,
          folderConversationFallbacks: folderConversationFallbacks,
          fetchFromServerForFolders: fetchFromServerForFolders,
          depth: depth + 1,
          visitedFolderIds: nextVisitedFolderIds,
        ),
      );
    }

    if (isFolderLoading && conversations.isEmpty) {
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.only(left: _folderIndent(depth + 1)),
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
      );
    } else if (conversations.isNotEmpty) {
      slivers.add(
        _conversationsSliver(
          conversations,
          leadingIndent: _folderIndent(depth + 1),
          modelsById: modelsById,
        ),
      );
      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: Spacing.sm)),
      );
    }

    return slivers;
  }

  int _folderTreeItemCount({
    required Folder folder,
    required Map<String?, List<Folder>> childFoldersByParentId,
    required Map<String, int> cachedItemCounts,
    Map<String, List<dynamic>> folderConversationFallbacks =
        const <String, List<dynamic>>{},
    bool fetchFromServerForFolders = true,
    Set<String> visitedFolderIds = const <String>{},
  }) {
    final cachedCount = cachedItemCounts[folder.id];
    if (cachedCount != null) {
      return cachedCount;
    }
    if (visitedFolderIds.contains(folder.id)) {
      return 0;
    }

    final nextVisitedFolderIds = {...visitedFolderIds, folder.id};
    final childFolders = childFoldersByParentId[folder.id] ?? const <Folder>[];
    final directConversationCount =
        !fetchFromServerForFolders
        ? (folderConversationFallbacks[folder.id]?.length ?? 0)
        : (folderConversationFallbacks[folder.id]?.length ??
              folder.conversationIds.length);

    final descendantCount = childFolders.fold<int>(
      0,
      (count, childFolder) =>
          count +
          1 +
          _folderTreeItemCount(
            folder: childFolder,
            childFoldersByParentId: childFoldersByParentId,
            cachedItemCounts: cachedItemCounts,
            folderConversationFallbacks: folderConversationFallbacks,
            fetchFromServerForFolders: fetchFromServerForFolders,
            visitedFolderIds: nextVisitedFolderIds,
          ),
    );

    final totalCount = directConversationCount + descendantCount;
    cachedItemCounts[folder.id] = totalCount;
    return totalCount;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final backgroundColor = context.conduitTheme.surfaceBackground;

    return Stack(
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
                  backgroundColor,
                  backgroundColor.withValues(alpha: 0.85),
                  backgroundColor.withValues(alpha: 0.0),
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
      ],
    );
  }

  Widget _buildFloatingSearchField(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ConduitGlassSearchField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            hintText: AppLocalizations.of(context)!.searchConversations,
            onChanged: (_) => _onSearchChanged(),
            query: _query,
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
              _searchFocusNode.unfocus();
            },
          ),
        ),
        const SizedBox(width: 8),
        FloatingAppBarIconButton(
          icon: UiUtils.newChatIcon,
          onTap: _startNewChat,
        ),
      ],
    );
  }

  void _startNewChat() {
    ConduitHaptics.selectionClick();
    ref.read(chat.chatMessagesProvider.notifier).clearMessages();
    ref.read(activeConversationProvider.notifier).clear();
    ref.read(contextAttachmentsProvider.notifier).clear();
    chat.restoreDefaultModel(ref);

    NavigationService.router.go(Routes.chat);

    if (mounted) {
      final isTablet = MediaQuery.of(context).size.shortestSide >= 600;
      if (!isTablet) {
        ResponsiveDrawerLayout.of(context)?.close();
      }
    }

    final settings = ref.read(appSettingsProvider);
    ref
        .read(temporaryChatEnabledProvider.notifier)
        .set(settings.temporaryChatByDefault);
  }

  Widget _buildConversationList(BuildContext context) {
    final theme = context.conduitTheme;

    if (_query.isEmpty) {
      final conversationsAsync = ref.watch(conversationsProvider);
      return conversationsAsync.when(
        data: (items) {
          final list = items;
          final conversationsNotifier = ref.read(conversationsProvider.notifier);
          final hasMoreRegularChats =
              conversationsNotifier.hasMoreRegularChats ||
              _isLoadingMoreConversations;
          // Build a models map once for this build.
          final modelsAsync = ref.watch(modelsProvider);
          final Map<String, Model> modelsById = modelsAsync.maybeWhen(
            data: (models) => {
              for (final m in models)
                if (m.id.isNotEmpty) m.id: m,
            },
            orElse: () => const <String, Model>{},
          );
          final foldersEnabled = ref.watch(foldersFeatureEnabledProvider);
          final hasVisibleFolders = ref
              .watch(foldersProvider)
              .maybeWhen(
                data: (folders) => foldersEnabled && folders.isNotEmpty,
                orElse: () => false,
              );

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
              if (_isDragging && _canDropToRoot) ...[
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                  sliver: SliverToBoxAdapter(child: _buildUnfileDropTarget()),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.sm)),
              ],
              ...ref
                  .watch(foldersProvider)
                  .when(
                    data: (folders) => _buildFolderSectionSlivers(
                      folders: folders,
                      folderConversationFallbacks: folderConversationFallbacks,
                      modelsById: modelsById,
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
                    regular.length,
                    sectionType: _SectionType.recent,
                    showCountBadge: false,
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
              if (ref.watch(showArchivedProvider)) ...[
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
                _conversationsSliver(archived, modelsById: modelsById),
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

          if (_isDragging && _canDropToRoot) {
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
                data: (folders) => _buildFolderSectionSlivers(
                  folders: folders,
                  folderConversationFallbacks: folderSearchResults,
                  fetchFromServerForFolders: false,
                  modelsById: modelsById,
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
                  regular.length,
                  sectionType: _SectionType.recent,
                  showCountBadge: false,
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
          if (ref.watch(showArchivedProvider)) {
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
    bool showCountBadge = true,
  }) {
    final sidebarTheme = context.sidebarTheme;

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
        if (showCountBadge) ...[
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
              style: AppTypography.sidebarBadgeStyle.copyWith(
                color: sidebarTheme.foreground.withValues(alpha: 0.8),
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
    final isExpanded = ref.watch(showFoldersProvider);

    return Row(
      children: [
        InkWell(
          onTap: () => ref.read(showFoldersProvider.notifier).toggle(),
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
          onPressed: () =>
              CreateFolderDialog.show(context, ref, onError: _showDrawerError),
        ),
      ],
    );
  }

  Widget _buildFolderHeader({
    required Folder folder,
    required int itemCount,
    required Map<String, Folder> foldersById,
  }) {
    final folderId = folder.id;
    final name = folder.name;
    final theme = context.conduitTheme;
    final failedToMoveChat = AppLocalizations.of(context)!.failedToMoveChat;
    final expandedMap = ref.watch(expandedFoldersProvider);
    final isExpanded = expandedMap[folderId] ?? folder.isExpanded;
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
        final operation = _folderDropOperationFor(
          localData: event.session.items.first.localData,
          targetParentId: folderId,
          foldersById: foldersById,
        );
        setState(() {
          _dragHoverFolderId = operation == DropOperation.move
              ? folderId
              : null;
        });
        return operation;
      },
      onDropEnter: (event) {
        final operation = _folderDropOperationFor(
          localData: event.session.items.first.localData,
          targetParentId: folderId,
          foldersById: foldersById,
        );
        if (operation == DropOperation.move) {
          setState(() => _dragHoverFolderId = folderId);
        }
      },
      onDropLeave: (_) {
        if (_dragHoverFolderId == folderId) {
          setState(() => _dragHoverFolderId = null);
        }
      },
      onPerformDrop: (event) async {
        final localData = event.session.items.first.localData;
        final operation = _folderDropOperationFor(
          localData: localData,
          targetParentId: folderId,
          foldersById: foldersById,
        );
        if (operation != DropOperation.move) {
          return;
        }

        setState(() {
          _dragHoverFolderId = null;
          _isDragging = false;
          _canDropToRoot = false;
        });

        final dragId = _dragPayloadId(localData);
        if (dragId == null) {
          return;
        }

        try {
          final api = ref.read(apiServiceProvider);
          if (api == null) {
            throw Exception('No API service');
          }

          if (_isFolderPayload(localData)) {
            await api.updateFolderParent(dragId, folderId);
            ConduitHaptics.selectionClick();
            ref
                .read(foldersProvider.notifier)
                .updateFolder(
                  dragId,
                  (draggedFolder) => draggedFolder.copyWith(
                    parentId: folderId,
                    updatedAt: DateTime.now(),
                  ),
                );
            _setFolderExpanded(folderId, true);
          } else {
            await api.moveConversationToFolder(dragId, folderId);
            ConduitHaptics.selectionClick();
            ref
                .read(conversationsProvider.notifier)
                .updateConversation(
                  dragId,
                  (conversation) => conversation.copyWith(
                    folderId: folderId,
                    updatedAt: DateTime.now(),
                  ),
                );
            _setFolderExpanded(folderId, true);
          }

          refreshConversationsCache(ref, includeFolders: true);
        } catch (e, stackTrace) {
          final logLabel = _isFolderPayload(localData)
              ? 'move-folder-failed'
              : 'move-conversation-failed';
          final errorMessage = _isFolderPayload(localData)
              ? 'Failed to move folder'
              : failedToMoveChat;

          DebugLogger.error(
            logLabel,
            scope: 'drawer',
            error: e,
            stackTrace: stackTrace,
          );
          if (mounted) {
            await _showDrawerError(errorMessage);
          }
        }
      },
      child: DragItemWidget(
        allowedOperations: () => [DropOperation.move],
        canAddItemToExistingSession: true,
        dragItemProvider: (request) async {
          ConduitHaptics.lightImpact();
          final hasParent = _normalizeParentId(folder.parentId) != null;
          setState(() {
            _isDragging = true;
            _canDropToRoot = hasParent;
          });

          void onDragCompleted() {
            if (mounted) {
              setState(() {
                _dragHoverFolderId = null;
                _isDragging = false;
                _canDropToRoot = false;
              });
            }
            request.session.dragCompleted.removeListener(onDragCompleted);
          }

          request.session.dragCompleted.addListener(onDragCompleted);

          return DragItem(localData: _buildFolderDragPayload(folder));
        },
        dragBuilder: (context, child) {
          return Opacity(
            opacity: 0.92,
            child: _FolderDragFeedback(name: name, theme: theme),
          );
        },
        child: DraggableWidget(
          child: ConduitContextMenu(
            actions: _buildFolderActions(folder),
            child: Material(
              color: isHover ? hoverColor : baseColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
                side: BorderSide(color: borderColor, width: BorderWidth.thin),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
                onTap: () => _setFolderExpanded(folderId, !isExpanded),
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
                                      style: AppTypography.sidebarTitleStyle
                                          .copyWith(
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
                                      color: context.sidebarTheme.accent
                                          .withValues(alpha: 0.7),
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
                                      '$itemCount',
                                      style: AppTypography.sidebarBadgeStyle
                                          .copyWith(
                                            color: context
                                                .sidebarTheme
                                                .foreground
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
                                  ConduitHaptics.selectionClick();
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
        ),
      ),
    );
  }

  List<Conversation> _placeholderConversationsForFolder(Folder folder) {
    return folder.conversationIds
        .map((conversationId) => _placeholderConversation(conversationId, folder.id))
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
        AdaptiveButton(
          onPressed: () => Navigator.of(context).pop(),
          label: l10n.ok,
          style: AdaptiveButtonStyle.plain,
        ),
      ],
    );
  }

  List<ConduitContextMenuAction> _buildFolderActions(Folder folder) {
    final l10n = AppLocalizations.of(context)!;
    final folderId = folder.id;
    final folderName = folder.name;

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

    // Reset temporary chat state based on user preference
    final settings = ref.read(appSettingsProvider);
    ref
        .read(temporaryChatEnabledProvider.notifier)
        .set(settings.temporaryChatByDefault);
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

  Widget _buildUnfileDropTarget() {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final folders = ref
        .watch(foldersProvider)
        .maybeWhen(data: (folders) => folders, orElse: () => const <Folder>[]);
    final foldersById = <String, Folder>{
      for (final folder in folders) folder.id: folder,
    };
    final isHover = _dragHoverFolderId == _rootDropTargetId;
    return DropRegion(
      formats: const [], // Local data only
      onDropOver: (event) {
        final operation = _folderDropOperationFor(
          localData: event.session.items.first.localData,
          targetParentId: null,
          foldersById: foldersById,
        );
        setState(() {
          _dragHoverFolderId = operation == DropOperation.move
              ? _rootDropTargetId
              : null;
        });
        return operation;
      },
      onDropEnter: (event) {
        final operation = _folderDropOperationFor(
          localData: event.session.items.first.localData,
          targetParentId: null,
          foldersById: foldersById,
        );
        if (operation == DropOperation.move) {
          setState(() => _dragHoverFolderId = _rootDropTargetId);
        }
      },
      onDropLeave: (_) => setState(() => _dragHoverFolderId = null),
      onPerformDrop: (event) async {
        final localData = event.session.items.first.localData;
        final operation = _folderDropOperationFor(
          localData: localData,
          targetParentId: null,
          foldersById: foldersById,
        );
        if (operation != DropOperation.move) {
          return;
        }

        setState(() {
          _dragHoverFolderId = null;
          _isDragging = false;
          _canDropToRoot = false;
        });

        final dragId = _dragPayloadId(localData);
        if (dragId == null) {
          return;
        }

        try {
          final api = ref.read(apiServiceProvider);
          if (api == null) {
            throw Exception('No API service');
          }

          if (_isFolderPayload(localData)) {
            await api.updateFolderParent(dragId, null);
            ConduitHaptics.selectionClick();
            ref
                .read(foldersProvider.notifier)
                .updateFolder(
                  dragId,
                  (folder) => folder.copyWith(
                    parentId: null,
                    updatedAt: DateTime.now(),
                  ),
                );
          } else {
            await api.moveConversationToFolder(dragId, null);
            ConduitHaptics.selectionClick();
            ref
                .read(conversationsProvider.notifier)
                .updateConversation(
                  dragId,
                  (conversation) => conversation.copyWith(
                    folderId: null,
                    updatedAt: DateTime.now(),
                  ),
                );
          }

          refreshConversationsCache(ref, includeFolders: true);
        } catch (e, stackTrace) {
          final logLabel = _isFolderPayload(localData)
              ? 'unstack-folder-failed'
              : 'unfile-conversation-failed';
          final errorMessage = _isFolderPayload(localData)
              ? 'Failed to move folder'
              : l10n.failedToMoveChat;
          DebugLogger.error(
            logLabel,
            scope: 'drawer',
            error: e,
            stackTrace: stackTrace,
          );
          if (mounted) {
            await _showDrawerError(errorMessage);
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
                'Drop here to move to top level',
                style: AppTypography.sidebarSupportingStyle.copyWith(
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
    double leadingIndent = 0,
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

    final tileWidget = ConversationTile(
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
        padding: EdgeInsets.only(left: leadingIndent),
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
          ConduitHaptics.lightImpact();
          final hasFolder =
              (conv.folderId != null && (conv.folderId as String).isNotEmpty);
          setState(() {
            _isDragging = true;
            _canDropToRoot = hasFolder;
          });

          // Listen for drag completion to reset state
          void onDragCompleted() {
            if (mounted) {
              setState(() {
                _dragHoverFolderId = null;
                _isDragging = false;
                _canDropToRoot = false;
              });
            }
            request.session.dragCompleted.removeListener(onDragCompleted);
          }

          request.session.dragCompleted.addListener(onDragCompleted);

          // Provide drag data with conversation info as serializable Map
          final item = DragItem(
            localData: _buildConversationDragPayload(conv, title),
          );
          return item;
        },
        dragBuilder: (context, child) {
          // Custom drag preview
          return Opacity(
            opacity: 0.9,
            child: ConversationDragFeedback(
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
    final show = ref.watch(showArchivedProvider);
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
        onTap: () => ref.read(showArchivedProvider.notifier).set(!show),
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

class _FolderDragFeedback extends StatelessWidget {
  const _FolderDragFeedback({required this.name, required this.theme});

  final String name;
  final ConduitThemeExtension theme;

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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Platform.isIOS ? CupertinoIcons.folder : Icons.folder,
              color: theme.iconPrimary,
              size: IconSize.listItem,
            ),
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.sidebarTitleStyle.copyWith(
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
}

// Bottom quick actions widget removed as design now shows only profile card
// Notifier classes extracted to drawer_section_notifiers.dart
// Conversation tile widgets extracted to conversation_tile.dart
// Create folder dialog extracted to create_folder_dialog.dart

// (classes removed - see drawer_section_notifiers.dart)
