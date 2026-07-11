import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';

class WorkspacePage extends ConsumerWidget {
  const WorkspacePage({
    super.key,
    this.section,
    this.mode = WorkspaceRouteMode.collection,
    this.resourceId,
  });

  final WorkspaceSection? section;
  final WorkspaceRouteMode mode;
  final String? resourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = section;
    return WorkspaceGate(
      section: selected,
      child: selected == null
          ? const SizedBox.shrink()
          : WorkspaceScaffold(
              section: selected,
              mode: mode,
              resourceId: resourceId,
            ),
    );
  }
}

class WorkspaceGate extends ConsumerWidget {
  const WorkspaceGate({super.key, required this.section, required this.child});

  final WorkspaceSection? section;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(reviewerModeProvider)) {
      return const _WorkspaceGateState(kind: _GateStateKind.denied);
    }

    final capabilities = ref.watch(workspaceCapabilitiesProvider);
    return capabilities.when(
      loading: () => const _WorkspaceGateState(
        key: Key('workspace-loading'),
        kind: _GateStateKind.loading,
      ),
      error: (error, _) => _WorkspaceGateState(
        key: const Key('workspace-error'),
        kind: _isUnsupported(error)
            ? _GateStateKind.unsupported
            : _GateStateKind.error,
        onRetry: () => ref.invalidate(workspaceCapabilitiesProvider),
      ),
      data: (value) {
        final permitted = permittedWorkspaceSections(value);
        final requested = section;
        if (requested == null) {
          return permitted.isEmpty
              ? const _WorkspaceGateState(
                  key: Key('workspace-denied'),
                  kind: _GateStateKind.denied,
                )
              : const _WorkspaceGateState(
                  key: Key('workspace-loading'),
                  kind: _GateStateKind.loading,
                );
        }
        if (!permitted.contains(requested)) {
          return const _WorkspaceGateState(
            key: Key('workspace-denied'),
            kind: _GateStateKind.denied,
          );
        }
        return child;
      },
    );
  }

  static bool _isUnsupported(Object error) {
    return error is DioException &&
        (error.response?.statusCode == 404 ||
            error.response?.statusCode == 405);
  }
}

enum _GateStateKind { loading, denied, unsupported, error }

class _WorkspaceGateState extends StatelessWidget {
  const _WorkspaceGateState({super.key, required this.kind, this.onRetry});

  final _GateStateKind kind;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      appBar: AdaptiveAppBar(title: l10n.workspaceTitle),
      body: _WorkspaceStatusContent(kind: kind, onRetry: onRetry),
    );
  }
}

class _WorkspaceStatusContent extends StatelessWidget {
  const _WorkspaceStatusContent({required this.kind, this.onRetry});

