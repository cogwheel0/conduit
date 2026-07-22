import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/widgets/workspace_section_editors.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
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
      appBar: AdaptiveAppBar(
        title: l10n.workspaceTitle,
        leading: _workspaceExitButton(context),
      ),
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
    if (kind == _GateStateKind.loading) {
      return Semantics(
        liveRegion: true,
        label: message,
        child: Center(child: ConduitLoading.primary(message: message)),
      );
    }
    return Semantics(
      liveRegion: true,
      label: message,
      child: ConduitEmptyState(
        icon: icon!,
        title: l10n.workspaceTitle,
        message: message,
        action: onRetry == null
            ? null
            : ConduitButton(
                key: const Key('workspace-retry'),
                text: l10n.workspaceRetry,
                onPressed: onRetry,
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
    // The three-pane layout reserves 184px for the rail and 320px for the
    // collection list (plus dividers); anything below the Material expanded
    // breakpoint leaves the detail/editor pane too narrow to render forms, so
    // fall back to the single-pane compact layout there.
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final theme = context.conduitTheme;

    // iOS compact collection uses native Cupertino chrome (a sliver navigation
    // bar with search + a pinned segmented switcher), so it hosts its own
    // CupertinoPageScaffold and must NOT be wrapped in an AdaptiveRouteShell —
    // doing so would stack a second navigation bar.
    if (!wide && PlatformInfo.isIOS && mode == WorkspaceRouteMode.collection) {
      return _WorkspaceIosCollectionShell(
        section: section,
        permitted: permitted,
      );
    }

    // iOS 26 native toolbars contribute their height to MediaQuery padding as
    // of adaptive_platform_ui 0.1.110. Older Cupertino bars still need the
    // explicit status-bar + navigation-bar offset used before that release.
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;
    final usesNativeToolbarInset = isIos && PlatformInfo.isIOS26OrHigher();
    final topInset = isIos && !usesNativeToolbarInset
        ? MediaQuery.paddingOf(context).top +
              conduitAdaptiveToolbarHeightOf(context)
        : 0.0;

    final appBar = !wide && mode == WorkspaceRouteMode.collection
        ? _workspaceCompactCollectionAppBar(
            context,
            section: section,
            permitted: permitted,
            canCreate: _canCreateSection(ref, section),
          )
        : AdaptiveAppBar(
            title: l10n.workspaceTitle,
            subtitle: _sectionLabel(l10n, section),
            leading: _workspaceExitButton(context),
          );

    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      appBar: appBar,
      body: Material(
        color: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: SafeArea(
            top: usesNativeToolbarInset,
            child: wide
                ? _buildWide(context, permitted)
                : _buildCompact(context, permitted),
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, List<WorkspaceSection> permitted) {
    if (mode == WorkspaceRouteMode.collection) {
      return _WorkspaceCollectionPanel(
        section: section,
        showCreateAction: false,
      );
    }
    return _WorkspaceDetailPanel(
      section: section,
      mode: mode,
      resourceId: resourceId,
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

/// Compact Workspace chrome. The current section lives in the adaptive app
/// bar and opens a native popup menu, so every permitted destination remains
/// visible without squeezing labels into a segmented control.
AdaptiveAppBar _workspaceCompactCollectionAppBar(
  BuildContext context, {
  required WorkspaceSection section,
  required List<WorkspaceSection> permitted,
  required bool canCreate,
}) {
  final theme = context.conduitTheme;
  final isIos = PlatformInfo.isIOS;
  final textScaler = MediaQuery.textScalerOf(context);
  final controlExtent = conduitScaledControlExtent(context);
  final toolbarHeight = conduitAdaptiveToolbarHeightOf(context);

  Widget sectionMenu({required bool activePlatform}) => _WorkspaceSectionMenu(
    key: activePlatform ? const Key('workspace-section-tabs') : null,
    selected: section,
    permitted: permitted,
  );

  Widget createButton({required bool activePlatform}) => Tooltip(
    message: AppLocalizations.of(context)!.workspaceCreate,
    child: KeyedSubtree(
      key: activePlatform ? Key('workspace-create-${section.name}') : null,
      child: ConduitAdaptiveAppBarIconButton(
        icon: PlatformInfo.isIOS ? CupertinoIcons.add : Icons.add,
        iconColor: theme.textPrimary,
        onPressed: () => context.push(section.routes.createPattern),
      ),
    ),
  );

  final materialLeading = ConduitSystemTextScaling(
    textScaler: textScaler,
    child: _workspaceExitButton(context),
  );
  final materialTitle = ConduitSystemTextScaling(
    textScaler: textScaler,
    child: sectionMenu(activePlatform: !isIos),
  );
  final materialCreate = ConduitSystemTextScaling(
    textScaler: textScaler,
    child: createButton(activePlatform: !isIos),
  );

  return AdaptiveAppBar(
    useNativeToolbar: false,
    tintColor: theme.textPrimary,
    cupertinoNavigationBar: ConduitAdaptiveCupertinoNavigationBar(
      textScaler: textScaler,
      leading: _workspaceExitButton(context),
      middle: sectionMenu(activePlatform: isIos),
      trailing: canCreate
          ? createButton(activePlatform: isIos)
          : const SizedBox.shrink(),
    ),
    appBar: AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: Elevation.none,
      scrolledUnderElevation: Elevation.none,
      toolbarHeight: toolbarHeight,
      centerTitle: true,
      leadingWidth: controlExtent + Spacing.md,
      leading: materialLeading,
      title: materialTitle,
      actions: canCreate
          ? [
              Padding(
                padding: const EdgeInsets.only(right: Spacing.inputPadding),
                child: materialCreate,
              ),
            ]
          : null,
    ),
  );
}

class _WorkspaceSectionMenu extends StatelessWidget {
  const _WorkspaceSectionMenu({
    super.key,
    required this.selected,
    required this.permitted,
  });

  final WorkspaceSection selected;
  final List<WorkspaceSection> permitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = '${l10n.workspaceTitle} · ${_sectionLabel(l10n, selected)}';
    if (permitted.length < 2) {
      return Text(label, style: conduitAdaptiveToolbarPillTextStyle(context));
    }

    final textStyle = conduitAdaptiveToolbarPillTextStyle(context);
    final controlScale = conduitSystemControlScaleOf(context);
    final iconSize = conduitScaledIconExtent(context, IconSize.small);
    final targetWidth = resolveConduitAdaptiveTextPillWidth(
      context: context,
      label: label,
      textStyle: textStyle,
      maxWidth: 260,
      minWidth: 120,
      horizontalPadding: 20,
      trailingWidth: iconSize + Spacing.sm,
    );

    return AdaptivePopupMenuButton.widget<WorkspaceSection>(
      tint: context.conduitTheme.textPrimary,
      buttonStyle: PopupButtonStyle.glass,
      child: SizedBox(
        width: targetWidth,
        height: 32 * controlScale,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              ConduitSystemAdaptiveIcon(
                PlatformInfo.isIOS
                    ? CupertinoIcons.chevron_down
                    : Icons.keyboard_arrow_down_rounded,
                size: iconSize,
                color: context.conduitTheme.iconSecondary,
              ),
            ],
          ),
        ),
      ),
      items: [
        for (final item in permitted)
          AdaptivePopupMenuItem<WorkspaceSection>(
            value: item,
            label: _sectionLabel(l10n, item),
            icon: conduitAdaptivePopupMenuIcon(
              iosSymbol: item == selected
                  ? 'checkmark'
                  : _sectionIosSymbol(item),
              materialIcon: item == selected
                  ? Icons.check_rounded
                  : _sectionIcon(item),
            ),
          ),
      ],
      onSelected: (_, entry) {
        final next = entry.value;
        if (next != null && next != selected) {
          context.pushReplacement(next.path);
        }
      },
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
    final theme = context.conduitTheme;
    return ListView(
      key: const Key('workspace-section-rail'),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.sm,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.xs,
            Spacing.md,
            Spacing.xs,
            Spacing.sm,
          ),
          child: Text(
            l10n.workspaceSubtitle,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
        ),
        for (final item in permitted)
          ListTile(
            key: Key('workspace-rail-${item.name}'),
            selected: item == selected,
            selectedTileColor: theme.buttonPrimary.withValues(alpha: 0.1),
            selectedColor: theme.buttonPrimary,
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppBorderRadius.small),
            ),
            leading: Icon(_sectionIcon(item), size: IconSize.small),
            title: Text(_sectionLabel(l10n, item)),
            onTap: () => context.pushReplacement(item.path),
          ),
      ],
    );
  }
}

