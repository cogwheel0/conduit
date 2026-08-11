import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import '../../widgets/workspace_editor_fields.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelPromptSection extends StatelessWidget {
  const WorkspaceModelPromptSection({super.key, required this.model});

  final WorkspaceModelPromptSectionModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.workspaceModelSectionPrompt,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-system',
            controller: model.system,
            label: l10n.workspaceModelSystemPrompt,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            minLines: 3,
            maxLines: 10,
            onChanged: model.onTextChanged,
          ),
          _suggestionPrompts(context, l10n),
        ],
      ),
    );
  }

  Widget _suggestionPrompts(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceModelSuggestionPrompts, style: theme.label),
          const SizedBox(height: Spacing.xs),
          for (var index = 0; index < model.suggestionPrompts.length; index++)
            AdaptiveListTile(
              key: Key('workspace-model-suggestion-$index'),
              padding: EdgeInsets.zero,
              title: Text(model.suggestionPrompts[index]),
              trailing: model.readOnly
                  ? null
                  : IconButton(
                      tooltip: l10n.workspaceModelRemoveSuggestion,
                      icon: const Icon(Icons.close, size: IconSize.small),
                      onPressed: () => model.onRemoveSuggestion(index),
                    ),
            ),
          if (!model.readOnly)
            Align(
              alignment: Alignment.centerLeft,
              child: WorkspacePlainIconButton(
                buttonKey: const Key('workspace-model-suggestion-add'),
                onPressed: model.onAddSuggestion,
                icon: Icons.add,
                label: l10n.workspaceModelAddSuggestion,
              ),
            ),
        ],
      ),
    );
  }
}
