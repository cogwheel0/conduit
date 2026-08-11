import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelBasicsSection extends StatelessWidget {
  const WorkspaceModelBasicsSection({super.key, required this.model});

  final WorkspaceModelBasicsSectionModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.workspaceModelSectionBasics,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-id',
            controller: model.id,
            label: l10n.workspaceModelIdLabel,
            isDetail: model.isDetail,
            enabled: !model.readOnly && model.isCreate,
            onChanged: model.onTextChanged,
          ),
          _baseModelSelector(context, l10n),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-name',
            controller: model.name,
            label: l10n.workspaceModelName,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            onChanged: model.onTextChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-description',
            controller: model.description,
            label: l10n.workspaceModelDescription,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            minLines: 2,
            maxLines: 4,
            onChanged: model.onTextChanged,
          ),
          _tagsField(context, l10n),
        ],
      ),
    );
  }

  Widget _baseModelSelector(BuildContext context, AppLocalizations l10n) {
    final selectedId = model.baseModelId;
    if (model.isDetail) {
      return UtilityValueRow(
        key: const Key('workspace-model-base'),
        label: l10n.workspaceModelBaseModel,
        value: selectedId ?? l10n.workspaceModelBaseModelNone,
      );
    }
    final hasSelectedOption =
        selectedId == null ||
        model.baseModels.any((option) => option.id == selectedId);
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
          for (final option in model.baseModels)
            DropdownMenuItem<String?>(
              value: option.id,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: model.readOnly ? null : model.onBaseModelChanged,
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
              for (final tag in model.tags)
                InputChip(
                  key: Key('workspace-model-tag-$tag'),
                  label: Text(tag),
                  onDeleted: model.readOnly
                      ? null
                      : () => model.onRemoveTag(tag),
                ),
              if (!model.readOnly)
                ActionChip(
                  key: const Key('workspace-model-tag-add'),
                  avatar: const Icon(Icons.add, size: IconSize.small),
                  label: Text(l10n.workspaceModelTagsHint),
                  onPressed: model.onAddTag,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
