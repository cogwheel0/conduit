/// Whether this device has a usable network interface.
///
/// Deliberately *not* "is the server reachable" — that is a health probe the
/// core already owns. This is the cheap, OS-level signal that says a probe is
/// even worth attempting: a radio came up, a cable was plugged in, the laptop
/// left airplane mode.
abstract interface class ConnectivityPort {
  /// Best current guess. False means "definitely no interface"; true means
  /// "an interface exists", which is not the same as "the internet works".
  Future<bool> hasNetworkInterface();

  /// Fires when the set of interfaces changes.
  ///
  /// The payload is the same optimistic boolean. Consumers treat an edge to
  /// true as "retry now", never as proof of reachability.
  Stream<bool> get onChanged;
}

/// Assumes a working interface and never reports a change.
///
/// Correct for a host with no connectivity API — the core then relies purely
/// on its own probes and on request failures, which is how it behaved before
/// the port existed.
class AlwaysOnlineConnectivityPort implements ConnectivityPort {
  const AlwaysOnlineConnectivityPort();

  @override
  Future<bool> hasNetworkInterface() async => true;

  @override
  Stream<bool> get onChanged => const Stream<bool>.empty();
}
