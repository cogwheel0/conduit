import 'dart:convert';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';

import '../../models/workspace_model_draft.dart';
import '../../providers/workspace_model_relationships.dart';
import '../../widgets/workspace_access_grants.dart';
import '../../widgets/workspace_editor_fields.dart';
import '../../widgets/workspace_tiles.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/conduit_components.dart';
import '../../../../shared/widgets/utility_components.dart';

/// Owns the text-input lifecycle for a workspace model draft.
final class WorkspaceModelFormBindings {
  WorkspaceModelFormBindings(WorkspaceModelDraft draft)
    : id = TextEditingController(text: draft.id),
      name = TextEditingController(text: draft.name),
      description = TextEditingController(text: draft.description),
      system = TextEditingController(text: draft.system),
      stop = TextEditingController(text: draft.stop.join(', ')),
      terminal = TextEditingController(text: draft.terminalId),
      tts = TextEditingController(text: draft.ttsVoice),
      defaultFeatures = TextEditingController(
        text: draft.defaultFeatureIds.join(', '),
      ),
      params = TextEditingController(
        text: draft.advancedParams.isEmpty
            ? ''
            : const JsonEncoder.withIndent('  ').convert(draft.advancedParams),
      ),
      builtinTools = TextEditingController(
        text: draft.builtinTools.isEmpty
            ? ''
            : const JsonEncoder.withIndent('  ').convert(draft.builtinTools),
      );

  final TextEditingController id;
  final TextEditingController name;
  final TextEditingController description;
  final TextEditingController system;
  final TextEditingController stop;
  final TextEditingController terminal;
  final TextEditingController tts;
  final TextEditingController defaultFeatures;
  final TextEditingController params;
  final TextEditingController builtinTools;

  void dispose() {
    id.dispose();
    name.dispose();
    description.dispose();
    system.dispose();
    stop.dispose();
    terminal.dispose();
    tts.dispose();
    defaultFeatures.dispose();
    params.dispose();
    builtinTools.dispose();
  }
}

/// Pure presentation boundary for the model form's sections.
///
/// Persistence and async interactions stay in the parent coordinator; this
/// widget receives only draft mutations and section-specific callbacks.
final class WorkspaceModelEditorBody extends StatelessWidget {
  const WorkspaceModelEditorBody({
    super.key,
    required this.draft,
    required this.fields,
    required this.profileImage,
    required this.isCreate,
    required this.isDetail,
    required this.readOnly,
    required this.advancedExpanded,
    required this.paramsError,
    required this.baseModels,
    required this.onChanged,
    required this.onMutate,
    required this.onAdvancedChanged,
    required this.onAddTag,
    required this.onAddSuggestion,
    required this.onPickKnowledge,
    required this.onPickTools,
    required this.onPickSkills,
    required this.onPickFilters,
    required this.onPickDefaultFilters,
    required this.onPickActions,
    required this.onManageAccess,
  });

