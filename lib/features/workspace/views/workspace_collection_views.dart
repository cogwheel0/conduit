part of 'workspace_page.dart';

class _CollectionBinding<T> {
  const _CollectionBinding({
    required this.value,
    required this.idOf,
    required this.titleOf,
    required this.subtitleOf,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onSearch,
    required this.presentationOf,
    this.filterBar,
    this.trailingOf,
  });

  final AsyncValue<WorkspaceCollectionState<T>> value;
  final String Function(T) idOf;
  final String Function(T) titleOf;
  final String? Function(T) subtitleOf;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onLoadMore;
  final Future<void> Function(String) onSearch;
  final WorkspaceResourcePresentation Function(AppLocalizations, T)
  presentationOf;
  final Widget? filterBar;
  final Widget? Function(T)? trailingOf;
}

/// Resolves the [_CollectionBinding] for [section] and hands it to a generic
/// [build] callback. Centralizes the per-section provider wiring.
R _withCollectionBinding<R>(
  WidgetRef ref,
  WorkspaceSection section,
  R Function<T>(_CollectionBinding<T> binding) build,
) {
  switch (section) {
    case WorkspaceSection.models:
      return build<WorkspaceModelSummary>(
        _CollectionBinding(
          value: ref.watch(workspaceModelsProvider),
          idOf: (item) => item.id,
          titleOf: (item) => item.name,
          subtitleOf: (item) => item.baseModelId,
          onRefresh: ref.read(workspaceModelsProvider.notifier).refresh,
          onLoadMore: ref.read(workspaceModelsProvider.notifier).loadMore,
          onSearch: ref.read(workspaceModelsProvider.notifier).setQuery,
          presentationOf: presentWorkspaceModel,
        ),
      );
    case WorkspaceSection.knowledge:
      return build<WorkspaceKnowledgeSummary>(
        _CollectionBinding(
          value: ref.watch(workspaceKnowledgeProvider),
          idOf: (item) => item.id,
          titleOf: (item) => item.name,
          subtitleOf: (item) => item.description,
          onRefresh: ref.read(workspaceKnowledgeProvider.notifier).refresh,
          onLoadMore: ref.read(workspaceKnowledgeProvider.notifier).loadMore,
          onSearch: ref.read(workspaceKnowledgeProvider.notifier).setQuery,
          presentationOf: presentWorkspaceKnowledge,
          filterBar: const _KnowledgeFilterBar(),
        ),
      );
    case WorkspaceSection.prompts:
      return build<WorkspacePromptSummary>(
        _CollectionBinding(
          value: ref.watch(workspacePromptsProvider),
          idOf: (item) => item.id,
          titleOf: (item) => item.name,
          subtitleOf: (item) => item.command.isEmpty
              ? null
              : WorkspacePromptCommand.display(item.command),
          onRefresh: ref.read(workspacePromptsProvider.notifier).refresh,
          onLoadMore: ref.read(workspacePromptsProvider.notifier).loadMore,
          onSearch: ref.read(workspacePromptsProvider.notifier).setQuery,
          presentationOf: presentWorkspacePrompt,
        ),
      );
    case WorkspaceSection.tools:
      return build<WorkspaceToolSummary>(
        _CollectionBinding(
          value: ref.watch(workspaceToolsProvider),
          idOf: (item) => item.id,
          titleOf: (item) => item.name,
          subtitleOf: (item) => item.meta['description']?.toString(),
          onRefresh: ref.read(workspaceToolsProvider.notifier).refresh,
          onLoadMore: ref.read(workspaceToolsProvider.notifier).loadMore,
          onSearch: ref.read(workspaceToolsProvider.notifier).setQuery,
          presentationOf: presentWorkspaceTool,
        ),
      );
    case WorkspaceSection.skills:
      return build<WorkspaceSkillSummary>(
        _CollectionBinding(
          value: ref.watch(workspaceSkillsProvider),
          idOf: (item) => item.id,
          titleOf: (item) => item.name,
          subtitleOf: (item) => item.description,
          onRefresh: ref.read(workspaceSkillsProvider.notifier).refresh,
          onLoadMore: ref.read(workspaceSkillsProvider.notifier).loadMore,
          onSearch: ref.read(workspaceSkillsProvider.notifier).setQuery,
          presentationOf: presentWorkspaceSkill,
        ),
      );
  }
}

/// Fire-and-forget a collection mutation (search/filter/pagination) from a
/// synchronous UI callback.
///
/// The collection notifiers record failures into their own error state (which
/// drives the retry UI) but also rethrow so awaited callers like
/// pull-to-refresh can surface the error. The callbacks below intentionally
/// drop the returned [Future], so absorb the already-recorded error here to keep
/// it from escalating to an uncaught async zone error.
void _fireCollectionMutation(Future<void> Function() action) {
  unawaited(
    action().catchError((Object error, StackTrace stackTrace) {
      DebugLogger.error(
        'workspace collection mutation failed',
        scope: 'workspace/collection',
        error: error,
        stackTrace: stackTrace,
      );
    }),
  );
}

