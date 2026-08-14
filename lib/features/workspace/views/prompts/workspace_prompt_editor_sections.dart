import 'package:material_ui/material_ui.dart';

import 'package:conduit/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit/features/workspace/models/workspace_common.dart';
import 'package:conduit/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit/features/workspace/models/workspace_resources.dart';
import 'package:conduit/features/workspace/widgets/workspace_access_grants.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_fields.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/utility_components.dart';

final class WorkspacePromptCoreFields extends StatelessWidget {
  const WorkspacePromptCoreFields({
    super.key,
    required this.isDetail,
    required this.readOnly,
    required this.commandError,
    required this.nameController,
    required this.commandController,
    required this.tags,
    required this.onNameChanged,
    required this.onCommandChanged,
    required this.onRemoveTag,
    required this.onAddTag,
  });

  final bool isDetail;
  final bool readOnly;
  final bool commandError;
  final TextEditingController nameController;
  final TextEditingController commandController;
  final List<String> tags;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<String> onCommandChanged;
  final ValueChanged<String> onRemoveTag;
  final VoidCallback onAddTag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isDetail)
          UtilityValueRow(
            key: const Key('workspace-prompt-name'),
            label: l10n.workspacePromptName,
            value: nameController.text,
          )
        else
          ConduitInput(
            key: const Key('workspace-prompt-name'),
            controller: nameController,
            label: l10n.workspacePromptName,
            enabled: !readOnly,
            onChanged: onNameChanged,
            textInputAction: TextInputAction.next,
          ),
        const SizedBox(height: Spacing.md),
        if (isDetail)
          UtilityValueRow(
            key: const Key('workspace-prompt-command'),
            label: l10n.workspacePromptCommand,
            value: WorkspacePromptCommand.display(commandController.text),
          )
        else
          WorkspaceLabeledField(
            helperText: l10n.workspacePromptCommandHint,
            child: ConduitInput(
              key: const Key('workspace-prompt-command'),
              controller: commandController,
              label: l10n.workspacePromptCommand,
              enabled: !readOnly,
              onChanged: onCommandChanged,
              errorText: commandError
                  ? l10n.workspacePromptCommandInvalid
                  : null,
              prefixIcon: Padding(
                padding: const EdgeInsets.only(
                  left: Spacing.md,
                  right: Spacing.xs,
                ),
                child: Text(
                  '/',
                  style: AppTypography.standard.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: Spacing.md),
        Text(l10n.workspacePromptTags, style: theme.label),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final tag in tags)
              InputChip(
                key: Key('workspace-prompt-tag-$tag'),
                label: Text(tag),
                onDeleted: readOnly
                    ? null
                    : () {
                        ConduitHaptics.selectionClick();
                        onRemoveTag(tag);
                      },
              ),
            if (!readOnly)
              ActionChip(
                key: const Key('workspace-prompt-tag-add'),
                avatar: const Icon(Icons.add, size: IconSize.small),
                label: Text(l10n.workspacePromptTagAdd),
                onPressed: onAddTag,
              ),
          ],
        ),
      ],
    );
  }
}

final class WorkspacePromptContentEditor extends StatelessWidget {
  const WorkspacePromptContentEditor({
    super.key,
    required this.isDetail,
    required this.readOnly,
    required this.previewMode,
    required this.controller,
    required this.onPreviewModeChanged,
    required this.onContentChanged,
  });

  final bool isDetail;
  final bool readOnly;
  final bool previewMode;
  final TextEditingController controller;
  final ValueChanged<bool> onPreviewModeChanged;
  final VoidCallback onContentChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    if (isDetail) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspacePromptContent, style: theme.headingSmall),
          const SizedBox(height: Spacing.sm),
          _PromptPreview(controller: controller),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.workspacePromptContent,
                style: theme.headingSmall,
              ),
            ),
            // Native segmented controls need a finite width on iOS 26.
            SizedBox(
              width: 200,
              child: AdaptiveSegmentedControl(
                key: const Key('workspace-prompt-preview-toggle'),
                shrinkWrap: true,
                labels: [
                  l10n.workspacePromptWriteTab,
                  l10n.workspacePromptPreviewTab,
                ],
                selectedIndex: previewMode ? 1 : 0,
                onValueChanged: (index) => onPreviewModeChanged(index == 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        if (previewMode)
          _PromptPreview(controller: controller)
        else
          AdaptiveTextField(
            key: const Key('workspace-prompt-content'),
            controller: controller,
            enabled: !readOnly,
            minLines: 6,
            maxLines: 20,
            onChanged: (_) => onContentChanged(),
            style: theme.code?.copyWith(color: theme.textPrimary),
            placeholder: l10n.workspacePromptContentHint,
          ),
      ],
    );
  }
}

final class WorkspacePromptVersionSection extends StatelessWidget {
  const WorkspacePromptVersionSection({
    super.key,
    required this.readOnly,
    required this.expanded,
    required this.isProduction,
    required this.commitController,
    required this.onExpandedChanged,
    required this.onCommitChanged,
    required this.onProductionChanged,
  });

