part of 'workspace_page.dart';

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
        onEdit: () => context.pushWorkspace(section.routes.editLocation(id)),
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

/// Inline value picker for the Knowledge filter bar. iOS presents the shared
/// native action sheet; other platforms keep the anchored adaptive menu.
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
    final textStyle =
        context.conduitTheme.bodyMedium ??
        Theme.of(context).textTheme.bodyMedium ??
        const TextStyle();
    final height = 32 * conduitSystemControlScaleOf(context);
    final trigger = DecoratedBox(
      decoration: BoxDecoration(
        color: context.conduitTheme.surfaceContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            ConduitSystemAdaptiveIcon(
              PlatformInfo.isIOS
                  ? CupertinoIcons.chevron_down
                  : Icons.keyboard_arrow_down_rounded,
              size: IconSize.small,
              color: context.conduitTheme.iconSecondary,
            ),
          ],
        ),
      ),
    );
    return SizedBox(
      key: menuKey,
      height: height,
      child: AdaptiveSingleChoiceTrigger<String>(
        value: currentValue,
        options: [
          for (final entry in options.entries)
            AdaptiveDropdownOption(value: entry.key, label: entry.value),
        ],
        onChanged: onSelected,
        semanticLabel: label,
        child: trigger,
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