/// Whether the current user can create resources in [section]; drives the
/// permission-gated create (+) affordance.
bool _canCreateSection(WidgetRef ref, WorkspaceSection section) {
  return ref
      .watch(workspaceCapabilitiesProvider)
      .maybeWhen(
        data: (value) => section.capabilities(value).manage,
        orElse: () => false,
      );
}

/// Box (Material) collection layout used on Android compact and both tablet
/// list panes.
class _WorkspaceCollectionPanel extends ConsumerWidget {
  const _WorkspaceCollectionPanel({
    required this.section,
    this.selectedId,
    this.showCreateAction = true,
  });

  final WorkspaceSection section;
  final String? selectedId;
  final bool showCreateAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canCreate = _canCreateSection(ref, section);
    Widget render<T>(_CollectionBinding<T> binding) =>
        _buildColumn<T>(context, binding, canCreate: canCreate);
    return _withCollectionBinding(ref, section, render);
  }

  Widget _buildColumn<T>(
    BuildContext context,
    _CollectionBinding<T> binding, {
    required bool canCreate,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return binding.value.when(
      loading: () =>
          Center(child: ConduitLoading.primary(message: l10n.loadingShort)),
      error: (_, _) => _CollectionError(onRetry: binding.onRefresh),
      data: (collection) {
        if (collection.error != null && collection.items.isEmpty) {
          return _CollectionError(onRetry: binding.onRefresh);
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.pagePadding,
                Spacing.md,
                Spacing.pagePadding,
                Spacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _WorkspaceGlassSearchField(
                      section: section,
                      initialQuery: collection.query,
                      onSearch: binding.onSearch,
                    ),
                  ),
                  if (canCreate && showCreateAction) ...[
                    const SizedBox(width: Spacing.sm),
                    ConduitIconButton(
                      key: Key('workspace-create-${section.name}'),
                      tooltip: l10n.workspaceCreate,
                      onPressed: () =>
                          context.pushWorkspace(section.routes.createPattern),
                      icon: Icons.add,
                    ),
                  ],
                ],
              ),
            ),
            if (binding.filterBar != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.pagePadding,
                  0,
                  Spacing.pagePadding,
                  Spacing.md,
                ),
                child: binding.filterBar,
              ),
            if (collection.isLoading)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: collection.items.isEmpty
                  ? _emptyState(context, section, canCreate: canCreate)
                  : RefreshIndicator(
                      onRefresh: binding.onRefresh,
                      child: ListView.builder(
                        key: Key('workspace-list-${section.name}'),
                        padding: EdgeInsets.only(
                          left: Spacing.pagePadding,
                          right: Spacing.pagePadding,
                          bottom:
                              Spacing.pagePadding +
                              MediaQuery.paddingOf(context).bottom,
                        ),
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount:
                            collection.items.length +
                            (collection.hasMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == collection.items.length) {
                            return _loadMoreFooter(
                              context,
                              isLoadingMore: collection.isLoadingMore,
                              onLoadMore: binding.onLoadMore,
                            );
                          }
                          return _resourceTile<T>(
                            context,
                            binding,
                            collection.items[index],
                            section: section,
                            selectedId: selectedId,
                            groupedIndex: index,
                            groupedLast: index == collection.items.length - 1,
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// iOS compact collection: adaptive app-bar navigation, native pull-to-refresh,
/// a persistent search field, and a sliver list.
class _WorkspaceIosCollectionShell extends ConsumerStatefulWidget {
  const _WorkspaceIosCollectionShell({
    required this.section,
    required this.permitted,
  });

  final WorkspaceSection section;
  final List<WorkspaceSection> permitted;

  @override
  ConsumerState<_WorkspaceIosCollectionShell> createState() =>
      _WorkspaceIosCollectionShellState();
}

class _WorkspaceIosCollectionShellState
    extends ConsumerState<_WorkspaceIosCollectionShell> {
  final ScrollController _scrollController = ScrollController();

  // Latest load-more state, refreshed on every build so the scroll listener can
  // trigger pagination without re-reading providers.
  Future<void> Function()? _onLoadMore;
  bool _hasMore = false;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_hasMore || _isLoadingMore || _onLoadMore == null) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      _fireCollectionMutation(_onLoadMore!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = _canCreateSection(ref, widget.section);
    Widget render<T>(_CollectionBinding<T> binding) =>
        _buildScaffold<T>(binding, canCreate: canCreate);
    return _withCollectionBinding(ref, widget.section, render);
  }

  Widget _buildScaffold<T>(
    _CollectionBinding<T> binding, {
    required bool canCreate,
  }) {
    final pageBackground = CupertinoColors.systemGroupedBackground.resolveFrom(
      context,
    );
    final section = widget.section;

    // Keep the pagination snapshot current for the scroll listener.
    binding.value.whenData((collection) {
      _hasMore = collection.hasMore;
      _isLoadingMore = collection.isLoadingMore;
    });
    _onLoadMore = binding.onLoadMore;

    final currentQuery = binding.value.maybeWhen(
      data: (collection) => collection.query,
      orElse: () => '',
    );
    final showSearch = binding.value.maybeWhen(
      data: (collection) =>
          collection.items.isNotEmpty || collection.query.isNotEmpty,
      orElse: () => true,
    );
    // The iOS 26 navigation bar is a native overlay rather than part of the
    // Flutter scaffold layout. Reserve exactly its safe-area and toolbar
    // extent so the search field begins below the chrome instead of behind
    // the Dynamic Island. Material app bars already inset their body.
    final nativeTopInset = PlatformInfo.isIOS
        ? MediaQuery.paddingOf(context).top +
              conduitAdaptiveToolbarHeightOf(context)
        : 0.0;

    final slivers = <Widget>[
      CupertinoSliverRefreshControl(onRefresh: binding.onRefresh),
      if (nativeTopInset > 0)
        SliverToBoxAdapter(child: SizedBox(height: nativeTopInset)),
      if (showSearch)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              Spacing.md,
            ),
            child: _WorkspaceCupertinoSearchField(
              section: section,
              initialQuery: currentQuery,
              onSearch: binding.onSearch,
            ),
          ),
        ),
      if (binding.filterBar != null)
        SliverToBoxAdapter(
          child: ColoredBox(
            color: pageBackground,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.sm,
                Spacing.md,
                Spacing.md,
              ),
              child: binding.filterBar,
            ),
          ),
        ),
      ..._contentSlivers<T>(binding, section, canCreate: canCreate),
    ];

    return AdaptiveRouteShell(
      backgroundColor: pageBackground,
      appBar: _workspaceCompactCollectionAppBar(
        context,
        section: section,
        permitted: widget.permitted,
        canCreate: canCreate,
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: CustomScrollView(
                controller: _scrollController,
                slivers: slivers,
              ),
            ),
          ),
          if (PlatformInfo.isIOS)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: ConduitChromeGradientFade.top(
                contentHeight: nativeTopInset,
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _contentSlivers<T>(
    _CollectionBinding<T> binding,
    WorkspaceSection section, {
    required bool canCreate,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return binding.value.when(
      loading: () => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: ConduitLoading.primary(message: l10n.loadingShort),
          ),
        ),
      ],
      error: (_, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _CollectionError(onRetry: binding.onRefresh),
        ),
      ],
      data: (collection) {
        if (collection.error != null && collection.items.isEmpty) {
          return [
            SliverFillRemaining(
              hasScrollBody: false,
              child: _CollectionError(onRetry: binding.onRefresh),
            ),
          ];
        }
        if (collection.items.isEmpty) {
          return [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  Spacing.xxl,
                  Spacing.md,
                  Spacing.md,
                ),
                child: _emptyState(context, section, canCreate: canCreate),
              ),
            ),
          ];
        }
        return [
          if (collection.isLoading)
            const SliverToBoxAdapter(
              child: LinearProgressIndicator(minHeight: 2),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.md,
              Spacing.md,
              Spacing.md + MediaQuery.paddingOf(context).bottom,
            ),
            sliver: SliverList(
              key: Key('workspace-list-${section.name}'),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index == collection.items.length) {
                    return _loadMoreFooter(
                      context,
                      isLoadingMore: collection.isLoadingMore,
                      onLoadMore: binding.onLoadMore,
                    );
                  }
                  return _resourceTile<T>(
                    context,
                    binding,
                    collection.items[index],
                    section: section,
                    groupedIndex: index,
                    groupedLast: index == collection.items.length - 1,
                  );
                },
                childCount:
                    collection.items.length + (collection.hasMore ? 1 : 0),
              ),
            ),
          ),
        ];
      },
    );
  }
}

