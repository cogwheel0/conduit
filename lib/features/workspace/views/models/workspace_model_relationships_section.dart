import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../widgets/workspace_access_grants.dart';
import '../../widgets/workspace_tiles.dart';
import 'workspace_model_editor_contract.dart';

final class WorkspaceModelRelationshipsSection extends StatelessWidget {
  const WorkspaceModelRelationshipsSection({
    super.key,
    required this.state,
    required this.intents,
  });

  final WorkspaceModelEditorViewState state;
  final WorkspaceModelEditorIntents intents;

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
          count: state.draft.knowledge.length,
          onTap: state.readOnly ? null : intents.onPickKnowledge,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-tools',
          label: l10n.workspaceModelTools,
          count: state.draft.toolIds.length,
          onTap: state.readOnly ? null : intents.onPickTools,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-skills',
          label: l10n.workspaceModelSkills,
          count: state.draft.skillIds.length,
          onTap: state.readOnly ? null : intents.onPickSkills,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-filters',
          label: l10n.workspaceModelFilters,
          count: state.draft.filterIds.length,
          onTap: state.readOnly ? null : intents.onPickFilters,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-default-filters',
          label: l10n.workspaceModelDefaultFilters,
          count: state.draft.defaultFilterIds.length,
          onTap: state.readOnly ? null : intents.onPickDefaultFilters,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-actions',
          label: l10n.workspaceModelActions,
          count: state.draft.actionIds.length,
          onTap: state.readOnly ? null : intents.onPickActions,
        ),
        const SizedBox(height: Spacing.xl),
        WorkspaceSectionHeader(title: l10n.workspaceModelSectionAccess),
        _accessTile(l10n),
      ],
    );
  }

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
    final principals = workspaceSharedPrincipals(
      state.draft.normalizedAccessGrants,
    );
    final isPublic = workspaceGrantsArePublic(
      state.draft.normalizedAccessGrants,
    );
    return WorkspaceResourceTile(
      key: const Key('workspace-model-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspaceModelManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(principals.length),
      onTap: intents.onManageAccess,
    );
  }
}
