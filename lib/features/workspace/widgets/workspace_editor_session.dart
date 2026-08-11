import '../workspace_navigation.dart';

/// Passive route and mutation state owned by a workspace editor widget.
///
/// The widget's `setState` call is the single rebuild mechanism; this object
/// groups related values without publishing a second notification stream.
final class WorkspaceEditorSession {
  WorkspaceEditorSession(this.mode);

  final WorkspaceRouteMode mode;
  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;

  bool get dirty => _dirty;
  bool get saving => _saving;
  String? get errorMessage => _errorMessage;

  bool get isCreate => mode == WorkspaceRouteMode.create;
  bool get isDetail => mode == WorkspaceRouteMode.detail;
  bool get isEdit => mode == WorkspaceRouteMode.edit;

  void markDirty() => _dirty = true;

  void markClean() => _dirty = false;

  void setError(String message) => _errorMessage = message;

  void clearError() => _errorMessage = null;

  void beginOperation({bool clearError = false}) {
    _saving = true;
    if (clearError) _errorMessage = null;
  }

  void finishOperation({String? errorMessage, bool? dirty}) {
    _saving = false;
    _errorMessage = errorMessage;
    if (dirty != null) _dirty = dirty;
  }

  void endOperation() => _saving = false;
}
