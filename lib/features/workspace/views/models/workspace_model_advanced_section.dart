import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import 'workspace_model_editor_controller.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelAdvancedSection extends StatelessWidget {
  const WorkspaceModelAdvancedSection({super.key, required this.controller});

  final WorkspaceModelEditorController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return UtilityDisclosureSection(
      key: const Key('workspace-model-advanced-disclosure'),
      title: l10n.workspaceModelSectionAdvanced,
      expanded: controller.advancedExpanded,
      onChanged: controller.setAdvancedExpanded,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-stop',
            controller: controller.fields.stop,
            label: l10n.workspaceModelStopSequences,
            helperText: l10n.workspaceModelStopHint,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            onChanged: controller.markDirty,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-params',
            controller: controller.fields.params,
            label: l10n.workspaceModelAdvancedParams,
            helperText: l10n.workspaceModelParamsHint,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            json: true,
            hasError:
                controller.syncIssue == WorkspaceModelDraftSyncIssue.params,
            onChanged: controller.markDirty,
          ),
          _capabilities(context, l10n),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-terminal',
            controller: controller.fields.terminal,
            label: l10n.workspaceModelTerminal,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            onChanged: controller.markDirty,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-tts',
            controller: controller.fields.tts,
            label: l10n.workspaceModelTtsVoice,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            onChanged: controller.markDirty,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-default-features',
            controller: controller.fields.defaultFeatures,
            label: l10n.workspaceModelDefaultFeatures,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            onChanged: controller.markDirty,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-builtin-tools',
            controller: controller.fields.builtinTools,
            label: l10n.workspaceModelBuiltinTools,
            helperText: l10n.workspaceModelParamsHint,
            isDetail: controller.session.isDetail,
            enabled: !controller.readOnly,
            json: true,
            hasError:
                controller.syncIssue ==
                WorkspaceModelDraftSyncIssue.builtinTools,
            onChanged: controller.markDirty,
          ),
        ],
      ),
    );
  }

  Widget _capabilities(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.workspaceModelCapabilities,
            style: context.conduitTheme.label,
          ),
          for (final entry in controller.draft.capabilities.entries)
            AdaptiveListTile(
              key: Key('workspace-model-capability-${entry.key}'),
              padding: EdgeInsets.zero,
              title: Text(entry.key),
              trailing: AdaptiveSwitch(
                value: entry.value,
                onChanged: controller.readOnly
                    ? null
                    : (value) => controller.setCapability(entry.key, value),
              ),
            ),
        ],
      ),
    );
  }
}
