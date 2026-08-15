import 'package:material_ui/material_ui.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import '../../providers/workspace_model_relationships.dart';
import '../../widgets/workspace_editor_fields.dart';
import 'workspace_model_advanced_section.dart';
import 'workspace_model_avatar.dart';
import 'workspace_model_basics_section.dart';
import 'workspace_model_editor_controller.dart';
import 'workspace_model_prompt_section.dart';
import 'workspace_model_relationships_section.dart';

/// Owns model-form presentation composition from one behavioral controller.
final class WorkspaceModelEditorBody extends StatelessWidget {
  const WorkspaceModelEditorBody({
    super.key,
    required this.controller,
    required this.baseModels,
    required this.onPickImage,
    required this.onAddTag,
    required this.onAddSuggestion,
    required this.onPickRelationship,
    required this.onManageAccess,
  });

  final WorkspaceModelEditorController controller;
  final List<WorkspaceRelationshipOption> baseModels;
  final VoidCallback onPickImage;
  final VoidCallback onAddTag;
  final VoidCallback onAddSuggestion;
  final ValueChanged<WorkspaceModelRelationshipKind> onPickRelationship;
  final VoidCallback onManageAccess;

  @override
  Widget build(BuildContext context) {
    final sectionGap = WorkspaceEditorMetrics.sectionGap(context);
    return ListView(
      key: const Key('workspace-model-editor-body'),
      padding: WorkspaceEditorMetrics.bodyPadding(context),
      children: [
        _profileImage(context),
        SizedBox(height: sectionGap),
        WorkspaceModelBasicsSection(
          controller: controller,
          baseModels: baseModels,
          onAddTag: onAddTag,
        ),
        SizedBox(height: sectionGap),
        WorkspaceModelPromptSection(
          controller: controller,
          onAddSuggestion: onAddSuggestion,
        ),
        SizedBox(height: sectionGap),
        WorkspaceModelAdvancedSection(controller: controller),
        SizedBox(height: sectionGap),
        WorkspaceModelRelationshipsSection(
          controller: controller,
          onPick: onPickRelationship,
          onManageAccess: onManageAccess,
        ),
        SizedBox(height: sectionGap),
      ],
    );
  }

  Widget _profileImage(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final content = Row(
      children: [
        WorkspaceModelAvatar(
          draftImage: controller.draft.profileImageUrl,
          modelId: controller.draft.id,
          removed: controller.avatarRemoved,
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.workspaceModelProfileImage,
                style: context.usesCupertinoChrome
                    ? AppTypography.bodyMediumStyle.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w400,
                      )
                    : theme.label,
              ),
              const SizedBox(height: Spacing.xs),
              if (!controller.readOnly)
                Wrap(
                  spacing: Spacing.sm,
                  children: [
                    WorkspacePlainIconButton(
                      buttonKey: const Key('workspace-model-image-pick'),
                      onPressed: onPickImage,
                      icon: Icons.image_outlined,
                      label: l10n.workspaceModelChangeImage,
                    ),
                    if (controller.draft.profileImageUrl != null)
                      WorkspacePlainIconButton(
                        buttonKey: const Key('workspace-model-image-remove'),
                        onPressed: controller.removeAvatar,
                        icon: Icons.close,
                        label: l10n.workspaceModelRemoveImage,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
    if (!context.usesCupertinoChrome) return content;
    return InsetGroupedSection(
      useNativeSurface: true,
      padding: const EdgeInsets.all(Spacing.md),
      child: content,
    );
  }
}