  final _GateStateKind kind;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final message = switch (kind) {
      _GateStateKind.loading => l10n.loadingShort,
      _GateStateKind.denied => l10n.workspaceDenied,
      _GateStateKind.unsupported => l10n.workspaceUnsupported,
      _GateStateKind.error => l10n.workspaceLoadFailed,
    };
    final icon = switch (kind) {
      _GateStateKind.loading => null,
      _GateStateKind.denied => Icons.lock_outline,
      _GateStateKind.unsupported => Icons.cloud_off_outlined,
      _GateStateKind.error => Icons.error_outline,
    };
    return Semantics(
      liveRegion: true,
      label: message,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (kind == _GateStateKind.loading)
                ConduitLoading.primary(message: message)
              else ...[
                Icon(icon, size: 36, color: theme.iconSecondary),
                const SizedBox(height: Spacing.md),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: Spacing.lg),
                  FilledButton(
                    key: const Key('workspace-retry'),
                    onPressed: onRetry,
                    child: Text(l10n.workspaceRetry),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class WorkspaceScaffold extends ConsumerWidget {
  const WorkspaceScaffold({
    super.key,
    required this.section,
    required this.mode,
    this.resourceId,
  });

  final WorkspaceSection section;
  final WorkspaceRouteMode mode;
  final String? resourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final permitted = ref
        .watch(workspaceCapabilitiesProvider)
        .maybeWhen(
          data: permittedWorkspaceSections,
          orElse: () => const <WorkspaceSection>[],
        );
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final theme = context.conduitTheme;

    // iOS compact collection uses native Cupertino chrome (a sliver navigation
    // bar with search + a pinned segmented switcher), so it hosts its own
    // CupertinoPageScaffold and must NOT be wrapped in an AdaptiveRouteShell —
    // doing so would stack a second navigation bar.
    if (!wide &&
        PlatformInfo.isIOS &&
        mode == WorkspaceRouteMode.collection) {
      return _WorkspaceIosCollectionShell(
        section: section,
        permitted: permitted,
      );
    }

    // The adaptive iOS nav bar is a translucent overlay, so the body renders
    // behind it. Mirror SettingsPageScaffold and inset the top by the status
    // bar + nav bar height so the section switcher and content clear it;
    // Android's Material app bar reserves its own space, so no extra inset is
    // needed.
    final topInset = Theme.of(context).platform == TargetPlatform.iOS
        ? MediaQuery.paddingOf(context).top + kTextTabBarHeight
        : 0.0;

    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      appBar: AdaptiveAppBar(
        title: '${l10n.workspaceTitle} · ${_sectionLabel(l10n, section)}',
      ),
      body: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: SafeArea(
            top: false,
            child: wide
                ? _buildWide(context, permitted)
                : _buildCompact(context, permitted),
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, List<WorkspaceSection> permitted) {
    return Column(
      children: [
        _WorkspaceSectionSwitcher(selected: section, permitted: permitted),
        Divider(height: 1, color: context.conduitTheme.dividerColor),
        Expanded(
          child: mode == WorkspaceRouteMode.collection
              ? _WorkspaceCollectionPanel(section: section)
              : _WorkspaceDetailPanel(
                  section: section,
                  mode: mode,
                  resourceId: resourceId,
                ),
        ),
      ],
    );
  }

  Widget _buildWide(BuildContext context, List<WorkspaceSection> permitted) {
    final theme = context.conduitTheme;
    return Row(
      children: [
        SizedBox(
          width: 184,
          child: Material(
            color: theme.surfaceContainer,
            child: _WorkspaceSectionRail(
              selected: section,
              permitted: permitted,
            ),
          ),
        ),
        VerticalDivider(width: 1, color: theme.dividerColor),
        SizedBox(
          width: 320,
          child: _WorkspaceCollectionPanel(
            section: section,
            selectedId: resourceId,
          ),
        ),
        VerticalDivider(width: 1, color: theme.dividerColor),
        Expanded(
          child: _WorkspaceDetailPanel(
            section: section,
            mode: mode,
            resourceId: resourceId,
          ),
        ),
      ],
    );
  }
}

/// Adaptive section switcher shared by the iOS pinned header and the Android
/// compact column. Renders a native `CupertinoSlidingSegmentedControl` on iOS
/// and a Material `SegmentedButton` elsewhere, preserving the
/// `workspace-section-tabs` container key and per-segment `workspace-tab-<name>`
/// keys that tests depend on. Selecting a segment navigates to that section.
class _WorkspaceSectionSwitcher extends StatelessWidget {
  const _WorkspaceSectionSwitcher({
    required this.selected,
    required this.permitted,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Spacing.md,
      vertical: Spacing.sm,
    ),
  });

  final WorkspaceSection selected;
  final List<WorkspaceSection> permitted;
  final EdgeInsets padding;

  void _select(BuildContext context, WorkspaceSection next) {
    if (next != selected) {
      context.go(next.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    Widget control;
    if (permitted.length < 2) {
      // A sliding segmented control needs at least two segments; when only one
      // section is permitted just label it (still keyed for tests).
      final only = permitted.isNotEmpty ? permitted.first : selected;
      control = Center(
        child: Text(
          _sectionLabel(l10n, only),
          key: Key('workspace-tab-${only.name}'),
          style: theme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
    } else if (PlatformInfo.isIOS) {
      control = LayoutBuilder(
        builder: (context, constraints) {
          final segmented = CupertinoSlidingSegmentedControl<WorkspaceSection>(
            groupValue: permitted.contains(selected) ? selected : null,
            onValueChanged: (value) {
              if (value != null) _select(context, value);
            },
            children: {
              for (final item in permitted)
                item: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: Spacing.xs,
                  ),
                  child: Text(
                    _sectionLabel(l10n, item),
                    key: Key('workspace-tab-${item.name}'),
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            },
          );
          // Fill the available width when the labels fit; if they would
          // overflow, let the control keep its intrinsic width and scroll
          // horizontally instead of truncating.
          final minWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 0.0;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: minWidth),
              child: segmented,
            ),
          );
        },
      );
    } else {
      control = SegmentedButton<WorkspaceSection>(
        showSelectedIcon: false,
        selected: {permitted.contains(selected) ? selected : permitted.first},
        segments: [
          for (final item in permitted)
            ButtonSegment<WorkspaceSection>(
              value: item,
              label: Text(
                _sectionLabel(l10n, item),
                key: Key('workspace-tab-${item.name}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) _select(context, selection.first);
        },
      );
    }

    return Semantics(
      container: true,
      label: l10n.workspaceTitle,
      child: Padding(
        key: const Key('workspace-section-tabs'),
        padding: padding,
        child: control,
      ),
    );
  }
}

class _WorkspaceSectionRail extends StatelessWidget {
  const _WorkspaceSectionRail({
    required this.selected,
    required this.permitted,
  });

  final WorkspaceSection selected;
  final List<WorkspaceSection> permitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListView(
      key: const Key('workspace-section-rail'),
      padding: const EdgeInsets.all(Spacing.sm),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.sm,
            Spacing.md,
            Spacing.sm,
            Spacing.sm,
          ),
          child: Text(
            l10n.workspaceSubtitle,
            style: context.conduitTheme.bodySmall?.copyWith(
              color: context.conduitTheme.textSecondary,
            ),
          ),
        ),
        for (final item in permitted)
          ListTile(
            key: Key('workspace-rail-${item.name}'),
            selected: item == selected,
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
            ),
            leading: Icon(_sectionIcon(item), size: IconSize.small),
            title: Text(_sectionLabel(l10n, item)),
            onTap: () => context.go(item.path),
          ),
      ],
    );
  }
}

/// A per-section bundle of the collection state and its notifier callbacks,
/// resolved once by [_withCollectionBinding] so the box (Android/tablet) and
/// sliver (iOS) renderers never duplicate the section switch.
class _CollectionBinding<T> {
  const _CollectionBinding({
    required this.value,
    required this.idOf,
    required this.titleOf,
    required this.subtitleOf,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onSearch,
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
          filterBar: const _KnowledgeFilterBar(),
          trailingOf: (item) =>
              item.isExternal ? const _KnowledgeExternalBadge() : null,
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
        ),
      );
  }
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
  const _WorkspaceCollectionPanel({required this.section, this.selectedId});

