import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/workspace_model_draft.dart';
import '../../providers/workspace_model_relationships.dart';

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

/// Narrow inputs and intents owned by the Basics section.
final class WorkspaceModelBasicsSectionModel {
  WorkspaceModelBasicsSectionModel({
    required this.id,
    required this.name,
    required this.description,
    required this.baseModelId,
    required List<WorkspaceRelationshipOption> baseModels,
    required List<String> tags,
    required this.isCreate,
    required this.isDetail,
    required this.readOnly,
    required this.onTextChanged,
    required this.onBaseModelChanged,
    required this.onRemoveTag,
    required this.onAddTag,
  }) : baseModels = List.unmodifiable(baseModels),
       tags = List.unmodifiable(tags);

  final TextEditingController id;
  final TextEditingController name;
  final TextEditingController description;
  final String? baseModelId;
  final List<WorkspaceRelationshipOption> baseModels;
  final List<String> tags;
  final bool isCreate;
  final bool isDetail;
  final bool readOnly;
  final VoidCallback onTextChanged;
  final ValueChanged<String?> onBaseModelChanged;
  final ValueChanged<String> onRemoveTag;
  final VoidCallback onAddTag;
}

/// Narrow inputs and intents owned by the Prompt section.
final class WorkspaceModelPromptSectionModel {
  WorkspaceModelPromptSectionModel({
    required this.system,
    required List<String> suggestionPrompts,
    required this.isDetail,
    required this.readOnly,
    required this.onTextChanged,
    required this.onRemoveSuggestion,
    required this.onAddSuggestion,
  }) : suggestionPrompts = List.unmodifiable(suggestionPrompts);

  final TextEditingController system;
  final List<String> suggestionPrompts;
  final bool isDetail;
  final bool readOnly;
  final VoidCallback onTextChanged;
  final ValueChanged<int> onRemoveSuggestion;
  final VoidCallback onAddSuggestion;
}

/// Narrow inputs and intents owned by the Advanced section.
final class WorkspaceModelAdvancedSectionModel {
  WorkspaceModelAdvancedSectionModel({
    required this.stop,
    required this.params,
    required this.terminal,
    required this.tts,
    required this.defaultFeatures,
    required this.builtinTools,
    required Map<String, bool> capabilities,
    required this.isDetail,
    required this.readOnly,
    required this.paramsError,
    required this.expanded,
    required this.onTextChanged,
    required this.onCapabilityChanged,
    required this.onExpandedChanged,
  }) : capabilities = Map.unmodifiable(capabilities);

  final TextEditingController stop;
  final TextEditingController params;
  final TextEditingController terminal;
  final TextEditingController tts;
  final TextEditingController defaultFeatures;
  final TextEditingController builtinTools;
  final Map<String, bool> capabilities;
  final bool isDetail;
  final bool readOnly;
  final String? paramsError;
  final bool expanded;
  final VoidCallback onTextChanged;
  final void Function(String capability, bool value) onCapabilityChanged;
  final ValueChanged<bool> onExpandedChanged;
}

enum WorkspaceModelRelationshipKind {
  knowledge,
  tools,
  skills,
  filters,
  defaultFilters,
  actions,
}

/// Narrow inputs and intents owned by the Relationships section.
final class WorkspaceModelRelationshipsSectionModel {
  WorkspaceModelRelationshipsSectionModel({
    required Map<WorkspaceModelRelationshipKind, int> counts,
    required this.readOnly,
    required this.accessPrincipalCount,
    required this.accessIsPublic,
    required this.onPick,
    required this.onManageAccess,
  }) : counts = Map.unmodifiable(counts);

  final Map<WorkspaceModelRelationshipKind, int> counts;
  final bool readOnly;
  final int accessPrincipalCount;
  final bool accessIsPublic;
  final ValueChanged<WorkspaceModelRelationshipKind> onPick;
  final VoidCallback onManageAccess;
}
