/// Hands a URL to the platform's browser.
///
/// Never an in-app view. Model output and server-supplied citations contain
/// links; opening those inside the app's own origin would give an
/// attacker-influenced page the app's context. The desktop implementation is
/// `shell.openExternal` behind an http/https allowlist, and the mobile one is
/// `url_launcher` with an external application mode.
abstract interface class OpenExternalUrlPort {
  /// Returns false when the host refused — an unsupported scheme, no handler
  /// installed, or the user dismissed a confirmation.
  Future<bool> open(Uri url);
}

/// Refuses every URL. The safe default for a host with no browser.
class NullOpenExternalUrlPort implements OpenExternalUrlPort {
  const NullOpenExternalUrlPort();

  @override
  Future<bool> open(Uri url) async => false;
}