  final WorkspaceSection section;
  final String? selectedId;

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
              padding: const EdgeInsets.all(Spacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: _WorkspaceGlassSearchField(
                      section: section,
                      initialQuery: collection.query,
                      onSearch: binding.onSearch,
                    ),
                  ),
                  if (canCreate) ...[
                    const SizedBox(width: Spacing.sm),
                    IconButton(
                      key: Key('workspace-create-${section.name}'),
                      tooltip: l10n.workspaceCreate,
                      onPressed: () =>
                          context.push(section.routes.createPattern),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ],
              ),
            ),
            if (binding.filterBar != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  0,
                  Spacing.md,
                  Spacing.sm,
                ),
                child: binding.filterBar,
              ),
            if (collection.isLoading)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: collection.items.isEmpty
                  ? _emptyState(context, section)
                  : RefreshIndicator(
                      onRefresh: binding.onRefresh,
                      child: ListView.builder(
                        key: Key('workspace-list-${section.name}'),
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

/// iOS compact collection: a `CupertinoPageScaffold` hosting a
/// `CustomScrollView` with a searchable large-title navigation bar, a pinned
/// segmented section switcher, native pull-to-refresh, and a sliver list.
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
      _onLoadMore!.call();
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
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
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

    final slivers = <Widget>[
      CupertinoSliverNavigationBar.search(
        largeTitle: Text(l10n.workspaceTitle),
        // The search field is the nav bar's bottom slot (not the largeTitle),
        // so its ValueKey is safe from the largeTitle double-insertion.
        searchField: _WorkspaceCupertinoSearchField(
          section: section,
          initialQuery: currentQuery,
          onSearch: binding.onSearch,
        ),
        trailing: canCreate ? _iosCreateButton(context, section, l10n) : null,
      ),
      CupertinoSliverRefreshControl(onRefresh: binding.onRefresh),
      SliverPersistentHeader(
        pinned: true,
        delegate: _SegmentedHeaderDelegate(
          selected: section,
          permitted: widget.permitted,
          background: theme.surfaceBackground,
          dividerColor: theme.dividerColor,
        ),
      ),
      if (binding.filterBar != null)
        SliverToBoxAdapter(
          child: ColoredBox(
            color: theme.surfaceBackground,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.sm,
                Spacing.md,
                Spacing.sm,
              ),
              child: binding.filterBar,
            ),
          ),
        ),
      ..._contentSlivers<T>(binding, section),
    ];

    return CupertinoPageScaffold(
      backgroundColor: theme.surfaceBackground,
      // Material ancestor so shared ListTile/FilledButton/progress widgets in
      // the slivers keep working under the Cupertino scaffold.
      child: Material(
        color: Colors.transparent,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: slivers,
        ),
      ),
    );
  }

  List<Widget> _contentSlivers<T>(
    _CollectionBinding<T> binding,
    WorkspaceSection section,
  ) {
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
            SliverFillRemaining(
              hasScrollBody: false,
              child: _emptyState(context, section),
            ),
          ];
        }
        return [
          if (collection.isLoading)
            const SliverToBoxAdapter(
              child: LinearProgressIndicator(minHeight: 2),
            ),
          SliverList(
            key: Key('workspace-list-${section.name}'),
            delegate: SliverChildBuilderDelegate((context, index) {
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
              );
            }, childCount: collection.items.length + (collection.hasMore ? 1 : 0)),
          ),
        ];
      },
    );
  }
}

