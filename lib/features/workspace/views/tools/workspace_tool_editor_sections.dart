import 'package:flutter/material.dart';

import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_grouped_components.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

final class WorkspaceToolCoreFields extends StatelessWidget {
  const WorkspaceToolCoreFields({
    super.key,
    required this.isDetail,
    required this.fieldsReadOnly,
    required this.idReadOnly,
    required this.idError,
    required this.nameController,
    required this.idController,
    required this.descriptionController,
    required this.onNameChanged,
    required this.onIdChanged,
    required this.onDescriptionChanged,
  });

  final bool isDetail;
  final bool fieldsReadOnly;
  final bool idReadOnly;
  final bool idError;
  final TextEditingController nameController;
  final TextEditingController idController;
  final TextEditingController descriptionController;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onIdChanged;
  final VoidCallback onDescriptionChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isDetail)
          WorkspaceValueRow(
            key: const Key('workspace-tool-name'),
            label: l10n.workspaceToolName,
            value: nameController.text,
          )
        else
          ConduitInput(
            key: const Key('workspace-tool-name'),
            controller: nameController,
            label: l10n.workspaceToolName,
            hint: l10n.workspaceToolNameHint,
            enabled: !fieldsReadOnly,
            onChanged: onNameChanged,
            textInputAction: TextInputAction.next,
          ),
        const SizedBox(height: Spacing.md),
        if (isDetail)
          WorkspaceValueRow(
            key: const Key('workspace-tool-id'),
            label: l10n.workspaceToolId,
            value: idController.text,
          )
        else
          WorkspaceLabeledField(
            helperText: l10n.workspaceToolIdHint,
            child: ConduitInput(
              key: const Key('workspace-tool-id'),
              controller: idController,
              label: l10n.workspaceToolId,
              enabled: !idReadOnly,
              onChanged: onIdChanged,
              errorText: idError ? l10n.workspaceToolIdInvalid : null,
            ),
          ),
        const SizedBox(height: Spacing.md),
        if (isDetail)
          WorkspaceValueRow(
            key: const Key('workspace-tool-description'),
            label: l10n.workspaceToolDescription,
            value: descriptionController.text,
          )
        else
          ConduitInput(
            key: const Key('workspace-tool-description'),
            controller: descriptionController,
            label: l10n.workspaceToolDescription,
            hint: l10n.workspaceToolDescriptionHint,
            enabled: !fieldsReadOnly,
            onChanged: (_) => onDescriptionChanged(),
            textInputAction: TextInputAction.next,
          ),
      ],
    );
  }
}

final class WorkspaceToolContentEditor extends StatelessWidget {
  const WorkspaceToolContentEditor({
    super.key,
    required this.isDetail,
    required this.readOnly,
    required this.controller,
    required this.onChanged,
  });

  final bool isDetail;
  final bool readOnly;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.workspaceToolContent, style: theme.headingSmall),
        const SizedBox(height: Spacing.sm),
        if (isDetail)
          Container(
            key: const Key('workspace-tool-content'),
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 160),
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: theme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppBorderRadius.medium),
              border: Border.all(color: theme.dividerColor),
            ),
            child: SelectableText(
              controller.text,
              style: theme.code?.copyWith(color: theme.textPrimary),
            ),
          )
        else
          AdaptiveTextField(
            key: const Key('workspace-tool-content'),
            controller: controller,
            enabled: !readOnly,
            minLines: 12,
            maxLines: 32,
            onChanged: onChanged,
            style: theme.code?.copyWith(color: theme.textPrimary),
            placeholder: l10n.workspaceToolContentHint,
          ),
      ],
    );
  }
}

final class WorkspaceToolIncompatibilityBanner extends StatelessWidget {
  const WorkspaceToolIncompatibilityBanner({
    super.key,
    required this.requiredVersion,
    required this.currentServerVersion,
  });

  final String? requiredVersion;
  final String? currentServerVersion;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Container(
      key: const Key('workspace-tool-incompatible'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.errorBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
        border: Border.all(color: theme.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: IconSize.small,
            color: theme.error,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              l10n.workspaceToolIncompatible(
                requiredVersion ?? '0.0.0',
                currentServerVersion ?? '?',
              ),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ),
        ],
      ),
    );
  }
}

final class WorkspaceToolWarning extends StatelessWidget {
  const WorkspaceToolWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: IconSize.small,
          color: theme.textSecondary,
        ),
        const SizedBox(width: Spacing.xs),
        Expanded(
          child: Text(
            l10n.workspaceToolWarning,
            style: theme.caption?.copyWith(color: theme.textSecondary),
          ),
        ),
      ],
    );
  }
}

final class WorkspaceToolDetailsSummary extends StatelessWidget {
  const WorkspaceToolDetailsSummary({super.key, required this.summary});

  final WorkspaceToolSummary summary;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ToolManifestSummary(summary: summary),
        _ToolSpecsSummary(summary: summary),
      ],
    );
  }
}

