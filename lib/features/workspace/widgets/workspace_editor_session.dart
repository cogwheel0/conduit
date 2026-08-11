import 'package:flutter/foundation.dart';

import '../workspace_navigation.dart';

/// Notifying route and mutation state shared by workspace resource forms.
final class WorkspaceEditorSession extends ChangeNotifier {
  WorkspaceEditorSession(this.mode);

  final WorkspaceRouteMode mode;
  bool _dirty = false;
  bool _saving = false;
  String? _errorMessage;

  bool get isCreate => mode == WorkspaceRouteMode.create;
  bool get isDetail => mode == WorkspaceRouteMode.detail;
  bool get isEdit => mode == WorkspaceRouteMode.edit;
  bool get dirty => _dirty;
  bool get saving => _saving;
  String? get errorMessage => _errorMessage;

  set dirty(bool value) {
    if (_dirty == value) return;
    _dirty = value;
    notifyListeners();
  }

  set saving(bool value) {
    if (_saving == value) return;
    _saving = value;
    notifyListeners();
  }

  set errorMessage(String? value) {
    if (_errorMessage == value) return;
    _errorMessage = value;
    notifyListeners();
  }

  void beginSaving() {
    final changed = !_saving || _errorMessage != null;
    _saving = true;
    _errorMessage = null;
    if (changed) notifyListeners();
  }

  void finishSaving({String? errorMessage, bool? dirty}) {
    final nextDirty = dirty ?? _dirty;
    final changed =
        _saving || _errorMessage != errorMessage || _dirty != nextDirty;
    _saving = false;
    _errorMessage = errorMessage;
    _dirty = nextDirty;
    if (changed) notifyListeners();
  }
}