Widget _workspaceExitButton(BuildContext context) {
  final button = Tooltip(
    message: MaterialLocalizations.of(context).backButtonTooltip,
    child: ConduitAdaptiveAppBarIconButton(
      key: const Key('workspace-exit'),
      icon: PlatformInfo.isIOS ? CupertinoIcons.back : Icons.arrow_back,
      iconColor: context.conduitTheme.textPrimary,
      onPressed: () {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(Routes.profile);
        }
      },
    ),
  );

  // Material gives AppBar.leading tight 56x56 constraints. Loosen them around
  // the adaptive control so its painted surface remains the standard 44dp
  // toolbar action size instead of expanding to fill the entire leading slot.
  return context.usesCupertinoChrome
      ? button
      : Center(
          child: SizedBox.square(
            dimension: conduitScaledControlExtent(context),
            child: button,
          ),
        );
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
                  ? _emptyState(context, section)
                  : RefreshIndicator(
                      onRefresh: binding.onRefresh,
                      child: ListView.builder(
                        key: Key('workspace-list-${section.name}'),
                        padding: EdgeInsets.only(
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
      CupertinoSliverRefreshControl(onRefresh: binding.onRefresh),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.pagePadding,
            Spacing.md,
            Spacing.pagePadding,
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
            color: theme.surfaceBackground,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.pagePadding,
                Spacing.sm,
                Spacing.pagePadding,
                Spacing.md,
              ),
              child: binding.filterBar,
            ),
          ),
        ),
      ..._contentSlivers<T>(binding, section),
    ];

    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      appBar: _workspaceCompactCollectionAppBar(
        context,
        section: section,
        permitted: widget.permitted,
        canCreate: canCreate,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top:
              MediaQuery.paddingOf(context).top +
              conduitAdaptiveToolbarHeightOf(context),
        ),
        child: Material(
          color: Colors.transparent,
          child: CustomScrollView(
            controller: _scrollController,
            slivers: slivers,
          ),
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
          SliverPadding(
            padding: EdgeInsets.only(
              top: Spacing.md,
              bottom:
                  Spacing.pagePadding + MediaQuery.paddingOf(context).bottom,
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
}) {
  final id = binding.idOf(item);
  final subtitle = binding.subtitleOf(item);
  final trailing = binding.trailingOf?.call(item);
  return Padding(
    padding: const EdgeInsets.fromLTRB(
      Spacing.pagePadding,
      0,
      Spacing.pagePadding,
      Spacing.md,
    ),
    child: WorkspaceResourceTile(
      key: Key('workspace-resource-${section.name}-$id'),
      icon: _sectionIcon(section),
      title: binding.titleOf(item),
      subtitle: subtitle,
      trailing: trailing,
      selected: selectedId == id,
      onTap: () => context.push(section.routes.detailLocation(id)),
    ),
  );
}

/// Shared empty-collection placeholder, keyed `workspace-empty-<section>`.
Widget _emptyState(BuildContext context, WorkspaceSection section) {
  final l10n = AppLocalizations.of(context)!;
  return ConduitEmptyState(
    key: Key('workspace-empty-${section.name}'),
    icon: _sectionIcon(section),
    title: _sectionLabel(l10n, section),
    message: l10n.workspaceEmpty,
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

class _CollectionError extends StatelessWidget {
  const _CollectionError({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ConduitEmptyState(
      icon: Icons.error_outline,
      title: l10n.error,
      message: l10n.workspaceLoadFailed,
      action: ConduitButton(text: l10n.workspaceRetry, onPressed: onRetry),
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
                  ConduitButton(
                    key: const Key('workspace-edit-action'),
                    text: l10n.edit,
                    icon: Icons.edit_outlined,
                    onPressed: onEdit,
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
          orElse: () =>
              const WorkspaceCollectionState<WorkspaceKnowledgeSummary>(),
        );
    final view = (state.view == 'created' || state.view == 'shared')
        ? state.view
        : '';
    final notifier = ref.read(workspaceKnowledgeProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: _WorkspaceFilterMenu(
            menuKey: const Key('workspace-knowledge-view-filter'),
            currentValue: view,
            options: {
              '': l10n.workspaceKnowledgeViewAll,
              'created': l10n.workspaceKnowledgeViewCreated,
              'shared': l10n.workspaceKnowledgeViewShared,
            },
            onSelected: (view) =>
                _fireCollectionMutation(() => notifier.setView(view)),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: _WorkspaceFilterMenu(
            menuKey: const Key('workspace-knowledge-source-filter'),
            currentValue: state.source,
            options: {
              '': l10n.workspaceKnowledgeSourceAll,
              'local': l10n.workspaceKnowledgeSourceLocal,
              'external': l10n.workspaceKnowledgeSourceExternal,
            },
            onSelected: (source) =>
                _fireCollectionMutation(() => notifier.setSource(source)),
          ),
        ),
      ],
    );
  }
}

/// Inline value picker for the knowledge filter bar, presented as a native
/// adaptive menu. Wrapped in a [KeyedSubtree] because
/// [AdaptivePopupMenuButton.text] does not forward its own `key`; the subtree
/// keeps the stable test key on the trigger.
class _WorkspaceFilterMenu extends StatelessWidget {
  const _WorkspaceFilterMenu({
    required this.menuKey,
    required this.currentValue,
    required this.options,
    required this.onSelected,
  });

  final Key menuKey;
  final String currentValue;
  final Map<String, String> options;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final label = options[currentValue] ?? options.values.first;
    return KeyedSubtree(
      key: menuKey,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: AdaptivePopupMenuButton.text<String>(
          label: label,
          tint: context.conduitTheme.buttonPrimary,
          buttonStyle: PopupButtonStyle.bordered,
          items: [
            for (final entry in options.entries)
              AdaptivePopupMenuItem<String>(
                label: entry.value,
                value: entry.key,
              ),
          ],
          onSelected: (_, entry) => onSelected(entry.value ?? ''),
        ),
      ),
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
      child: ConduitBadge(
        key: const Key('workspace-knowledge-external-badge'),
        text: l10n.workspaceKnowledgeExternalBadge,
        isCompact: true,
        backgroundColor: theme.surfaceContainerHighest,
        textColor: theme.textSecondary,
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

String _sectionIosSymbol(WorkspaceSection section) {
  return switch (section) {
    WorkspaceSection.models => 'point.3.connected.trianglepath.dotted',
    WorkspaceSection.knowledge => 'books.vertical',
    WorkspaceSection.prompts => 'text.quote',
    WorkspaceSection.tools => 'wrench.and.screwdriver',
    WorkspaceSection.skills => 'sparkles',
  };
}
