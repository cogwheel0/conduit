import 'package:flutter/widgets.dart';

import 'package:conduit_core/features/workspace/editor/workspace_model_editor_state.dart';

import '../../models/workspace_model_draft.dart';

export 'package:conduit_core/features/workspace/editor/workspace_model_editor_state.dart';

/// Owns the text-input lifecycle for a workspace model draft.
final class WorkspaceModelFormBindings {
  WorkspaceModelFormBindings(WorkspaceModelDraft draft)
    : this._(WorkspaceModelFieldText.fromDraft(draft));

  WorkspaceModelFormBindings._(WorkspaceModelFieldText initial)
    : id = TextEditingController(text: initial.id),
      name = TextEditingController(text: initial.name),
      description = TextEditingController(text: initial.description),
      system = TextEditingController(text: initial.system),
      stop = TextEditingController(text: initial.stop),
      terminal = TextEditingController(text: initial.terminal),
      tts = TextEditingController(text: initial.tts),
      defaultFeatures = TextEditingController(text: initial.defaultFeatures),
      params = TextEditingController(text: initial.params),
      builtinTools = TextEditingController(text: initial.builtinTools);

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

  /// The fields' current text.
  WorkspaceModelFieldText get text => WorkspaceModelFieldText(
    id: id.text,
    name: name.text,
    description: description.text,
    system: system.text,
    stop: stop.text,
    terminal: terminal.text,
    tts: tts.text,
    defaultFeatures: defaultFeatures.text,
    params: params.text,
    builtinTools: builtinTools.text,
  );

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

/// The conduit_core model editor state with the form's text controllers.
final class WorkspaceModelEditorController extends WorkspaceModelEditorState {
  WorkspaceModelEditorController({
    required super.mode,
    required super.initialDraft,
    required super.writeAccess,
    super.summary,
  }) {
    fields = WorkspaceModelFormBindings(draft);
  }

  late final WorkspaceModelFormBindings fields;

  /// Copies the text controllers into the draft; see [syncFieldText].
  bool syncTextIntoDraft() => syncFieldText(fields.text);

  @override
  void dispose() {
    super.dispose();
    fields.dispose();
  }
}
