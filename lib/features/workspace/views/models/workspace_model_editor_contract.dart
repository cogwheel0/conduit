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

/// Immutable presentation inputs shared by model-editor sections.
@immutable
final class WorkspaceModelEditorViewState {
  const WorkspaceModelEditorViewState({
    required this.draft,
    required this.fields,
    required this.isCreate,
    required this.isDetail,
    required this.readOnly,
    required this.paramsError,
    required this.baseModels,
  });

  final WorkspaceModelDraft draft;
  final WorkspaceModelFormBindings fields;
  final bool isCreate;
  final bool isDetail;
  final bool readOnly;
  final String? paramsError;
  final List<WorkspaceRelationshipOption> baseModels;
}

/// User intents consumed by the independently rendered model-editor sections.
@immutable
final class WorkspaceModelEditorIntents {
  const WorkspaceModelEditorIntents({
    required this.onChanged,
    required this.onMutate,
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

  final VoidCallback onChanged;
  final void Function(VoidCallback mutation) onMutate;
  final VoidCallback onAddTag;
  final VoidCallback onAddSuggestion;
  final VoidCallback onPickKnowledge;
  final VoidCallback onPickTools;
  final VoidCallback onPickSkills;
  final VoidCallback onPickFilters;
  final VoidCallback onPickDefaultFilters;
  final VoidCallback onPickActions;
  final VoidCallback onManageAccess;
}
