import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import '../../widgets/workspace_editor_fields.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelPromptSection extends StatelessWidget {
  const WorkspaceModelPromptSection({
    super.key,
    required this.state,
    required this.intents,
  });

  final WorkspaceModelEditorViewState state;
  final WorkspaceModelEditorIntents intents;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.workspaceModelSectionPrompt,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-system',
            controller: state.fields.system,
            label: l10n.workspaceModelSystemPrompt,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            minLines: 3,
            maxLines: 10,
            onChanged: intents.onChanged,
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
          for (
            var index = 0;
            index < state.draft.suggestionPrompts.length;
            index++
          )
            AdaptiveListTile(
              key: Key('workspace-model-suggestion-$index'),
              padding: EdgeInsets.zero,
              title: Text(state.draft.suggestionPrompts[index]),
              trailing: state.readOnly
                  ? null
                  : IconButton(
                      tooltip: l10n.workspaceModelRemoveSuggestion,
                      icon: const Icon(Icons.close, size: IconSize.small),
                      onPressed: () => intents.onMutate(
                        () => state.draft.suggestionPrompts.removeAt(index),
                      ),
                    ),
            ),
          if (!state.readOnly)
            Align(
              alignment: Alignment.centerLeft,
              child: WorkspacePlainIconButton(
                buttonKey: const Key('workspace-model-suggestion-add'),
                onPressed: intents.onAddSuggestion,
                icon: Icons.add,
                label: l10n.workspaceModelAddSuggestion,
              ),
            ),
        ],
      ),
    );
  }
}
