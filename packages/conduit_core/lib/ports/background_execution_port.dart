/// Keeps a stream alive while the host is not in the foreground.
///
/// Only mobile needs this, and only mobile can do it: iOS grants a bounded
/// background task on request, Android holds a foreground service, and the
/// `conduitd` sidecar has no foreground to leave -- it runs for as long as
/// Electron does, whether or not a window is visible.
///
/// A port rather than a `Platform.isIOS` check inside the streaming code,
/// which is what it was. That check was correct and still dragged the mobile
/// pigeon API into every library that touched streaming, which is what kept
/// the send path out of the sidecar.
abstract interface class BackgroundExecutionPort {
  /// Asks to keep running while [streamIds] are in flight.
  ///
  /// Best-effort by contract: the caller must not await this before
  /// streaming, and must not treat a failure as a reason to stop. A denied
  /// background task means the stream may be suspended, not that it should
  /// not start.
  Future<void> begin(List<String> streamIds);

  /// Releases the leases for [streamIds].
  ///
  /// Called with the ids the matching [begin] was given, and safe to call for
  /// ids that were never granted -- a start that resolves after its own stop
  /// would otherwise leave a lease held forever.
  Future<void> end(List<String> streamIds);

  /// The host's implementation, installed once at startup.
  static BackgroundExecutionPort hostDefault = const NoBackgroundExecution();
}

/// Does nothing, which is correct for every host that cannot be suspended.
///
/// The daemon and the desktop shell both run until they are told to stop, so
/// there is nothing to ask for and nothing to release.
class NoBackgroundExecution implements BackgroundExecutionPort {
  const NoBackgroundExecution();

  @override
  Future<void> begin(List<String> streamIds) async {}

  @override
  Future<void> end(List<String> streamIds) async {}
}
