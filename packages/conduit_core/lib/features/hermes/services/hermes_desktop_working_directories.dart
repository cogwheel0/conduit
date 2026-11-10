part of 'hermes_desktop_api_service.dart';

/// The most chats whose working directory is kept in memory.
const int _kMaxHermesWorkingDirectorySessions = 64;

extension _HermesDesktopWorkingDirectories on HermesDesktopApiService {
  /// Adopts the working directory session [sessionId] (a runtime or stored
  /// id) runs its tools in, from the `cwd` of a session's info: a resume's
  /// or create's, or a `session.info` event's. Infos without one (partial
  /// ones, or a session with none) change nothing.
  void _adoptWorkingDirectory(String? sessionId, Object? cwd) {
    if (sessionId == null || sessionId.isEmpty) return;
    if (cwd is! String || cwd.trim().isEmpty) return;
    final key = _storedIdForRuntime(sessionId) ?? sessionId;
    if (_workingDirectories[key] == cwd) return;
    if (!_workingDirectories.containsKey(key) &&
        _workingDirectories.length >= _kMaxHermesWorkingDirectorySessions) {
      _workingDirectories.remove(_workingDirectories.keys.first);
    }
    _workingDirectories[key] = cwd;
    if (!_closed) _workingDirectoryChanges.add(key);
  }

  /// The working directory of [storedId], under its stored or its runtime
  /// id; the one a resume's new stored id has comes first.
  String? _workingDirectoryFor(String storedId) {
    final binding = _bindings[storedId];
    return _workingDirectories[binding?.storedId] ??
        _workingDirectories[binding?.runtimeId] ??
        _workingDirectories[storedId];
  }

  Stream<String?> _workingDirectoriesFor(String storedId) =>
      Stream<String?>.multi((controller) {
        final subscription = _workingDirectoryChanges.stream.listen(
          (changedId) {
            final binding = _bindings[storedId];
            if (changedId == storedId ||
                changedId == binding?.storedId ||
                changedId == binding?.runtimeId) {
              controller.add(_workingDirectoryFor(storedId));
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        controller
          ..add(_workingDirectoryFor(storedId))
          ..onCancel = subscription.cancel;
      });
}
