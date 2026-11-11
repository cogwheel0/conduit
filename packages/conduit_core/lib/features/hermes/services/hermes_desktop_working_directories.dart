part of 'hermes_desktop_api_service.dart';

/// The most chats whose working directory is kept in memory. The one used
/// longest ago goes first: reported again or read, a chat's is kept anew.
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
    // Taken out and put back, it is the newest whether or not it changed.
    final previous = _workingDirectories.remove(key);
    if (previous == null &&
        _workingDirectories.length >= _kMaxHermesWorkingDirectorySessions) {
      // The chat that loses its directory hears so, not only the new one.
      _forgetWorkingDirectory([_workingDirectories.keys.first]);
    }
    _workingDirectories[key] = cwd;
    if (previous != cwd && !_closed) _workingDirectoryChanges.add(key);
  }

  /// Drops the working directory kept under any of [ids], as for a deleted
  /// session, and tells the chats that showed it.
  void _forgetWorkingDirectory(Iterable<String?> ids) {
    for (final id in ids) {
      if (id == null || _workingDirectories.remove(id) == null) continue;
      if (!_closed) _workingDirectoryChanges.add(id);
    }
  }

  /// The working directory of [storedId], under its stored or its runtime
  /// id; the one a resume's new stored id has comes first. Read, it is kept
  /// the longest: a chat in use does not lose it to others opened since.
  String? _workingDirectoryFor(String storedId) {
    final binding = _bindings[storedId];
    for (final key in [binding?.storedId, binding?.runtimeId, storedId]) {
      if (key == null) continue;
      final cwd = _workingDirectories.remove(key);
      if (cwd == null) continue;
      _workingDirectories[key] = cwd;
      return cwd;
    }
    return null;
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
