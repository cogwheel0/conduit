import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../widgets/workspace_access_grants.dart';
import '../../widgets/workspace_tiles.dart';
import 'workspace_model_editor_controller.dart';

final class WorkspaceModelRelationshipsSection extends StatelessWidget {
  const WorkspaceModelRelationshipsSection({
    super.key,
    required this.controller,
    required this.onPick,
    required this.onManageAccess,
  });

  final WorkspaceModelEditorController controller;
  final ValueChanged<WorkspaceModelRelationshipKind> onPick;
  final VoidCallback onManageAccess;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspaceSectionHeader(title: l10n.workspaceModelSectionRelationships),
        _relationshipTile(
          context,
          keyId: 'workspace-model-knowledge',
          label: l10n.workspaceModelKnowledge,
          count: _count(WorkspaceModelRelationshipKind.knowledge),
          onTap: _picker(WorkspaceModelRelationshipKind.knowledge),
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-tools',
          label: l10n.workspaceModelTools,
          count: _count(WorkspaceModelRelationshipKind.tools),
          onTap: _picker(WorkspaceModelRelationshipKind.tools),
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-skills',
          label: l10n.workspaceModelSkills,
          count: _count(WorkspaceModelRelationshipKind.skills),
          onTap: _picker(WorkspaceModelRelationshipKind.skills),
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-filters',
          label: l10n.workspaceModelFilters,
          count: _count(WorkspaceModelRelationshipKind.filters),
          onTap: _picker(WorkspaceModelRelationshipKind.filters),
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-default-filters',
          label: l10n.workspaceModelDefaultFilters,
          count: _count(WorkspaceModelRelationshipKind.defaultFilters),
          onTap: _picker(WorkspaceModelRelationshipKind.defaultFilters),
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-actions',
          label: l10n.workspaceModelActions,
          count: _count(WorkspaceModelRelationshipKind.actions),
          onTap: _picker(WorkspaceModelRelationshipKind.actions),
        ),
        const SizedBox(height: Spacing.xl),
        WorkspaceSectionHeader(title: l10n.workspaceModelSectionAccess),
        _accessTile(l10n),
      ],
    );
  }

  int _count(WorkspaceModelRelationshipKind kind) =>
      controller.relationshipCounts[kind] ?? 0;

  VoidCallback? _picker(WorkspaceModelRelationshipKind kind) =>
      controller.readOnly ? null : () => onPick(kind);

  Widget _relationshipTile(
    BuildContext context, {
    required String keyId,
    required String label,
    required int count,
    VoidCallback? onTap,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: WorkspaceResourceTile(
        key: Key(keyId),
        icon: Icons.account_tree_outlined,
        title: label,
        subtitle: count == 0
            ? l10n.workspaceModelSelectNone
            : l10n.workspaceModelSelectCount(count),
        onTap: onTap,
      ),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final accessGrants = controller.draft.normalizedAccessGrants;
    final isPublic = workspaceGrantsArePublic(accessGrants);
    return WorkspaceResourceTile(
      key: const Key('workspace-model-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspaceModelManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(
              workspaceSharedPrincipals(accessGrants).length,
            ),
      onTap: onManageAccess,
    );
  }
}
