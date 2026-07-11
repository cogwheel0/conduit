import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit/features/workspace/providers/workspace_providers.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';
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

    return AdaptiveRouteShell(
      backgroundColor: theme.surfaceBackground,
      appBar: AdaptiveAppBar(
        title: '${l10n.workspaceTitle} · ${_sectionLabel(l10n, section)}',
      ),
      body: Material(
        color: Colors.transparent,
        child: SafeArea(
          top: false,
          child: wide
              ? _buildWide(context, permitted)
              : _buildCompact(context, permitted),
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, List<WorkspaceSection> permitted) {
    return Column(
      children: [
        _WorkspaceSectionTabs(selected: section, permitted: permitted),
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

class _WorkspaceSectionTabs extends StatelessWidget {
  const _WorkspaceSectionTabs({
    required this.selected,
    required this.permitted,
  });

  final WorkspaceSection selected;
  final List<WorkspaceSection> permitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      label: l10n.workspaceTitle,
      child: SizedBox(
        height: 52,
        child: ListView.separated(
          key: const Key('workspace-section-tabs'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          itemCount: permitted.length,
          separatorBuilder: (_, _) => const SizedBox(width: Spacing.xs),
          itemBuilder: (context, index) {
            final item = permitted[index];
            return ChoiceChip(
              key: Key('workspace-tab-${item.name}'),
              selected: item == selected,
              label: Text(_sectionLabel(l10n, item)),
              onSelected: (_) => context.go(item.path),
            );
          },
        ),
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

class _WorkspaceCollectionPanel extends ConsumerWidget {
  const _WorkspaceCollectionPanel({required this.section, this.selectedId});

  final WorkspaceSection section;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (section) {
      WorkspaceSection.models => _buildCollection<WorkspaceModelSummary>(
        context,
        value: ref.watch(workspaceModelsProvider),
        idOf: (item) => item.id,
        titleOf: (item) => item.name,
        subtitleOf: (item) => item.baseModelId,
        onRefresh: ref.read(workspaceModelsProvider.notifier).refresh,
        onLoadMore: ref.read(workspaceModelsProvider.notifier).loadMore,
        onSearch: ref.read(workspaceModelsProvider.notifier).setQuery,
      ),
      WorkspaceSection.knowledge => _buildCollection<WorkspaceKnowledgeSummary>(
        context,
        value: ref.watch(workspaceKnowledgeProvider),
        idOf: (item) => item.id,
        titleOf: (item) => item.name,
        subtitleOf: (item) => item.description,
        onRefresh: ref.read(workspaceKnowledgeProvider.notifier).refresh,
        onLoadMore: ref.read(workspaceKnowledgeProvider.notifier).loadMore,
        onSearch: ref.read(workspaceKnowledgeProvider.notifier).setQuery,
      ),
      WorkspaceSection.prompts => _buildCollection<WorkspacePromptSummary>(
        context,
        value: ref.watch(workspacePromptsProvider),
        idOf: (item) => item.id,
        titleOf: (item) => item.name,
        subtitleOf: (item) => item.command,
        onRefresh: ref.read(workspacePromptsProvider.notifier).refresh,
        onLoadMore: ref.read(workspacePromptsProvider.notifier).loadMore,
        onSearch: ref.read(workspacePromptsProvider.notifier).setQuery,
      ),
      WorkspaceSection.tools => _buildCollection<WorkspaceToolSummary>(
        context,
        value: ref.watch(workspaceToolsProvider),
        idOf: (item) => item.id,
        titleOf: (item) => item.name,
        subtitleOf: (item) => item.meta['description']?.toString(),
        onRefresh: ref.read(workspaceToolsProvider.notifier).refresh,
        onLoadMore: ref.read(workspaceToolsProvider.notifier).loadMore,
        onSearch: ref.read(workspaceToolsProvider.notifier).setQuery,
      ),
      WorkspaceSection.skills => _buildCollection<WorkspaceSkillSummary>(
        context,
        value: ref.watch(workspaceSkillsProvider),
        idOf: (item) => item.id,
        titleOf: (item) => item.name,
        subtitleOf: (item) => item.description,
        onRefresh: ref.read(workspaceSkillsProvider.notifier).refresh,
        onLoadMore: ref.read(workspaceSkillsProvider.notifier).loadMore,
        onSearch: ref.read(workspaceSkillsProvider.notifier).setQuery,
      ),
    };
  }

  Widget _buildCollection<T>(
    BuildContext context, {
    required AsyncValue<WorkspaceCollectionState<T>> value,
    required String Function(T) idOf,
    required String Function(T) titleOf,
    required String? Function(T) subtitleOf,
    required Future<void> Function() onRefresh,
    required Future<void> Function() onLoadMore,
    required Future<void> Function(String) onSearch,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return value.when(
      loading: () =>
          Center(child: ConduitLoading.primary(message: l10n.loadingShort)),
      error: (_, _) => _CollectionError(onRetry: onRefresh),
      data: (collection) {
        if (collection.error != null && collection.items.isEmpty) {
          return _CollectionError(onRetry: onRefresh);
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: Key('workspace-search-${section.name}'),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: l10n.workspaceSearchHint,
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                      ),
                      onSubmitted: onSearch,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  IconButton(
                    key: Key('workspace-create-${section.name}'),
                    tooltip: l10n.workspaceCreate,
                    onPressed: () => context.push(section.routes.createPattern),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            if (collection.isLoading)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: collection.items.isEmpty
                  ? Center(
                      key: Key('workspace-empty-${section.name}'),
                      child: Text(
                        l10n.workspaceEmpty,
                        style: theme.bodyMedium?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: onRefresh,
                      child: ListView.builder(
                        key: Key('workspace-list-${section.name}'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount:
                            collection.items.length +
                            (collection.hasMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == collection.items.length) {
                            return Padding(
                              padding: const EdgeInsets.all(Spacing.md),
                              child: Center(
                                child: collection.isLoadingMore
                                    ? ConduitLoading.inline(context: context)
                                    : TextButton(
                                        onPressed: onLoadMore,
                                        child: Text(l10n.workspaceLoadMore),
                                      ),
                              ),
                            );
                          }
                          final item = collection.items[index];
                          final id = idOf(item);
                          final subtitle = subtitleOf(item);
                          return ListTile(
                            key: Key('workspace-item-${section.name}-$id'),
                            selected: selectedId == id,
                            title: Text(titleOf(item)),
                            subtitle: subtitle == null || subtitle.isEmpty
                                ? null
                                : Text(
                                    subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                context.push(section.routes.detailLocation(id)),
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
