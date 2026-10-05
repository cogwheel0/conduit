import '../../../navigation/routes.dart' show WorkspaceRouteMode;

/// Canonical route and operation state shared by every workspace editor.
///
/// Session mutations notify listeners directly so widgets and controllers use
/// the same rebuild contract. The listener API has the shape of Flutter's
/// `ChangeNotifier` (`addListener`, `removeListener`, `dispose`); the core is
/// Flutter-free and cannot extend it.
final class WorkspaceEditorSession {
  WorkspaceEditorSession(this.mode);

  final WorkspaceRouteMode mode;
  final List<void Function()> _listeners = <void Function()>[];
  bool _disposed = false;
  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;

  bool get dirty => _dirty;
  bool get saving => _saving;
  String? get errorMessage => _errorMessage;

  bool get isCreate => mode == WorkspaceRouteMode.create;
  bool get isDetail => mode == WorkspaceRouteMode.detail;
  bool get isEdit => mode == WorkspaceRouteMode.edit;

  void addListener(void Function() listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Drops every listener. Later mutations still update the state (an
  /// operation can finish after its editor is gone) but notify no one.
  void dispose() {
    _disposed = true;
    _listeners.clear();
  }

  /// Calls every listener registered when the notification starts; a listener
  /// removed by an earlier one in the same pass is skipped.
  void _notifyListeners() {
    if (_listeners.isEmpty) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void markDirty() {
    if (_dirty) return;
    _dirty = true;
    _notifyListeners();
  }

  void markClean() {
    if (!_dirty) return;
    _dirty = false;
    _notifyListeners();
  }

  void setError(String message) {
    if (_errorMessage == message) return;
    _errorMessage = message;
    _notifyListeners();
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    _notifyListeners();
  }

  /// Acquires the editor's mutation lock.
  ///
  /// Returns false while another mutation owns the session so callers cannot
  /// start overlapping save, clone, delete, toggle, or access operations.
  bool beginOperation({bool clearError = false}) {
    if (_saving) return false;
    _saving = true;
    if (clearError) _errorMessage = null;
    _notifyListeners();
    return true;
  }

  void finishOperation({String? errorMessage, bool? dirty}) {
    final nextDirty = dirty ?? _dirty;
    final changed =
        _saving || _errorMessage != errorMessage || _dirty != nextDirty;
    _saving = false;
    _errorMessage = errorMessage;
    _dirty = nextDirty;
    if (changed) _notifyListeners();
  }

  void endOperation() {
    if (!_saving) return;
    _saving = false;
    _notifyListeners();
  }
}