  final WorkspaceModelDraft draft;
  final WorkspaceModelFormBindings fields;
  final Widget profileImage;
  final bool isCreate;
  final bool isDetail;
  final bool readOnly;
  final bool advancedExpanded;
  final String? paramsError;
  final List<WorkspaceRelationshipOption> baseModels;
  final VoidCallback onChanged;
  final void Function(VoidCallback mutation) onMutate;
  final ValueChanged<bool> onAdvancedChanged;
  final VoidCallback onAddTag;
  final VoidCallback onAddSuggestion;
  final VoidCallback onPickKnowledge;
  final VoidCallback onPickTools;
  final VoidCallback onPickSkills;
  final VoidCallback onPickFilters;
  final VoidCallback onPickDefaultFilters;
  final VoidCallback onPickActions;
  final VoidCallback onManageAccess;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListView(
      key: const Key('workspace-model-editor-body'),
      padding: EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        Spacing.md,
        Spacing.pagePadding,
        Spacing.pagePadding + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        profileImage,
        const SizedBox(height: Spacing.xl),
        InsetGroupedSection(
          title: l10n.workspaceModelSectionBasics,
          child: Column(
            children: [
              _textField(
                context,
                key: 'workspace-model-id',
                controller: fields.id,
                label: l10n.workspaceModelIdLabel,
                enabled: !readOnly && isCreate,
              ),
              _baseModelSelector(context, l10n),
              _textField(
                context,
                key: 'workspace-model-name',
                controller: fields.name,
                label: l10n.workspaceModelName,
                enabled: !readOnly,
              ),
              _textField(
                context,
                key: 'workspace-model-description',
                controller: fields.description,
                label: l10n.workspaceModelDescription,
                enabled: !readOnly,
                minLines: 2,
                maxLines: 4,
              ),
              _tagsField(context, l10n),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),
        InsetGroupedSection(
          title: l10n.workspaceModelSectionPrompt,
          child: Column(
            children: [
              _textField(
                context,
                key: 'workspace-model-system',
                controller: fields.system,
                label: l10n.workspaceModelSystemPrompt,
                enabled: !readOnly,
                minLines: 3,
                maxLines: 10,
              ),
              _suggestionPrompts(context, l10n),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),
        UtilityDisclosureSection(
          key: const Key('workspace-model-advanced-disclosure'),
          title: l10n.workspaceModelSectionAdvanced,
          expanded: advancedExpanded,
          onChanged: onAdvancedChanged,
          child: Column(
            children: [
              _textField(
                context,
                key: 'workspace-model-stop',
                controller: fields.stop,
                label: l10n.workspaceModelStopSequences,
                helperText: l10n.workspaceModelStopHint,
                enabled: !readOnly,
              ),
              _jsonField(
                context,
                key: 'workspace-model-params',
                controller: fields.params,
                label: l10n.workspaceModelAdvancedParams,
                helperText: l10n.workspaceModelParamsHint,
                hasError: paramsError == 'params',
              ),
              _capabilities(context, l10n),
              _textField(
                context,
                key: 'workspace-model-terminal',
                controller: fields.terminal,
                label: l10n.workspaceModelTerminal,
                enabled: !readOnly,
              ),
              _textField(
                context,
                key: 'workspace-model-tts',
                controller: fields.tts,
                label: l10n.workspaceModelTtsVoice,
                enabled: !readOnly,
              ),
              _textField(
                context,
                key: 'workspace-model-default-features',
                controller: fields.defaultFeatures,
                label: l10n.workspaceModelDefaultFeatures,
                enabled: !readOnly,
              ),
              _jsonField(
                context,
                key: 'workspace-model-builtin-tools',
                controller: fields.builtinTools,
                label: l10n.workspaceModelBuiltinTools,
                helperText: l10n.workspaceModelParamsHint,
                hasError: paramsError == 'builtinTools',
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xl),
        WorkspaceSectionHeader(title: l10n.workspaceModelSectionRelationships),
        _relationshipTile(
          context,
          keyId: 'workspace-model-knowledge',
          label: l10n.workspaceModelKnowledge,
          count: draft.knowledge.length,
          onTap: readOnly ? null : onPickKnowledge,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-tools',
          label: l10n.workspaceModelTools,
          count: draft.toolIds.length,
          onTap: readOnly ? null : onPickTools,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-skills',
          label: l10n.workspaceModelSkills,
          count: draft.skillIds.length,
          onTap: readOnly ? null : onPickSkills,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-filters',
          label: l10n.workspaceModelFilters,
          count: draft.filterIds.length,
          onTap: readOnly ? null : onPickFilters,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-default-filters',
          label: l10n.workspaceModelDefaultFilters,
          count: draft.defaultFilterIds.length,
          onTap: readOnly ? null : onPickDefaultFilters,
        ),
        _relationshipTile(
          context,
          keyId: 'workspace-model-actions',
          label: l10n.workspaceModelActions,
          count: draft.actionIds.length,
          onTap: readOnly ? null : onPickActions,
        ),
        const SizedBox(height: Spacing.xl),
        WorkspaceSectionHeader(title: l10n.workspaceModelSectionAccess),
        _accessTile(l10n),
        const SizedBox(height: Spacing.xl),
      ],
    );
  }

  Widget _textField(
    BuildContext context, {
    required String key,
    required TextEditingController controller,
    required String label,
    required bool enabled,
    String? helperText,
    int minLines = 1,
    int maxLines = 1,
  }) {
    if (isDetail) {
      return UtilityValueRow(
        key: Key(key),
        label: label,
        value: controller.text.trim().isEmpty
            ? AppLocalizations.of(context)!.workspaceModelBaseModelNone
            : controller.text,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: WorkspaceLabeledField(
        helperText: helperText,
        child: ConduitInput(
          key: Key(key),
          controller: controller,
          label: label,
          enabled: enabled,
          minLines: minLines,
          maxLines: maxLines < minLines ? minLines : maxLines,
          onChanged: (_) => onChanged(),
        ),
      ),
    );
  }

  Widget _jsonField(
    BuildContext context, {
    required String key,
    required TextEditingController controller,
    required String label,
    String? helperText,
    bool hasError = false,
  }) {
    if (isDetail) {
      return UtilityValueRow(
        key: Key(key),
        label: label,
        value: controller.text.trim().isEmpty
            ? AppLocalizations.of(context)!.workspaceModelBaseModelNone
            : controller.text,
      );
    }
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: WorkspaceLabeledField(
        helperText: helperText,
        child: ConduitInput(
          key: Key(key),
          controller: controller,
          label: label,
          enabled: !readOnly,
          minLines: 2,
          maxLines: 8,
          style: theme.code?.copyWith(color: theme.textPrimary),
          errorText: hasError
              ? AppLocalizations.of(context)!.workspaceModelInvalidJson
              : null,
          onChanged: (_) => onChanged(),
        ),
      ),
    );
  }

  Widget _baseModelSelector(BuildContext context, AppLocalizations l10n) {
    final selectedId = draft.baseModelId;
    if (isDetail) {
      return UtilityValueRow(
        key: const Key('workspace-model-base'),
        label: l10n.workspaceModelBaseModel,
        value: selectedId ?? l10n.workspaceModelBaseModelNone,
      );
    }
    final hasSelectedOption =
        selectedId == null || baseModels.any((model) => model.id == selectedId);
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
          for (final model in baseModels)
            DropdownMenuItem<String?>(
              value: model.id,
              child: Text(model.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: readOnly
            ? null
            : (value) => onMutate(() => draft.baseModelId = value),
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
              for (final tag in draft.tags)
                InputChip(
                  key: Key('workspace-model-tag-$tag'),
                  label: Text(tag),
                  onDeleted: readOnly
                      ? null
                      : () => onMutate(() => draft.tags.remove(tag)),
                ),
              if (!readOnly)
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

  Widget _suggestionPrompts(BuildContext context, AppLocalizations l10n) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceModelSuggestionPrompts, style: theme.label),
          const SizedBox(height: Spacing.xs),
          for (var index = 0; index < draft.suggestionPrompts.length; index++)
            AdaptiveListTile(
              key: Key('workspace-model-suggestion-$index'),
              padding: EdgeInsets.zero,
              title: Text(draft.suggestionPrompts[index]),
              trailing: readOnly
                  ? null
                  : IconButton(
                      tooltip: l10n.workspaceModelRemoveSuggestion,
                      icon: const Icon(Icons.close, size: IconSize.small),
                      onPressed: () => onMutate(
                        () => draft.suggestionPrompts.removeAt(index),
                      ),
                    ),
            ),
          if (!readOnly)
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
          for (final key in draft.capabilities.keys)
            AdaptiveListTile(
              key: Key('workspace-model-capability-$key'),
              padding: EdgeInsets.zero,
              title: Text(key),
              trailing: AdaptiveSwitch(
                value: draft.capabilities[key] ?? false,
                onChanged: readOnly
                    ? null
                    : (value) =>
                          onMutate(() => draft.capabilities[key] = value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _relationshipTile(
    BuildContext context, {
    required String keyId,
    required String label,
    required int count,
    VoidCallback? onTap,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: WorkspaceResourceTile(
        key: Key(keyId),
        icon: Icons.account_tree_outlined,
        title: label,
        subtitle: count == 0
            ? l10n.workspaceModelSelectNone
            : l10n.workspaceModelSelectCount(count),
        onTap: onTap,
      ),
    );
  }

  Widget _accessTile(AppLocalizations l10n) {
    final principals = workspaceSharedPrincipals(draft.normalizedAccessGrants);
    final isPublic = workspaceGrantsArePublic(draft.normalizedAccessGrants);
    return WorkspaceResourceTile(
      key: const Key('workspace-model-access'),
      icon: isPublic ? Icons.public : Icons.lock_outline,
      title: l10n.workspaceModelManageAccess,
      subtitle: isPublic
          ? l10n.workspaceAccessVisibilityLabel
          : l10n.workspaceModelSelectCount(principals.length),
      onTap: onManageAccess,
    );
  }
}