/// Shared list row for a workspace resource, keyed as
/// `workspace-resource-<section>-<id>`. Rendered as a ConduitCard tile with a
/// leading section icon badge, matching the profile/settings tile pattern.
Widget _resourceTile<T>(
  BuildContext context,
  _CollectionBinding<T> binding,
  T item, {
  required WorkspaceSection section,
  String? selectedId,
  int? groupedIndex,
  bool groupedLast = false,
}) {
  final id = binding.idOf(item);
  return WorkspaceCollectionResourceTile(
    section: section,
    resourceId: id,
    icon: _sectionIcon(section),
    title: binding.titleOf(item),
    subtitle: binding.subtitleOf(item),
    trailing: binding.trailingOf?.call(item),
    presentation: binding.presentationOf(AppLocalizations.of(context)!, item),
    selected: selectedId == id,
    groupedIndex: groupedIndex,
    groupedLast: groupedLast,
  );
}

/// Shared empty-collection placeholder, keyed `workspace-empty-<section>`.
Widget _emptyState(
  BuildContext context,
  WorkspaceSection section, {
  required bool canCreate,
}) {
  final l10n = AppLocalizations.of(context)!;
  return ConduitEmptyState(
    key: Key('workspace-empty-${section.name}'),
    icon: _sectionIcon(section),
    title: l10n.workspaceEmpty,
    message: '',
    action: canCreate && !PlatformInfo.isIOS
        ? ConduitButton(
            text: l10n.workspaceCreate,
            icon: Icons.add,
            onPressed: () =>
                context.pushWorkspace(section.routes.createPattern),
          )
        : null,
  );
}

