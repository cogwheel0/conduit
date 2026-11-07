part of 'hermes_desktop_api_service.dart';

/// The most chats whose task list is kept in memory.
const int _kMaxHermesTodoSessions = 64;

extension _HermesDesktopTodos on HermesDesktopApiService {
  /// Adopts the task list [payload] carries for [sessionId] (a runtime or
  /// stored id): a `todo.updated` event, a `tool.complete` of the todo tool,
  /// or a resume's `todo_state`. Revisions only move forward.
  void _adoptTodoState(String? sessionId, Object? payload) {
    if (sessionId == null || sessionId.isEmpty) return;
    final state = HermesTodoState.fromPayload(payload);
    if (state == null) return;
    final key = _storedIdForRuntime(sessionId) ?? sessionId;
    final current = _todoStateFor(key);
    if (current != null && state.revision < current.revision) return;
    if (!_todoStates.containsKey(key) &&
        _todoStates.length >= _kMaxHermesTodoSessions) {
      _todoStates.remove(_todoStates.keys.first);
    }
    _todoStates[key] = state;
    if (!_closed) _todoChanges.add(key);
  }

  /// The task list of [storedId], under its stored or its runtime id.
  HermesTodoState? _todoStateFor(String storedId) {
    final binding = _bindings[storedId];
    return _todoStates[storedId] ??
        _todoStates[binding?.storedId] ??
        _todoStates[binding?.runtimeId];
  }

  Stream<HermesTodoState?> _todoStatesFor(String storedId) =>
      Stream<HermesTodoState?>.multi((controller) {
        final subscription = _todoChanges.stream.listen(
          (changedId) {
            final binding = _bindings[storedId];
            if (changedId == storedId ||
                changedId == binding?.storedId ||
                changedId == binding?.runtimeId) {
              controller.add(_todoStateFor(storedId));
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        controller
          ..add(_todoStateFor(storedId))
          ..onCancel = subscription.cancel;
      });
}
