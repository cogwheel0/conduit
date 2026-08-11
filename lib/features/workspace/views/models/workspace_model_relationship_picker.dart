import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/debug_logger.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../models/workspace_model_draft.dart';
import '../../providers/workspace_model_relationships.dart';
import '../../providers/workspace_providers.dart';
import 'workspace_model_relationship_sheet.dart';

/// Coordinates relationship loading and selection for a model draft.
final class WorkspaceModelRelationshipPicker {
  const WorkspaceModelRelationshipPicker({
    required this.context,
    required this.ref,
    required this.l10n,
    required this.draft,
    required this.onMutate,
  });

  final BuildContext context;
  final WidgetRef ref;
  final AppLocalizations l10n;
  final WorkspaceModelDraft draft;
  final void Function(VoidCallback mutation) onMutate;

  Future<void> pickKnowledge() async {
    final List<WorkspaceRelationshipOption> options;
    try {
      options = await ref
          .read(workspaceKnowledgeProvider.future)
          .then(
            (state) => state.items
                .map(
                  (item) => WorkspaceRelationshipOption(
                    id: item.id,
                    label: item.name,
                    subtitle: item.description,
                  ),
                )
                .toList(),
          );
    } catch (error, stackTrace) {
      _reportLoadFailure('knowledge', error, stackTrace);
      return;
    }
    if (!context.mounted) return;
    final selected = await WorkspaceRelationshipSheet.show(
      context,
      title: l10n.workspaceModelKnowledge,
      options: options,
      selectedIds: draft.knowledge.map((item) => item.id).toList(),
    );
    if (selected == null) return;
    onMutate(() {
      draft.knowledge = [
        for (final id in selected)
          draft.knowledge.firstWhere(
            (item) => item.id == id,
            orElse: () => WorkspaceModelKnowledgeRef(
              id: id,
              name: options
                  .firstWhere(
                    (option) => option.id == id,
                    orElse: () =>
                        WorkspaceRelationshipOption(id: id, label: id),
                  )
                  .label,
            ),
          ),
      ];
    });
  }

  Future<void> pickTools() async {
    final List<WorkspaceRelationshipOption> options;
    try {
      options = await ref
          .read(workspaceToolsProvider.future)
          .then(
            (state) => state.items
                .map(
                  (tool) => WorkspaceRelationshipOption(
                    id: tool.id,
                    label: tool.name,
                  ),
                )
                .toList(),
          );
    } catch (error, stackTrace) {
      _reportLoadFailure('tools', error, stackTrace);
      return;
    }
    await _pickIds(
      title: l10n.workspaceModelTools,
      options: options,
      selectedIds: draft.toolIds,
      apply: (selected) => draft.toolIds = selected,
    );
  }

  Future<void> pickSkills() async {
    final List<WorkspaceRelationshipOption> options;
    try {
      options = await ref
          .read(workspaceSkillsProvider.future)
          .then(
            (state) => state.items
                .map(
                  (skill) => WorkspaceRelationshipOption(
                    id: skill.id,
                    label: skill.name,
                    subtitle: skill.description,
                  ),
                )
                .toList(),
          );
    } catch (error, stackTrace) {
      _reportLoadFailure('skills', error, stackTrace);
      return;
    }
    await _pickIds(
      title: l10n.workspaceModelSkills,
      options: options,
      selectedIds: draft.skillIds,
      apply: (selected) => draft.skillIds = selected,
    );
  }

  Future<void> pickFunctions({
    required bool isFilter,
    bool isDefault = false,
  }) async {
    final List<WorkspaceFunctionRef> functions;
    try {
      functions = await ref.read(workspaceFunctionsProvider.future);
    } catch (error, stackTrace) {
      _reportLoadFailure('functions', error, stackTrace);
      return;
    }
    final options = functions
        .where((item) => isFilter ? item.isFilter : item.isAction)
        .map(
          (item) => WorkspaceRelationshipOption(
            id: item.id,
            label: item.name,
            subtitle: item.type,
          ),
        )
        .toList();
    final selectedIds = isFilter
        ? (isDefault ? draft.defaultFilterIds : draft.filterIds)
        : draft.actionIds;
    final title = isFilter
        ? (isDefault
              ? l10n.workspaceModelDefaultFilters
              : l10n.workspaceModelFilters)
        : l10n.workspaceModelActions;
    await _pickIds(
      title: title,
      options: options,
      selectedIds: selectedIds,
      apply: (selected) {
        if (!isFilter) {
          draft.actionIds = selected;
        } else if (isDefault) {
          draft.defaultFilterIds = selected;
        } else {
          draft.filterIds = selected;
        }
      },
    );
  }

  Future<void> _pickIds({
    required String title,
    required List<WorkspaceRelationshipOption> options,
    required List<String> selectedIds,
    required ValueChanged<List<String>> apply,
  }) async {
    if (!context.mounted) return;
    final selected = await WorkspaceRelationshipSheet.show(
      context,
      title: title,
      options: options,
      selectedIds: selectedIds,
    );
    if (selected != null) onMutate(() => apply(selected));
  }

  void _reportLoadFailure(
    String relationship,
    Object error,
    StackTrace stackTrace,
  ) {
    DebugLogger.error(
      '$relationship relationship load failed',
      scope: 'workspace/models',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      AdaptiveSnackBar.show(
        context,
        message: l10n.workspaceLoadFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }
}
