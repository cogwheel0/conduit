import 'package:material_ui/material_ui.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../../shared/widgets/utility_components.dart';
import '../../widgets/workspace_editor_fields.dart';
import '../../providers/workspace_model_relationships.dart';
import 'workspace_model_editor_controller.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelBasicsSection extends StatelessWidget {
  const WorkspaceModelBasicsSection({
    super.key,
    required this.controller,
    required this.baseModels,
    required this.baseModelRequired,
    required this.onAddTag,
  });

  final WorkspaceModelEditorController controller;
  final List<WorkspaceRelationshipOption> baseModels;
  final bool baseModelRequired;
  final VoidCallback onAddTag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return WorkspaceEditorFieldGroup(
      title: l10n.workspaceModelSectionBasics,
      androidGap: Spacing.sm,
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
        WorkspaceTagField(
          keyPrefix: 'workspace-model',
          label: l10n.workspaceModelTags,
          addLabel: l10n.workspaceModelTagsHint,
          tags: controller.draft.tags,
          readOnly: controller.readOnly,
          onRemove: controller.removeTag,
          onAdd: onAddTag,
        ),
      ],
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
    final options = <AdaptiveDropdownOption<String?>>[
      if (!baseModelRequired)
        AdaptiveDropdownOption<String?>(
          value: null,
          label: l10n.workspaceModelBaseModelNone,
        ),
      if (!hasSelectedOption)
        AdaptiveDropdownOption<String?>(value: selectedId, label: selectedId),
      for (final option in baseModels)
        AdaptiveDropdownOption<String?>(value: option.id, label: option.label),
    ];
    if (context.usesCupertinoChrome) {
      final selectedLabel = selectedId == null
          ? l10n.workspaceModelBaseModelNone
          : options.firstWhere((option) => option.value == selectedId).label;
      final row = UtilityValueRow(
        key: const Key('workspace-model-base'),
        label: l10n.workspaceModelBaseModel,
        value: selectedLabel,
        selectable: false,
        showChevron: !controller.readOnly,
      );
      if (controller.readOnly) return row;
      return AdaptiveSingleChoiceTrigger<String?>(
        value: selectedId,
        options: options,
        onChanged: controller.setBaseModel,
        nativeTitle: l10n.workspaceModelBaseModel,
        semanticLabel: '${l10n.workspaceModelBaseModel}. $selectedLabel',
        child: row,
      );
    }
    return AdaptiveDropdownField<String?>(
      key: const Key('workspace-model-base'),
      value: selectedId,
      decoration: InputDecoration(
        labelText: l10n.workspaceModelBaseModel,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      options: options,
      onChanged: controller.readOnly ? null : controller.setBaseModel,
    );
  }
}