/// Native create (+) affordance for the iOS sliver navigation bar.
Widget _iosCreateButton(
  BuildContext context,
  WorkspaceSection section,
  AppLocalizations l10n,
) {
  return Tooltip(
    message: l10n.workspaceCreate,
    child: CupertinoButton(
      key: Key('workspace-create-${section.name}'),
      padding: EdgeInsets.zero,
      onPressed: () => context.push(section.routes.createPattern),
      child: Semantics(
        button: true,
        label: l10n.workspaceCreate,
        child: const Icon(CupertinoIcons.add),
      ),
    ),
  );
}

/// Shared list row for a workspace resource, keyed as
/// `workspace-resource-<section>-<id>`.
Widget _resourceTile<T>(
  BuildContext context,
  _CollectionBinding<T> binding,
  T item, {
  required WorkspaceSection section,
  String? selectedId,
}) {
  final id = binding.idOf(item);
  final subtitle = binding.subtitleOf(item);
  final trailing = binding.trailingOf?.call(item);
  return ListTile(
    key: Key('workspace-resource-${section.name}-$id'),
    selected: selectedId == id,
    title: Text(binding.titleOf(item)),
    subtitle: subtitle == null || subtitle.isEmpty
        ? null
        : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: trailing == null
        ? const Icon(Icons.chevron_right)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [trailing, const Icon(Icons.chevron_right)],
          ),
    onTap: () => context.push(section.routes.detailLocation(id)),
  );
}

/// Shared empty-collection placeholder, keyed `workspace-empty-<section>`.
Widget _emptyState(BuildContext context, WorkspaceSection section) {
  final l10n = AppLocalizations.of(context)!;
  final theme = context.conduitTheme;
  return Center(
    key: Key('workspace-empty-${section.name}'),
    child: Text(
      l10n.workspaceEmpty,
      style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
    ),
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
          : TextButton(
              onPressed: onLoadMore,
              child: Text(l10n.workspaceLoadMore),
            ),
    ),
  );
}