final class WorkspaceToolAccessTile extends StatelessWidget {
  const WorkspaceToolAccessTile({
    super.key,
    required this.grants,
    required this.onTap,
  });

  final List<WorkspaceAccessGrantInput> grants;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final principals = workspaceSharedPrincipals(grants);
    final isPublic = workspaceGrantsArePublic(grants);
    return WorkspaceResourceTile(
      key: const Key('workspace-tool-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspaceToolManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(principals.length),
      onTap: onTap,
    );
  }
}

final class _ToolManifestSummary extends StatelessWidget {
  const _ToolManifestSummary({required this.summary});

  final WorkspaceToolSummary summary;

  @override
  Widget build(BuildContext context) {
    final manifest = workspaceJsonMap(summary.meta['manifest']);
    if (manifest.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final version = manifest['version']?.toString();
    final requiredVersion = manifest['required_open_webui_version']?.toString();
    final fundingUrl = manifest['funding_url']?.toString();
    return Padding(
      key: const Key('workspace-tool-manifest'),
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceToolManifest, style: theme.headingSmall),
          const SizedBox(height: Spacing.sm),
          if (version != null && version.isNotEmpty)
            Text(
              l10n.workspaceToolManifestVersion(version),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (requiredVersion != null && requiredVersion.isNotEmpty)
            Text(
              l10n.workspaceToolManifestRequiredVersion(requiredVersion),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          if (fundingUrl != null && fundingUrl.isNotEmpty)
            Text(
              l10n.workspaceToolManifestFunding(fundingUrl),
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
        ],
      ),
    );
  }
}

final class _ToolSpecsSummary extends StatelessWidget {
  const _ToolSpecsSummary({required this.summary});

  final WorkspaceToolSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final specs = summary.specs;
    return Padding(
      key: const Key('workspace-tool-specs'),
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceToolSpecs, style: theme.headingSmall),
          const SizedBox(height: Spacing.sm),
          if (specs.isEmpty)
            Text(
              l10n.workspaceToolSpecsEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          else
            for (final spec in specs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spec['name']?.toString() ?? '',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.textPrimary,
                      ),
                    ),
                    if ((spec['description']?.toString() ?? '').isNotEmpty)
                      Text(
                        spec['description'].toString(),
                        style: theme.caption?.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

List<WorkspaceEditorAction> buildWorkspaceToolActions({
  required AppLocalizations l10n,
  required WorkspaceCapabilities capabilities,
  required bool isCreate,
  required bool isAdmin,
  required bool canWrite,
  required WorkspaceToolSummary? summary,
  required VoidCallback onImportJson,
  required VoidCallback onImportUrl,
  required VoidCallback onExport,
  required VoidCallback onClone,
  required VoidCallback onOpenValves,
  required VoidCallback onManageAccess,
  required VoidCallback onDelete,
}) {
  if (isCreate) {
    return [
      if (capabilities.tools.importItems)
        WorkspaceEditorAction(
          label: l10n.workspaceToolImportJson,
          icon: Icons.data_object_outlined,
          menuKey: const Key('workspace-tool-action-import-json'),
          onSelected: onImportJson,
        ),
      // URL import is admin-only, independent of tools_import permission.
      if (isAdmin)
        WorkspaceEditorAction(
          label: l10n.workspaceToolImportUrl,
          icon: Icons.link_outlined,
          menuKey: const Key('workspace-tool-action-import-url'),
          onSelected: onImportUrl,
        ),
      if (capabilities.tools.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspaceToolExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-tool-action-export'),
          onSelected: onExport,
        ),
    ];
  }
  if (summary == null) return const [];
  return [
    if (canWrite)
      WorkspaceEditorAction(
        label: l10n.workspaceToolClone,
        icon: Icons.copy_outlined,
        menuKey: const Key('workspace-tool-action-clone'),
        onSelected: onClone,
      ),
    if (canWrite)
      WorkspaceEditorAction(
        label: l10n.workspaceToolValves,
        icon: Icons.tune_outlined,
        menuKey: const Key('workspace-tool-action-valves'),
        onSelected: onOpenValves,
      ),
    WorkspaceEditorAction(
      label: l10n.workspaceToolManageAccess,
      icon: Icons.group_outlined,
      menuKey: const Key('workspace-tool-action-access'),
      onSelected: onManageAccess,
    ),
    if (capabilities.tools.exportItems)
      WorkspaceEditorAction(
        label: l10n.workspaceToolExport,
        icon: Icons.download_outlined,
        menuKey: const Key('workspace-tool-action-export'),
        onSelected: onExport,
      ),
    if (canWrite)
      WorkspaceEditorAction(
        label: l10n.workspaceToolDelete,
        icon: Icons.delete_outline,
        isDestructive: true,
        menuKey: const Key('workspace-tool-action-delete'),
        onSelected: onDelete,
      ),
  ];
}
