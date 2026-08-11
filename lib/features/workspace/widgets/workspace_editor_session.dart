import '../workspace_navigation.dart';

/// Passive route and mutation state owned by a workspace editor widget.
///
/// The widget's `setState` call is the single rebuild mechanism; this object
/// groups related values without publishing a second notification stream.
final class WorkspaceEditorSession {
  WorkspaceEditorSession(this.mode);

  final WorkspaceRouteMode mode;
  bool dirty = false;
  bool saving = false;
  String? errorMessage;

  bool get isCreate => mode == WorkspaceRouteMode.create;
  bool get isDetail => mode == WorkspaceRouteMode.detail;
  bool get isEdit => mode == WorkspaceRouteMode.edit;

  void beginSaving() {
    saving = true;
    errorMessage = null;
  }

  void finishSaving({String? errorMessage, bool? dirty}) {
    saving = false;
    this.errorMessage = errorMessage;
    if (dirty != null) this.dirty = dirty;
  }
}
