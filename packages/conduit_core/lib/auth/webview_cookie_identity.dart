/// How the app identifies WebView cookies, so every WebView surface tracks
/// and clears the same ones.
library;

/// A cookie's identity: name, path and domain, as the WebView stores it.
String webViewCookieIdentity({
  required String name,
  String? path,
  String? domain,
}) => '$name\u0000${path ?? '/'}\u0000${domain ?? ''}';

/// Whether a cookie set for [domain] belongs to [host] exactly.
///
/// Host-only cookies (no domain) belong to the host that set them. A cookie
/// for a parent domain is shared with sibling hosts, so clearing one host's
/// session must leave it alone.
bool webViewCookieBelongsToExactHost(String? domain, String host) {
  final raw = domain?.trim().toLowerCase();
  final normalized = raw?.startsWith('.') == true ? raw!.substring(1) : raw;
  return normalized == null || normalized.isEmpty || normalized == host;
}
