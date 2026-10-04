/// Keeps the screen from locking while a response is being generated.
///
/// Direct and Hermes generations run inside the app process, so a device that
/// locks mid-response suspends the transport and loses the reply (#681). The
/// core decides *when* the screen must stay awake; holding it is a platform
/// capability that only a host with a screen has.
abstract interface class WakelockPort {
  /// Enables or releases the hold. Idempotent on the platform side.
  Future<void> toggle({required bool enable});

  /// The host's implementation, installed once at startup.
  static WakelockPort hostDefault = const NullWakelock();
}

/// Does nothing: the daemon and tests have no screen to keep awake.
class NullWakelock implements WakelockPort {
  const NullWakelock();

  @override
  Future<void> toggle({required bool enable}) async {}
}
