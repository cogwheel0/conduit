import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelAdvancedSection extends StatelessWidget {
  const WorkspaceModelAdvancedSection({super.key, required this.model});

  final WorkspaceModelAdvancedSectionModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return UtilityDisclosureSection(
      key: const Key('workspace-model-advanced-disclosure'),
      title: l10n.workspaceModelSectionAdvanced,
      expanded: model.expanded,
      onChanged: model.onExpandedChanged,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-stop',
            controller: model.stop,
            label: l10n.workspaceModelStopSequences,
            helperText: l10n.workspaceModelStopHint,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            onChanged: model.onTextChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-params',
            controller: model.params,
            label: l10n.workspaceModelAdvancedParams,
            helperText: l10n.workspaceModelParamsHint,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            json: true,
            hasError: model.paramsError == 'params',
            onChanged: model.onTextChanged,
          ),
          _capabilities(context, l10n),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-terminal',
            controller: model.terminal,
            label: l10n.workspaceModelTerminal,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            onChanged: model.onTextChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-tts',
            controller: model.tts,
            label: l10n.workspaceModelTtsVoice,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            onChanged: model.onTextChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-default-features',
            controller: model.defaultFeatures,
            label: l10n.workspaceModelDefaultFeatures,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            onChanged: model.onTextChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-builtin-tools',
            controller: model.builtinTools,
            label: l10n.workspaceModelBuiltinTools,
            helperText: l10n.workspaceModelParamsHint,
            isDetail: model.isDetail,
            enabled: !model.readOnly,
            json: true,
            hasError: model.paramsError == 'builtinTools',
            onChanged: model.onTextChanged,
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
          for (final entry in model.capabilities.entries)
            AdaptiveListTile(
              key: Key('workspace-model-capability-${entry.key}'),
              padding: EdgeInsets.zero,
              title: Text(entry.key),
              trailing: AdaptiveSwitch(
                value: entry.value,
                onChanged: model.readOnly
                    ? null
                    : (value) => model.onCapabilityChanged(entry.key, value),
              ),
            ),
        ],
      ),
    );
  }
}