/// Fixed-height pinned header hosting the section switcher for the iOS sliver
/// layout.
class _SegmentedHeaderDelegate extends SliverPersistentHeaderDelegate {
  _SegmentedHeaderDelegate({
    required this.selected,
    required this.permitted,
    required this.background,
    required this.dividerColor,
  });

  final WorkspaceSection selected;
  final List<WorkspaceSection> permitted;
  final Color background;
  final Color dividerColor;

  static const double _extent = 56;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      height: _extent,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        border: Border(
          bottom: BorderSide(color: dividerColor, width: 0.5),
        ),
      ),
      child: _WorkspaceSectionSwitcher(
        selected: selected,
        permitted: permitted,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SegmentedHeaderDelegate oldDelegate) {
    return oldDelegate.selected != selected ||
        !listEquals(oldDelegate.permitted, permitted) ||
        oldDelegate.background != background ||
        oldDelegate.dividerColor != dividerColor;
  }
}

/// Debounced Cupertino search field for the iOS sliver navigation bar.
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

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => widget.onSearch(value),
    );
  }

  void _onSubmitted(String value) {
    _debounce?.cancel();
    widget.onSearch(value);
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

  void _onChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => widget.onSearch(value),
    );
  }

  void _onClear() {
    _controller.clear();
    setState(() => _query = '');
    _debounce?.cancel();
    widget.onSearch('');
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

class _CollectionError extends StatelessWidget {
  const _CollectionError({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              color: context.conduitTheme.iconSecondary,
              size: 32,
            ),
            const SizedBox(height: Spacing.md),
            Text(l10n.workspaceLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: Spacing.md),
            FilledButton(onPressed: onRetry, child: Text(l10n.workspaceRetry)),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceDetailPanel extends ConsumerWidget {
  const _WorkspaceDetailPanel({
    required this.section,
    required this.mode,
    this.resourceId,
  });

  final WorkspaceSection section;
  final WorkspaceRouteMode mode;
  final String? resourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (mode == WorkspaceRouteMode.collection) {
      return Center(
        key: const Key('workspace-select-placeholder'),
        child: Text(
          l10n.workspaceSelectItem,
          style: context.conduitTheme.bodyMedium?.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
      );
    }

    // Resolve a real section editor when one is registered; otherwise fall
    // through to the placeholder so unbuilt sections degrade gracefully.
    final editorBuilder = ref.watch(workspaceSectionEditorsProvider)[section];
    if (editorBuilder != null) {
      return editorBuilder(
        context,
        WorkspaceEditorArgs(
          section: section,
          mode: mode,
          resourceId: resourceId,
        ),
      );
    }

    if (mode == WorkspaceRouteMode.create) {
      return _EditorPlaceholder(
        key: Key('workspace-${section.name}-create-placeholder'),
        title: '${l10n.workspaceCreate} ${_sectionLabel(l10n, section)}',
      );
    }

    final id = resourceId;
    if (id == null || id.isEmpty) {
      return const _WorkspaceStatusContent(kind: _GateStateKind.error);
    }
    final detail = switch (section) {
      WorkspaceSection.models => ref.watch(workspaceModelDetailProvider(id)),
      WorkspaceSection.knowledge => ref.watch(
        workspaceKnowledgeDetailProvider(id),
      ),
      WorkspaceSection.prompts => ref.watch(workspacePromptDetailProvider(id)),
      WorkspaceSection.tools => ref.watch(workspaceToolDetailProvider(id)),
      WorkspaceSection.skills => ref.watch(workspaceSkillDetailProvider(id)),
    };
    return detail.when(
      loading: () =>
          Center(child: ConduitLoading.primary(message: l10n.loadingShort)),
      error: (_, _) =>
          const _WorkspaceStatusContent(kind: _GateStateKind.error),
      data: (value) => _EditorPlaceholder(
        key: Key('workspace-${section.name}-${mode.name}-$id'),
        title: _detailTitle(value) ?? id,
        showEdit: mode == WorkspaceRouteMode.detail,
        onEdit: () => context.push(section.routes.editLocation(id)),
      ),
    );
  }

  String? _detailTitle(Object? detail) {
    return switch (detail) {
      WorkspaceModelSummary() => detail.name,
      WorkspaceKnowledgeDetail() => detail.summary.name,
      WorkspacePromptSummary() => detail.name,
      WorkspaceToolSummary() => detail.name,
      WorkspaceSkillSummary() => detail.name,
      _ => null,
    };
  }
}

class _EditorPlaceholder extends StatelessWidget {
  const _EditorPlaceholder({
    super.key,
    required this.title,
    this.showEdit = false,
    this.onEdit,
  });

  final String title;
  final bool showEdit;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Semantics(
      label: title,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.square_grid_2x2,
                  size: 36,
                  color: theme.iconSecondary,
                ),
                const SizedBox(height: Spacing.md),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.headingSmall,
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  l10n.workspaceEditorComingSoon,
                  textAlign: TextAlign.center,
                  style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
                ),
                if (showEdit && onEdit != null) ...[
                  const SizedBox(height: Spacing.lg),
                  FilledButton.icon(
                    key: const Key('workspace-edit-action'),
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(l10n.edit),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Created/shared (view) + local/external (source) filters for the Knowledge
/// collection. Both map to server-side filters on `/knowledge/search`.
class _KnowledgeFilterBar extends ConsumerWidget {
  const _KnowledgeFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref
        .watch(workspaceKnowledgeProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const WorkspaceCollectionState<WorkspaceKnowledgeSummary>(),
        );
    final view = (state.view == 'created' || state.view == 'shared')
        ? state.view
        : '';
    final notifier = ref.read(workspaceKnowledgeProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: const Key('workspace-knowledge-view-filter'),
            initialValue: view,
            isExpanded: true,
            isDense: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              DropdownMenuItem(value: '', child: Text(l10n.workspaceKnowledgeViewAll)),
              DropdownMenuItem(
                value: 'created',
                child: Text(l10n.workspaceKnowledgeViewCreated),
              ),
              DropdownMenuItem(
                value: 'shared',
                child: Text(l10n.workspaceKnowledgeViewShared),
              ),
            ],
            onChanged: (value) => notifier.setView(value ?? ''),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: DropdownButtonFormField<String>(
            key: const Key('workspace-knowledge-source-filter'),
            initialValue: state.source,
            isExpanded: true,
            isDense: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(l10n.workspaceKnowledgeSourceAll),
              ),
              DropdownMenuItem(
                value: 'local',
                child: Text(l10n.workspaceKnowledgeSourceLocal),
              ),
              DropdownMenuItem(
                value: 'external',
                child: Text(l10n.workspaceKnowledgeSourceExternal),
              ),
            ],
            onChanged: (value) => notifier.setSource(value ?? ''),
          ),
        ),
      ],
    );
  }
}

