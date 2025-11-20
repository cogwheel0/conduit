import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../chat/providers/chat_providers.dart' as chat;
// import '../../files/views/files_page.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/services/navigation_service.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import 'package:conduit/l10n/app_localizations.dart';
import '../../../core/utils/user_display_name.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../auth/providers/unified_auth_providers.dart';
import '../../../core/utils/user_avatar_utils.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../../shared/widgets/model_avatar.dart';
import '../../../shared/widgets/responsive_drawer_layout.dart';
import '../../../core/models/model.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/folder.dart';
import '../../../core/utils/folder_hierarchy.dart';

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
    if (Platform.isIOS) {
      final scroll = CustomScrollView(
        key: const PageStorageKey<String>('chats_drawer_scroll'),
        controller: _listController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          CupertinoSliverRefreshControl(onRefresh: _refreshChats),
          ...slivers,
        ],
      );
      return CupertinoScrollbar(controller: _listController, child: scroll);
    }

    final scroll = CustomScrollView(
      key: const PageStorageKey<String>('chats_drawer_scroll'),
      controller: _listController,
      physics: const AlwaysScrollableScrollPhysics(),
      cacheExtent: 800,
      slivers: slivers,
    );
    return RefreshIndicator(
      onRefresh: _refreshChats,
      child: Scrollbar(controller: _listController, child: scroll),
    );
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

  // Payload for drag-and-drop of conversations
  // Kept local to this widget
  // ignore: unused_element
  static _DragConversationData _dragData(String id, String title) =>
      _DragConversationData(id: id, title: title);

  @override
  Widget build(BuildContext context) {
    // Bottom section now only shows navigation actions
    final sidebarTheme = context.sidebarTheme;

    return Container(
      decoration: BoxDecoration(
        color: sidebarTheme.background,
        border: Border(right: BorderSide(color: sidebarTheme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.inputPadding,
              Spacing.sm,
              Spacing.md,
              Spacing.sm,
            ),
            child: Row(children: [Expanded(child: _buildSearchField(context))]),
          ),
          Expanded(child: _buildConversationList(context)),
          Divider(
            height: 1,
            color: sidebarTheme.border.withValues(alpha: 0.28),
          ),
          _buildBottomSection(context),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final sidebarTheme = context.sidebarTheme;
    return Material(
      color: Colors.transparent,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: (_) => _onSearchChanged(),
        style: AppTypography.standard.copyWith(color: sidebarTheme.foreground),
        decoration: InputDecoration(
          isDense: true,
          hintText: AppLocalizations.of(context)!.searchConversations,
          hintStyle: AppTypography.standard.copyWith(
            color: sidebarTheme.foreground.withValues(alpha: 0.6),
          ),
          prefixIcon: Icon(
            Platform.isIOS ? CupertinoIcons.search : Icons.search,
            color: sidebarTheme.foreground.withValues(alpha: 0.7),
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
                    color: sidebarTheme.foreground.withValues(alpha: 0.7),
                    size: IconSize.input,
                  ),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(
            minWidth: TouchTarget.minimum,
            minHeight: TouchTarget.minimum,
          ),
          filled: true,
          fillColor: sidebarTheme.accent.withValues(alpha: 0.9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            borderSide: BorderSide(
              color: sidebarTheme.border.withValues(alpha: 0.28),
              width: BorderWidth.thin,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            borderSide: BorderSide(
              color: sidebarTheme.ring.withValues(alpha: 0.6),
              width: BorderWidth.thin,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.xs,
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

          final slivers = <Widget>[
            if (pinned.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    AppLocalizations.of(context)!.pinned,
                    pinned.length,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
              _conversationsSliver(pinned, modelsById: modelsById),
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
            ],

            // Folders section (shown even if empty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              sliver: SliverToBoxAdapter(child: _buildFoldersSectionHeader()),
            ),
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

                    // Build folder hierarchy
                    final hierarchy = FolderHierarchy(folders);

                    final out = <Widget>[];

                    // Recursively build folder widgets
                    void buildFolderWidgets(
                      List<FolderNode> nodes,
                      int depth,
                    ) {
                      for (final node in nodes) {
                        final folder = node.folder;
                        final existing =
                            grouped[folder.id] ?? const <dynamic>[];
                        final convs = _resolveFolderConversations(
                          folder,
                          existing,
                        );
                        final isExpanded =
                            expandedMap[folder.id] ?? folder.isExpanded;
                        final hasItems = convs.isNotEmpty;
                        final hasChildren = node.children.isNotEmpty;

                        // Count both conversations and subfolders
                        final totalCount = convs.length + node.children.length;

                        // Add folder header with proper indentation
                        out.add(
                          SliverPadding(
                            padding: EdgeInsets.only(
                              left: Spacing.md + (depth * Spacing.lg),
                              right: Spacing.md,
                            ),
                            sliver: SliverToBoxAdapter(
                              child: _buildFolderHeader(
                                folder.id,
                                folder.name,
                                totalCount,
                                defaultExpanded: folder.isExpanded,
                                depth: depth,
                                hasChildren: hasChildren,
                              ),
                            ),
                          ),
                        );

                        // If expanded, show conversations
                        if (isExpanded && hasItems) {
                          out.add(
                            const SliverToBoxAdapter(
                              child: SizedBox(height: Spacing.xs),
                            ),
                          );
                          out.add(
                            SliverPadding(
                              padding: EdgeInsets.only(
                                left: depth * Spacing.lg,
                              ),
                              sliver: _conversationsSliver(
                                convs,
                                inFolder: true,
                                modelsById: modelsById,
                              ),
                            ),
                          );
                          out.add(
                            const SliverToBoxAdapter(
                              child: SizedBox(height: Spacing.xs),
                            ),
                          );
                        }

                        // If expanded and has children, show nested folders
                        if (isExpanded && hasChildren) {
                          buildFolderWidgets(node.children, depth + 1);
                        }

                        out.add(
                          const SliverToBoxAdapter(
                            child: SizedBox(height: Spacing.xs),
                          ),
                        );
                      }
                    }

                    // Start building from root nodes
                    buildFolderWidgets(hierarchy.rootNodes, 0);

                    return out.isEmpty
                        ? <Widget>[
                            const SliverToBoxAdapter(child: SizedBox.shrink()),
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
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),

            if (regular.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                sliver: SliverToBoxAdapter(
                  child: _buildSectionHeader(
                    AppLocalizations.of(context)!.recent,
                    regular.length,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
              _conversationsSliver(regular, modelsById: modelsById),
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
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
            _conversationsSliver(pinned, modelsById: modelsById),
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
          ]);
        }

        slivers.addAll([
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            sliver: SliverToBoxAdapter(child: _buildFoldersSectionHeader()),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
        ]);

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

                // Build folder hierarchy
                final hierarchy = FolderHierarchy(folders);
                final out = <Widget>[];

                // Recursively build folder widgets
                void buildFolderWidgets(List<FolderNode> nodes, int depth) {
                  for (final node in nodes) {
                    final folder = node.folder;
                    final existing = grouped[folder.id] ?? const <dynamic>[];
                    final convs = _resolveFolderConversations(folder, existing);
                    final isExpanded =
                        expandedMap[folder.id] ?? folder.isExpanded;
                    final hasItems = convs.isNotEmpty;
                    final hasChildren = node.children.isNotEmpty;

                    // Count both conversations and subfolders
                    final totalCount = convs.length + node.children.length;

                    out.add(
                      SliverPadding(
                        padding: EdgeInsets.only(
                          left: Spacing.md + (depth * Spacing.lg),
                          right: Spacing.md,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: _buildFolderHeader(
                            folder.id,
                            folder.name,
                            totalCount,
                            defaultExpanded: folder.isExpanded,
                            depth: depth,
                            hasChildren: hasChildren,
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
                        SliverPadding(
                          padding: EdgeInsets.only(left: depth * Spacing.lg),
                          sliver: _conversationsSliver(
                            convs,
                            inFolder: true,
                            modelsById: modelsById,
                          ),
                        ),
                      );
                      out.add(
                        const SliverToBoxAdapter(
                          child: SizedBox(height: Spacing.sm),
                        ),
                      );
                    }

                    // If expanded and has children, show nested folders
                    if (isExpanded && hasChildren) {
                      buildFolderWidgets(node.children, depth + 1);
                    }
                  }
                }

                // Start building from root nodes
                buildFolderWidgets(hierarchy.rootNodes, 0);

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

        if (regular.isNotEmpty) {
          slivers.addAll([
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.md)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              sliver: SliverToBoxAdapter(
                child: _buildSectionHeader(
                  AppLocalizations.of(context)!.recent,
                  regular.length,
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: Spacing.xs)),
            _conversationsSliver(regular, modelsById: modelsById),
          ]);
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

  Widget _buildSectionHeader(String title, int count) {
    final sidebarTheme = context.sidebarTheme;
    return Row(
      children: [
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
  }

  /// Header for the Folders section with a create button on the right
  Widget _buildFoldersSectionHeader() {
    final theme = context.conduitTheme;
    return Row(
      children: [
        Text(
          AppLocalizations.of(context)!.folders,
          style: AppTypography.labelStyle.copyWith(
            color: theme.textSecondary,
            decoration: TextDecoration.none,
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

  Future<void> _promptCreateSubfolder(
    BuildContext context,
    String parentId,
  ) async {
    final name = await ThemedDialogs.promptTextInput(
      context,
      title: AppLocalizations.of(context)!.newSubfolder,
      hintText: AppLocalizations.of(context)!.folderName,
      confirmText: AppLocalizations.of(context)!.create,
      cancelText: AppLocalizations.of(context)!.cancel,
    );

    if (name == null) return;
    if (name.isEmpty) return;
    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      final created = await api.createFolder(name: name, parentId: parentId);
      final folder = Folder.fromJson(Map<String, dynamic>.from(created));
      HapticFeedback.lightImpact();
      ref.read(foldersProvider.notifier).upsertFolder(folder);
      refreshConversationsCache(ref, includeFolders: true);

      // Automatically expand the parent folder to show the new subfolder
      final expandedMap = {...ref.read(_expandedFoldersProvider)};
      expandedMap[parentId] = true;
      ref.read(_expandedFoldersProvider.notifier).set(expandedMap);
    } catch (e, stackTrace) {
      if (!mounted) return;
      DebugLogger.error(
        'create-subfolder-failed',
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
    int depth = 0,
    bool hasChildren = false,
  }) {
    final theme = context.conduitTheme;
    final expandedMap = ref.watch(_expandedFoldersProvider);
    final isExpanded = expandedMap[folderId] ?? defaultExpanded;
    final isHover = _dragHoverFolderId == folderId;

    // Build the folder header widget
    Widget buildFolderHeaderWidget({
      required bool isConversationHover,
      required bool isFolderHover,
    }) {
      final combinedHover = isConversationHover || isFolderHover;
      final baseColor = theme.surfaceContainer;
      final hoverColor = theme.buttonPrimary.withValues(alpha: 0.08);
      final borderColor = combinedHover
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

      return Material(
        color: combinedHover ? hoverColor : baseColor,
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
                  final textFit =
                      hasFiniteWidth ? FlexFit.tight : FlexFit.loose;

                  return Row(
                    mainAxisSize:
                        hasFiniteWidth ? MainAxisSize.max : MainAxisSize.min,
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
                      const SizedBox(width: Spacing.sm),
                      Text(
                        '$count',
                        style: AppTypography.standard.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Builder(
                        builder: (buttonContext) {
                          return IconButton(
                            iconSize: IconSize.sm,
                            visualDensity: const VisualDensity(
                              horizontal: -2,
                              vertical: -2,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: TouchTarget.listItem,
                              minHeight: TouchTarget.listItem,
                            ),
                            icon: Icon(
                              Platform.isIOS
                                  ? CupertinoIcons.ellipsis
                                  : Icons.more_vert_rounded,
                              color: theme.iconSecondary,
                            ),
                            onPressed: () {
                              _showFolderContextMenu(
                                buttonContext,
                                folderId,
                                name,
                              );
                            },
                            tooltip: AppLocalizations.of(context)!.more,
                          );
                        },
                      ),
                      const SizedBox(width: Spacing.xs),
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
      );
    }

    // Wrap in drag targets for both conversations and folders
    return DragTarget<_DragConversationData>(
      onWillAcceptWithDetails: (details) {
        setState(() => _dragHoverFolderId = folderId);
        return true;
      },
      onLeave: (_) {
        if (_dragHoverFolderId == folderId) {
          setState(() => _dragHoverFolderId = null);
        }
      },
      onAcceptWithDetails: (details) async {
        setState(() {
          _dragHoverFolderId = null;
          _isDragging = false;
        });
        try {
          final api = ref.read(apiServiceProvider);
          if (api == null) throw Exception('No API service');
          await api.moveConversationToFolder(details.data.id, folderId);
          HapticFeedback.selectionClick();
          ref.read(conversationsProvider.notifier).updateConversation(
                details.data.id,
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
      builder: (context, candidateConvData, rejectedConvData) {
        final isConversationHover = candidateConvData.isNotEmpty;

        // Nest another DragTarget for folders
        return DragTarget<_DragFolderData>(
          onWillAcceptWithDetails: (details) {
            // Prevent dropping a folder into itself or its descendants
            final hierarchy = FolderHierarchy(
              ref.read(foldersProvider).value ?? [],
            );
            final descendants = hierarchy.getDescendantIds(details.data.id);
            if (details.data.id == folderId ||
                descendants.contains(folderId)) {
              return false;
            }
            setState(() => _dragHoverFolderId = folderId);
            return true;
          },
          onLeave: (_) {
            if (_dragHoverFolderId == folderId) {
              setState(() => _dragHoverFolderId = null);
            }
          },
          onAcceptWithDetails: (details) async {
            setState(() {
              _dragHoverFolderId = null;
              _isDragging = false;
            });
            try {
              final api = ref.read(apiServiceProvider);
              if (api == null) throw Exception('No API service');
              await api.updateFolder(details.data.id, parentId: folderId);
              HapticFeedback.selectionClick();
              ref.read(foldersProvider.notifier).updateFolder(
                    details.data.id,
                    (folder) => folder.copyWith(
                      parentId: folderId,
                      updatedAt: DateTime.now(),
                    ),
                  );
              refreshConversationsCache(ref, includeFolders: true);

              // Automatically expand the target folder
              final expandedMap = {...ref.read(_expandedFoldersProvider)};
              expandedMap[folderId] = true;
              ref.read(_expandedFoldersProvider.notifier).set(expandedMap);
            } catch (e, stackTrace) {
              DebugLogger.error(
                'move-folder-failed',
                scope: 'drawer',
                error: e,
                stackTrace: stackTrace,
              );
              if (mounted) {
                await _showDrawerError('Failed to move folder');
              }
            }
          },
          builder: (context, candidateFolderData, rejectedFolderData) {
            final isFolderHover = candidateFolderData.isNotEmpty;

            // Make the folder header draggable
            return LongPressDraggable<_DragFolderData>(
              data: _DragFolderData(id: folderId, name: name),
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: Material(
                color: Colors.transparent,
                elevation: Elevation.low,
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
                child: Container(
                  constraints:
                      const BoxConstraints(minHeight: TouchTarget.listItem),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md,
                    vertical: Spacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppBorderRadius.small),
                    border: Border.all(
                      color: theme.surfaceContainerHighest
                          .withValues(alpha: 0.40),
                      width: BorderWidth.thin,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Platform.isIOS
                            ? CupertinoIcons.folder
                            : Icons.folder,
                        color: theme.iconPrimary,
                        size: IconSize.listItem,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Text(
                        name,
                        style: AppTypography.standard.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.5,
                child: IgnorePointer(
                  child: buildFolderHeaderWidget(
                    isConversationHover: false,
                    isFolderHover: false,
                  ),
                ),
              ),
              onDragStarted: () {
                HapticFeedback.lightImpact();
                setState(() => _isDragging = true);
              },
              onDragEnd: (_) => setState(() {
                _dragHoverFolderId = null;
                _isDragging = false;
              }),
              child: buildFolderHeaderWidget(
                isConversationHover: isConversationHover,
                isFolderHover: isFolderHover,
              ),
            );
          },
        );
      },
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
      final value = (item as dynamic).id;
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

  void _showFolderContextMenu(
    BuildContext context,
    String folderId,
    String folderName,
  ) {
    final l10n = AppLocalizations.of(context)!;

    showConduitContextMenu(
      context: context,
      actions: [
        ConduitContextMenuAction(
          cupertinoIcon: CupertinoIcons.folder_badge_plus,
          materialIcon: Icons.create_new_folder_outlined,
          label: l10n.newSubfolder,
          onBeforeClose: () => HapticFeedback.selectionClick(),
          onSelected: () async {
            await _promptCreateSubfolder(context, folderId);
          },
        ),
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
      ],
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
    return DragTarget<_DragConversationData>(
      onWillAcceptWithDetails: (details) {
        setState(() => _dragHoverFolderId = '__UNFILE__');
        return true;
      },
      onLeave: (_) => setState(() => _dragHoverFolderId = null),
      onAcceptWithDetails: (details) async {
        setState(() {
          _dragHoverFolderId = null;
          _isDragging = false;
        });
        try {
          final api = ref.read(apiServiceProvider);
          if (api == null) throw Exception('No API service');
          await api.moveConversationToFolder(details.data.id, null);
          HapticFeedback.selectionClick();
          ref
              .read(conversationsProvider.notifier)
              .updateConversation(
                details.data.id,
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
      builder: (context, candidate, rejected) {
        return AnimatedContainer(
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
        );
      },
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

    Model? model;
    final modelId = (conv.model is String && (conv.model as String).isNotEmpty)
        ? conv.model as String
        : null;
    if (modelId != null) {
      model = modelsById[modelId];
    }

    final api = ref.watch(apiServiceProvider);
    final modelIconUrl = resolveModelIconUrlForModel(api, model);

    Widget? leading;
    if (modelId != null) {
      leading = ModelAvatar(
        size: 28,
        imageUrl: modelIconUrl,
        label: model?.name ?? modelId,
      );
    }

    final tile = _ConversationTile(
      title: title,
      pinned: isPinned,
      selected: isActive,
      isLoading: isLoadingSelected,
      leading: leading,
      onTap: _isLoadingConversation
          ? null
          : () => _selectConversation(context, conv.id),
      onLongPress: null,
      onMorePressed: (buttonContext) {
        showConversationContextMenu(
          context: buttonContext,
          ref: ref,
          conversation: conv,
        );
      },
    );

    return RepaintBoundary(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: Spacing.xs,
          left: inFolder ? Spacing.md : 0,
        ),
        child: LongPressDraggable<_DragConversationData>(
          data: _DragConversationData(id: conv.id, title: title),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: _ConversationDragFeedback(
            title: title,
            pinned: isPinned,
            theme: theme,
          ),
          childWhenDragging: Opacity(
            opacity: 0.5,
            child: IgnorePointer(child: tile),
          ),
          onDragStarted: () {
            HapticFeedback.lightImpact();
            final hasFolder =
                (conv.folderId != null && (conv.folderId as String).isNotEmpty);
            setState(() {
              _isDragging = true;
              _draggingHasFolder = hasFolder;
            });
          },
          onDragEnd: (_) => setState(() {
            _dragHoverFolderId = null;
            _isDragging = false;
            _draggingHasFolder = false;
          }),
          child: tile,
        ),
      ),
    );
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

      // Close the slide drawer for faster perceived performance
      // (only on mobile; on tablet, drawer stays visible)
      if (mounted) {
        ResponsiveDrawerLayout.of(context)?.close();
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

  Widget _buildBottomSection(BuildContext context) {
    final theme = context.conduitTheme;
    final sidebarTheme = context.sidebarTheme;
    final currentUserAsync = ref.watch(currentUserProvider);
    final userFromProfile = currentUserAsync.maybeWhen(
      data: (u) => u,
      orElse: () => null,
    );
    final authUser = ref.watch(currentUserProvider2);
    final user = userFromProfile ?? authUser;
    final api = ref.watch(apiServiceProvider);

    String initialFor(String name) {
      if (name.isEmpty) return 'U';
      final ch = name.characters.first;
      return ch.toUpperCase();
    }

    final displayName = deriveUserDisplayName(user);
    final initial = initialFor(displayName);
    final avatarUrl = resolveUserAvatarUrlForUser(api, user);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.sm, 0, Spacing.sm, Spacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (user != null) ...[
            const SizedBox(height: Spacing.sm),
            Container(
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: sidebarTheme.accent.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppBorderRadius.small),
                border: Border.all(
                  color: sidebarTheme.border.withValues(alpha: 0.28),
                  width: BorderWidth.thin,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.avatar,
                      ),
                      border: Border.all(
                        color: theme.buttonPrimary.withValues(alpha: 0.25),
                        width: BorderWidth.thin,
                      ),
                    ),
                    // Hard-edge clipping is cheaper than anti-aliased clipping
                    // and sufficient for avatar squares with rounded corners.
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
                        color: sidebarTheme.foreground,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
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
                      color: sidebarTheme.foreground.withValues(alpha: 0.8),
                      size: IconSize.medium,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShowArchivedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

class _ExpandedFoldersNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => {};

  void set(Map<String, bool> value) => state = Map<String, bool>.from(value);
}

class _DragConversationData {
  final String id;
  final String title;
  const _DragConversationData({required this.id, required this.title});
}

class _DragFolderData {
  final String id;
  final String name;
  const _DragFolderData({required this.id, required this.name});
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
          onMorePressed: null,
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
  final void Function(BuildContext)? onMorePressed;
  final Widget? leading;

  const _ConversationTileContent({
    required this.title,
    required this.pinned,
    required this.selected,
    required this.isLoading,
    this.onMorePressed,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final textStyle = AppTypography.standard.copyWith(
      color: theme.textPrimary,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      height: 1.4,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasFiniteWidth = constraints.maxWidth.isFinite;
        final textFit = hasFiniteWidth ? FlexFit.tight : FlexFit.loose;

        final trailing = <Widget>[];
        if (pinned) {
          trailing.addAll([
            const SizedBox(width: Spacing.xs),
            Icon(
              Platform.isIOS ? CupertinoIcons.pin_fill : Icons.push_pin_rounded,
              color: theme.iconSecondary,
              size: IconSize.xs,
            ),
          ]);
        }

        if (isLoading) {
          trailing.addAll([
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
        } else if (onMorePressed != null) {
          trailing.addAll([
            const SizedBox(width: Spacing.sm),
            Builder(
              builder: (buttonContext) {
                return IconButton(
                  iconSize: IconSize.sm,
                  visualDensity: const VisualDensity(
                    horizontal: -2,
                    vertical: -2,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: TouchTarget.listItem,
                    minHeight: TouchTarget.listItem,
                  ),
                  icon: Icon(
                    Platform.isIOS
                        ? CupertinoIcons.ellipsis
                        : Icons.more_vert_rounded,
                    color: theme.iconSecondary,
                  ),
                  onPressed: () => onMorePressed!(buttonContext),
                  tooltip: AppLocalizations.of(context)!.more,
                );
              },
            ),
          ]);
        }

        return Row(
          mainAxisSize: hasFiniteWidth ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (leading != null) ...[
              SizedBox(
                width: TouchTarget.listItem,
                height: TouchTarget.listItem,
                child: Center(child: leading!),
              ),
              const SizedBox(width: Spacing.sm),
            ],
            Flexible(
              fit: textFit,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            ...trailing,
          ],
        );
      },
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final String title;
  final bool pinned;
  final bool selected;
  final bool isLoading;
  final Widget? leading;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(BuildContext)? onMorePressed;

  const _ConversationTile({
    required this.title,
    required this.pinned,
    required this.selected,
    required this.isLoading,
    this.leading,
    required this.onTap,
    this.onLongPress,
    this.onMorePressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    const BorderRadius borderRadius = BorderRadius.zero;
    final Color background = selected
        ? theme.buttonPrimary.withValues(alpha: 0.1)
        : Colors.transparent;
    final Color borderColor = selected
        ? theme.buttonPrimary.withValues(alpha: 0.5)
        : Colors.transparent;

    final List<BoxShadow> shadow = const [];

    Color? overlayForStates(Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return theme.buttonPrimary.withValues(alpha: Alpha.buttonPressed);
      }
      if (states.contains(WidgetState.focused) ||
          states.contains(WidgetState.hovered)) {
        return theme.buttonPrimary.withValues(alpha: Alpha.hover);
      }
      return Colors.transparent;
    }

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: borderRadius),
        child: InkWell(
          borderRadius: borderRadius,
          onTap: isLoading ? null : onTap,
          onLongPress: onLongPress,
          overlayColor: WidgetStateProperty.resolveWith(overlayForStates),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: background,
              borderRadius: borderRadius,
              border: selected
                  ? Border(
                      top: BorderSide(
                        color: borderColor,
                        width: BorderWidth.thin,
                      ),
                      bottom: BorderSide(
                        color: borderColor,
                        width: BorderWidth.thin,
                      ),
                    )
                  : null,
              boxShadow: shadow,
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
                child: _ConversationTileContent(
                  title: title,
                  pinned: pinned,
                  selected: selected,
                  isLoading: isLoading,
                  onMorePressed: onMorePressed,
                  leading: leading,
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
