/// The browser surface an external sign-in flow runs in (WP-1.5).
///
/// Proxy auth (oauth2-proxy, Authelia, Authentik, Cloudflare Tunnel) and SSO
/// finish somewhere the core does not own: an in-app WebView on mobile, a
/// separate Electron window on desktop. Both leave cookies the API client
/// must replay, and both need purging on sign-out.
///
/// Every method returns whether it *succeeded*, not just that it ran. A
/// half-completed purge is the dangerous case — it leaves credentials that
/// would silently re-authenticate the next session — so callers gate on the
/// result rather than assuming.
abstract interface class CookieJarPort {
  /// Whether this host has a browser surface at all.
  ///
  /// False on a platform with no WebView, which is what gates the SSO and
  /// proxy entry points off in the UI.
  bool get isSupported;

  /// Cookie identities currently held for [origin].
  ///
  /// Identities, not values: callers use them to delete precisely what they
  /// put there, and the core has no reason to read a session secret.
  Future<Set<String>> identitiesFor(String origin);

  Future<bool> clearCookies();

  Future<bool> clearWebsiteData();

  /// Cookies and website data together. True when nothing remains.
  Future<bool> clearAll();

  /// Finishes a purge queued by an earlier, possibly failed, sign-out.
  ///
  /// Distinct from [clearAll]: this is the "did the last logout actually
  /// complete" boundary that must hold before a new auth surface opens. It is
  /// a no-op, returning true, when nothing is pending.
  Future<bool> completePendingClear();
}

/// No browser surface, therefore nothing to clear.
///
/// Reports success from every purge because a host with no cookie store has,
/// trivially, no cookies left over.
class NullCookieJarPort implements CookieJarPort {
  const NullCookieJarPort();

  @override
  bool get isSupported => false;

  @override
  Future<Set<String>> identitiesFor(String origin) async => const <String>{};

  @override
  Future<bool> clearCookies() async => true;

  @override
  Future<bool> clearWebsiteData() async => true;

  @override
  Future<bool> clearAll() async => true;

  @override
  Future<bool> completePendingClear() async => true;
}