/// Shared load-more footer (spinner while loading, tap-to-load otherwise).
Widget _loadMoreFooter(
  BuildContext context, {
  required bool isLoadingMore,
  required Future<void> Function() onLoadMore,
}) {
  final l10n = AppLocalizations.of(context)!;
  return Padding(
    padding: const EdgeInsets.all(Spacing.md),
    child: Center(
      child: isLoadingMore
          ? ConduitLoading.inline(context: context)
          : AdaptiveButton(
              onPressed: () => _fireCollectionMutation(onLoadMore),
              style: AdaptiveButtonStyle.plain,
              size: AdaptiveButtonSize.small,
              label: l10n.workspaceLoadMore,
            ),
    ),
  );
}

/// Debounced Cupertino search field for the iOS compact collection.
class _WorkspaceCupertinoSearchField extends StatefulWidget {
  const _WorkspaceCupertinoSearchField({
    required this.section,
    required this.initialQuery,
    required this.onSearch,
  });

  final WorkspaceSection section;
  final String initialQuery;
  final Future<void> Function(String) onSearch;

  @override
  State<_WorkspaceCupertinoSearchField> createState() =>
      _WorkspaceCupertinoSearchFieldState();
}

class _WorkspaceCupertinoSearchFieldState
    extends State<_WorkspaceCupertinoSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  Timer? _debounce;

  @override
  void didUpdateWidget(covariant _WorkspaceCupertinoSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync the field when the bound collection query changes externally (e.g. a
    // session/source reset) without clobbering in-progress typing: once the
    // debounced change reaches the provider, initialQuery matches the field.
    if (widget.initialQuery != oldWidget.initialQuery &&
        widget.initialQuery != _controller.text) {
      _controller.text = widget.initialQuery;
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _fireCollectionMutation(() => widget.onSearch(value)),
    );
  }

  void _onSubmitted(String value) {
    _debounce?.cancel();
    _fireCollectionMutation(() => widget.onSearch(value));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoSearchTextField(
      key: Key('workspace-search-${widget.section.name}'),
      controller: _controller,
      placeholder: l10n.workspaceSearchHint,
      onChanged: _onChanged,
      onSubmitted: _onSubmitted,
    );
  }
}

/// Debounced glass search field for the Android compact and tablet layouts.
class _WorkspaceGlassSearchField extends StatefulWidget {
  const _WorkspaceGlassSearchField({
    required this.section,
    required this.initialQuery,
    required this.onSearch,
  });

  final WorkspaceSection section;
  final String initialQuery;
  final Future<void> Function(String) onSearch;

  @override
  State<_WorkspaceGlassSearchField> createState() =>
      _WorkspaceGlassSearchFieldState();
}

class _WorkspaceGlassSearchFieldState
    extends State<_WorkspaceGlassSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  late String _query = widget.initialQuery;
  Timer? _debounce;

  @override
  void didUpdateWidget(covariant _WorkspaceGlassSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync the field when the bound collection query changes externally (e.g. a
    // session/source reset) without clobbering in-progress typing: once the
    // debounced change reaches the provider, initialQuery matches the field.
    if (widget.initialQuery != oldWidget.initialQuery &&
        widget.initialQuery != _controller.text) {
      _controller.text = widget.initialQuery;
      _query = widget.initialQuery;
    }
  }

  void _onChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _fireCollectionMutation(() => widget.onSearch(value)),
    );
  }

  void _onClear() {
    _controller.clear();
    setState(() => _query = '');
    _debounce?.cancel();
    _fireCollectionMutation(() => widget.onSearch(''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ConduitGlassSearchField(
      key: Key('workspace-search-${widget.section.name}'),
      controller: _controller,
      hintText: l10n.workspaceSearchHint,
      query: _query,
      onChanged: _onChanged,
      onClear: _onClear,
    );
  }
}
