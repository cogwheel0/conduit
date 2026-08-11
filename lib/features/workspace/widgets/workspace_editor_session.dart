import 'package:flutter/foundation.dart';

import '../workspace_navigation.dart';

@immutable
final class WorkspaceEditorSessionState {
  const WorkspaceEditorSessionState({
    required this.mode,
    this.dirty = false,
    this.saving = false,
    this.errorMessage,
  });

  final WorkspaceRouteMode mode;
  final bool dirty;
  final bool saving;
  final String? errorMessage;

  bool get isCreate => mode == WorkspaceRouteMode.create;
  bool get isDetail => mode == WorkspaceRouteMode.detail;
  bool get isEdit => mode == WorkspaceRouteMode.edit;

  WorkspaceEditorSessionState copyWith({
    bool? dirty,
    bool? saving,
    String? errorMessage,
    bool clearError = false,
  }) => WorkspaceEditorSessionState(
    mode: mode,
    dirty: dirty ?? this.dirty,
    saving: saving ?? this.saving,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

/// Shared route and mutation state for workspace resource forms.
final class WorkspaceEditorSession {
  WorkspaceEditorSession(WorkspaceRouteMode mode)
    : _state = WorkspaceEditorSessionState(mode: mode);

  WorkspaceEditorSessionState _state;

  WorkspaceEditorSessionState get state => _state;
  bool get isCreate => state.isCreate;
  bool get isDetail => state.isDetail;
  bool get isEdit => state.isEdit;
  bool get dirty => state.dirty;
  bool get saving => state.saving;
  String? get errorMessage => state.errorMessage;

  set dirty(bool value) => _state = state.copyWith(dirty: value);
  set saving(bool value) => _state = state.copyWith(saving: value);
  set errorMessage(String? value) =>
      _state = state.copyWith(errorMessage: value, clearError: value == null);
}
