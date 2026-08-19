import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/conduit_components.dart';
import '../../widgets/workspace_editor_fields.dart';
import 'workspace_model_editor_controller.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelPromptSection extends StatelessWidget {
  const WorkspaceModelPromptSection({
    super.key,
    required this.controller,
    required this.onAddSuggestion,
  });

  final WorkspaceModelEditorController controller;
  final VoidCallback onAddSuggestion;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return WorkspaceEditorFieldGroup(
      title: l10n.workspaceModelSectionPrompt,
      androidGap: Spacing.sm,
      children: [
        WorkspaceModelEditorField(
          fieldKey: 'workspace-model-system',
          controller: controller.fields.system,
          label: l10n.workspaceModelSystemPrompt,
          isDetail: controller.session.isDetail,
          enabled: !controller.readOnly,
          minLines: 3,
          maxLines: 10,
          onChanged: controller.markDirty,
        ),
        _suggestionPrompts(context, l10n),
      ],
    );
  }

  Widget _suggestionPrompts(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Padding(
      padding: context.usesCupertinoChrome
          ? const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            )
          : EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.workspaceModelSuggestionPrompts,
            style: theme.label,
          ),
          const SizedBox(height: Spacing.xs),
          for (
            var index = 0;
            index < controller.draft.suggestionPrompts.length;
            index++
          )
            AdaptiveListTile(
              key: Key('workspace-model-suggestion-$index'),
              padding: EdgeInsets.zero,
              title: Text(controller.draft.suggestionPrompts[index]),
              trailing: controller.readOnly
                  ? null
                  : ConduitIconButton(
                      tooltip: l10n.workspaceModelRemoveSuggestion,
                      icon: Icons.close,
                      onPressed: () => controller.removeSuggestion(index),
                      isCompact: true,
                    ),
            ),
          if (!controller.readOnly)
            Align(
              alignment: Alignment.centerLeft,
              child: WorkspacePlainIconButton(
                buttonKey: const Key('workspace-model-suggestion-add'),
                onPressed: onAddSuggestion,
                icon: Icons.add,
                label: l10n.workspaceModelAddSuggestion,
              ),
            ),
        ],
      ),
    );
  }
}
