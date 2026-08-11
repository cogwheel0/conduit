import 'package:flutter/foundation.dart';

import '../workspace_navigation.dart';

/// Canonical route and operation state shared by every workspace editor.
///
/// Session mutations notify listeners directly so widgets and controllers use
/// the same rebuild contract.
final class WorkspaceEditorSession extends ChangeNotifier {
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

  void markDirty() {
    if (_dirty) return;
    _dirty = true;
    notifyListeners();
  }

  void markClean() {
    if (!_dirty) return;
    _dirty = false;
    notifyListeners();
  }

  void setError(String message) {
    if (_errorMessage == message) return;
    _errorMessage = message;
    notifyListeners();
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  /// Acquires the editor's mutation lock.
  ///
  /// Returns false while another mutation owns the session so callers cannot
  /// start overlapping save, clone, delete, toggle, or access operations.
  bool beginOperation({bool clearError = false}) {
    if (_saving) return false;
    _saving = true;
    if (clearError) _errorMessage = null;
    notifyListeners();
    return true;
  }

  void finishOperation({String? errorMessage, bool? dirty}) {
    final nextDirty = dirty ?? _dirty;
    final changed =
        _saving || _errorMessage != errorMessage || _dirty != nextDirty;
    _saving = false;
    _errorMessage = errorMessage;
    _dirty = nextDirty;
    if (changed) notifyListeners();
  }

  void endOperation() {
    if (!_saving) return;
    _saving = false;
    notifyListeners();
  }
}
