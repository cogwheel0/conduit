import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelBasicsSection extends StatelessWidget {
  const WorkspaceModelBasicsSection({
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
      title: l10n.workspaceModelSectionBasics,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-id',
            controller: state.fields.id,
            label: l10n.workspaceModelIdLabel,
            isDetail: state.isDetail,
            enabled: !state.readOnly && state.isCreate,
            onChanged: intents.onChanged,
          ),
          _baseModelSelector(context, l10n),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-name',
            controller: state.fields.name,
            label: l10n.workspaceModelName,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            onChanged: intents.onChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-description',
            controller: state.fields.description,
            label: l10n.workspaceModelDescription,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            minLines: 2,
            maxLines: 4,
            onChanged: intents.onChanged,
          ),
          _tagsField(context, l10n),
        ],
      ),
    );
  }

  Widget _baseModelSelector(BuildContext context, AppLocalizations l10n) {
    final selectedId = state.draft.baseModelId;
    if (state.isDetail) {
      return UtilityValueRow(
        key: const Key('workspace-model-base'),
        label: l10n.workspaceModelBaseModel,
        value: selectedId ?? l10n.workspaceModelBaseModelNone,
      );
    }
    final hasSelectedOption =
        selectedId == null ||
        state.baseModels.any((model) => model.id == selectedId);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: DropdownButtonFormField<String?>(
        key: const Key('workspace-model-base'),
        initialValue: selectedId,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.workspaceModelBaseModel,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(l10n.workspaceModelBaseModelNone),
          ),
          if (!hasSelectedOption)
            DropdownMenuItem<String?>(
              value: selectedId,
              child: Text(selectedId, overflow: TextOverflow.ellipsis),
            ),
          for (final model in state.baseModels)
            DropdownMenuItem<String?>(
              value: model.id,
              child: Text(model.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: state.readOnly
            ? null
            : (value) =>
                  intents.onMutate(() => state.draft.baseModelId = value),
      ),
    );
  }

  Widget _tagsField(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceModelTags, style: theme.label),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final tag in state.draft.tags)
                InputChip(
                  key: Key('workspace-model-tag-$tag'),
                  label: Text(tag),
                  onDeleted: state.readOnly
                      ? null
                      : () => intents.onMutate(
                          () => state.draft.tags.remove(tag),
                        ),
                ),
              if (!state.readOnly)
                ActionChip(
                  key: const Key('workspace-model-tag-add'),
                  avatar: const Icon(Icons.add, size: IconSize.small),
                  label: Text(l10n.workspaceModelTagsHint),
                  onPressed: intents.onAddTag,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