/// Compact "Connected" chip marking an external (read-only) knowledge base.
class _KnowledgeExternalBadge extends StatelessWidget {
  const _KnowledgeExternalBadge();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(right: Spacing.xs),
      child: Container(
        key: const Key('workspace-knowledge-external-badge'),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs,
          vertical: Spacing.xxs,
        ),
        decoration: BoxDecoration(
          color: theme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppBorderRadius.badge),
        ),
        child: Text(
          l10n.workspaceKnowledgeExternalBadge,
          style: theme.caption?.copyWith(color: theme.textSecondary),
        ),
      ),
    );
  }
}

String _sectionLabel(AppLocalizations l10n, WorkspaceSection section) {
  return switch (section) {
    WorkspaceSection.models => l10n.workspaceModels,
    WorkspaceSection.knowledge => l10n.workspaceKnowledge,
    WorkspaceSection.prompts => l10n.workspacePrompts,
    WorkspaceSection.tools => l10n.workspaceTools,
    WorkspaceSection.skills => l10n.workspaceSkills,
  };
}

IconData _sectionIcon(WorkspaceSection section) {
  return switch (section) {
    WorkspaceSection.models => Icons.hub_outlined,
    WorkspaceSection.knowledge => Icons.library_books_outlined,
    WorkspaceSection.prompts => Icons.short_text,
    WorkspaceSection.tools => Icons.build_outlined,
    WorkspaceSection.skills => Icons.auto_awesome_outlined,
  };
}
