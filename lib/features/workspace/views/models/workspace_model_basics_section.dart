import 'package:material_ui/material_ui.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import '../../providers/workspace_model_relationships.dart';
import 'workspace_model_editor_controller.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelBasicsSection extends StatelessWidget {
  const WorkspaceModelBasicsSection({
    super.key,
    required this.controller,
    required this.baseModels,
    required this.onAddTag,
  });

  final WorkspaceModelEditorController controller;
  final List<WorkspaceRelationshipOption> baseModels;
  final VoidCallback onAddTag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      title: l10n.workspaceModelSectionBasics,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-id',
            controller: controller.fields.id,
            label: l10n.workspaceModelIdLabel,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly && controller.session.isCreate,
            onChanged: controller.markDirty,
          ),
          _baseModelSelector(context, l10n),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-name',
            controller: controller.fields.name,
            label: l10n.workspaceModelName,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            onChanged: controller.markDirty,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-description',
            controller: controller.fields.description,
            label: l10n.workspaceModelDescription,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            minLines: 2,
            maxLines: 4,
            onChanged: controller.markDirty,
          ),
          _tagsField(context, l10n),
        ],
      ),
    );
  }

  Widget _baseModelSelector(BuildContext context, AppLocalizations l10n) {
    final selectedId = controller.draft.baseModelId;
    if (controller.session.isDetail) {
      return UtilityValueRow(
        key: const Key('workspace-model-base'),
        label: l10n.workspaceModelBaseModel,
        value: selectedId ?? l10n.workspaceModelBaseModelNone,
      );
    }
    final hasSelectedOption =
        selectedId == null ||
        baseModels.any((option) => option.id == selectedId);
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
          for (final option in baseModels)
            DropdownMenuItem<String?>(
              value: option.id,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: controller.readOnly ? null : controller.setBaseModel,
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
              for (final tag in controller.draft.tags)
                InputChip(
                  key: Key('workspace-model-tag-$tag'),
                  label: Text(tag),
                  onDeleted: controller.readOnly
                      ? null
                      : () => controller.removeTag(tag),
                ),
              if (!controller.readOnly)
                ActionChip(
                  key: const Key('workspace-model-tag-add'),
                  avatar: const Icon(Icons.add, size: IconSize.small),
                  label: Text(l10n.workspaceModelTagsHint),
                  onPressed: onAddTag,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