  final bool readOnly;
  final bool expanded;
  final bool isProduction;
  final TextEditingController commitController;
  final ValueChanged<bool> onExpandedChanged;
  final VoidCallback onCommitChanged;
  final ValueChanged<bool> onProductionChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return UtilityDisclosureSection(
      key: const Key('workspace-prompt-version-disclosure'),
      title: l10n.workspacePromptVersionSection,
      expanded: expanded,
      onChanged: onExpandedChanged,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConduitInput(
            key: const Key('workspace-prompt-commit-message'),
            controller: commitController,
            label: l10n.workspacePromptCommitMessage,
            hint: l10n.workspacePromptCommitMessageHint,
            enabled: !readOnly,
            onChanged: (_) => onCommitChanged(),
          ),
          const SizedBox(height: Spacing.xs),
          AdaptiveListTile(
            key: const Key('workspace-prompt-production-toggle'),
            padding: EdgeInsets.zero,
            title: Text(l10n.workspacePromptSetProduction),
            subtitle: Text(l10n.workspacePromptSetProductionSubtitle),
            trailing: AdaptiveSwitch(
              value: isProduction,
              onChanged: readOnly ? null : onProductionChanged,
            ),
          ),
        ],
      ),
    );
  }
}

final class WorkspacePromptAccessTile extends StatelessWidget {
  const WorkspacePromptAccessTile({
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
      key: const Key('workspace-prompt-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspacePromptManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(principals.length),
      onTap: onTap,
    );
  }
}

final class _PromptPreview extends StatelessWidget {
  const _PromptPreview({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final content = controller.text.trim();
    return Container(
      key: const Key('workspace-prompt-preview'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.medium),
        border: Border.all(color: theme.dividerColor),
      ),
      child: content.isEmpty
          ? Text(
              l10n.workspacePromptPreviewEmpty,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            )
          : ConduitMarkdownWidget(data: content),
    );
  }
}

List<WorkspaceEditorAction> buildWorkspacePromptActions({
  required AppLocalizations l10n,
  required WorkspaceCapabilities capabilities,
  required bool isCreate,
  required bool isEdit,
  required bool canWrite,
  required WorkspacePromptSummary? summary,
  required VoidCallback onImport,
  required VoidCallback onExport,
  required VoidCallback onClone,
  required VoidCallback onUpdateDetails,
  required VoidCallback onToggleActive,
  required VoidCallback onManageAccess,
  required VoidCallback onDelete,
}) {
  if (isCreate) {
    return [
      if (capabilities.prompts.importItems)
        WorkspaceEditorAction(
          label: l10n.workspacePromptImport,
          icon: Icons.upload_file_outlined,
          menuKey: const Key('workspace-prompt-action-import'),
          onSelected: onImport,
        ),
      if (capabilities.prompts.exportItems)
        WorkspaceEditorAction(
          label: l10n.workspacePromptExport,
          icon: Icons.download_outlined,
          menuKey: const Key('workspace-prompt-action-export'),
          onSelected: onExport,
        ),
    ];
  }
  if (summary == null) return const [];
  return [
    if (canWrite)
      WorkspaceEditorAction(
        label: l10n.workspacePromptClone,
        icon: Icons.copy_outlined,
        menuKey: const Key('workspace-prompt-action-clone'),
        onSelected: onClone,
      ),
    if (canWrite && isEdit)
      WorkspaceEditorAction(
        label: l10n.workspacePromptUpdateDetails,
        icon: Icons.drive_file_rename_outline,
        menuKey: const Key('workspace-prompt-action-update-details'),
        onSelected: onUpdateDetails,
      ),
    if (canWrite)
      WorkspaceEditorAction(
        label: summary.isActive
            ? l10n.workspacePromptDeactivate
            : l10n.workspacePromptActivate,
        icon: summary.isActive
            ? Icons.toggle_on_outlined
            : Icons.toggle_off_outlined,
        menuKey: const Key('workspace-prompt-action-toggle'),
        onSelected: onToggleActive,
      ),
    WorkspaceEditorAction(
      label: l10n.workspacePromptManageAccess,
      icon: Icons.group_outlined,
      menuKey: const Key('workspace-prompt-action-access'),
      onSelected: onManageAccess,
    ),
    if (capabilities.prompts.exportItems)
      WorkspaceEditorAction(
        label: l10n.workspacePromptExport,
        icon: Icons.download_outlined,
        menuKey: const Key('workspace-prompt-action-export'),
        onSelected: onExport,
      ),
    if (canWrite)
      WorkspaceEditorAction(
        label: l10n.workspacePromptDelete,
        icon: Icons.delete_outline,
        isDestructive: true,
        menuKey: const Key('workspace-prompt-action-delete'),
        onSelected: onDelete,
      ),
  ];
}
