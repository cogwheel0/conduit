import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/utility_components.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_editor_field.dart';

final class WorkspaceModelAdvancedSection extends StatelessWidget {
  const WorkspaceModelAdvancedSection({
    super.key,
    required this.state,
    required this.intents,
    required this.expanded,
    required this.onExpandedChanged,
  });

  final WorkspaceModelEditorViewState state;
  final WorkspaceModelEditorIntents intents;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return UtilityDisclosureSection(
      key: const Key('workspace-model-advanced-disclosure'),
      title: l10n.workspaceModelSectionAdvanced,
      expanded: expanded,
      onChanged: onExpandedChanged,
      child: Column(
        children: [
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-stop',
            controller: state.fields.stop,
            label: l10n.workspaceModelStopSequences,
            helperText: l10n.workspaceModelStopHint,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            onChanged: intents.onChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-params',
            controller: state.fields.params,
            label: l10n.workspaceModelAdvancedParams,
            helperText: l10n.workspaceModelParamsHint,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            json: true,
            hasError: state.paramsError == 'params',
            onChanged: intents.onChanged,
          ),
          _capabilities(context, l10n),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-terminal',
            controller: state.fields.terminal,
            label: l10n.workspaceModelTerminal,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            onChanged: intents.onChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-tts',
            controller: state.fields.tts,
            label: l10n.workspaceModelTtsVoice,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            onChanged: intents.onChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-default-features',
            controller: state.fields.defaultFeatures,
            label: l10n.workspaceModelDefaultFeatures,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            onChanged: intents.onChanged,
          ),
          WorkspaceModelEditorField(
            fieldKey: 'workspace-model-builtin-tools',
            controller: state.fields.builtinTools,
            label: l10n.workspaceModelBuiltinTools,
            helperText: l10n.workspaceModelParamsHint,
            isDetail: state.isDetail,
            enabled: !state.readOnly,
            json: true,
            hasError: state.paramsError == 'builtinTools',
            onChanged: intents.onChanged,
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
          for (final key in state.draft.capabilities.keys)
            AdaptiveListTile(
              key: Key('workspace-model-capability-$key'),
              padding: EdgeInsets.zero,
              title: Text(key),
              trailing: AdaptiveSwitch(
                value: state.draft.capabilities[key] ?? false,
                onChanged: state.readOnly
                    ? null
                    : (value) => intents.onMutate(
                        () => state.draft.capabilities[key] = value,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}
