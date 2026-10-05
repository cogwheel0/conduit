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

/// One `Max-Age=0` write that may expire a cookie in Android's WebView
/// cookie manager, which deletes only by overwriting a cookie with the same
/// name, path and domain (no domain: the host-only cookie).
typedef WebViewCookieExpiry = ({String path, String? domain, bool secure});

/// The writes that expire [name] for [url] on Android whatever attributes it
/// was stored with. Android reports neither the domain nor the path of a
/// cookie reliably, so the reported [path] and [domain] are only hints:
///
///  * `Secure` for an https [url] or a `__Host-`/`__Secure-` name: Chromium
///    refuses a prefixed cookie without it, the deletion included;
///  * the host-only cookie (no `Domain`) and, when given, the [domain]
///    cookie; never a `Domain` for `__Host-`, which forbids one;
///  * [path], `/` and [url]'s own path (a server behind a proxy prefix sets
///    `Path=<prefix>`, as Hermes' dashboard does), each with and without a
///    trailing slash, since a cookie stored with `Path=/prefix/` is replaced
///    only by that exact path; only `/` for `__Host-`.
///
/// Android's cookie manager reports only a cookie's name and value, so the
/// path and domain of a tracked cookie cannot be told apart from another
/// cookie's of the same name. The writes are therefore scoped to the tracked
/// cookie's name and the origin's host, not to a path: a cookie another
/// service stored under the same name on the same host can be expired along
/// with it, which is the price of being able to clear a cookie whose path is
/// unknown.
List<WebViewCookieExpiry> androidWebViewCookieExpiries({
  required Uri url,
  required String name,
  String? path,
  String? domain,
}) {
  final hostOnly = name.startsWith('__Host-');
  final secure =
      url.scheme.toLowerCase() == 'https' ||
      hostOnly ||
      name.startsWith('__Secure-');
  String normalized(String? value) {
    final trimmed = (value ?? '').replaceFirst(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? '/' : trimmed;
  }

  final paths = hostOnly
      ? const ['/']
      : {
          for (final candidate in [
            normalized(path),
            '/',
            normalized(url.path),
          ]) ...[candidate, if (candidate != '/') '$candidate/'],
        }.toList();
  final hint = domain?.trim();
  final domains = hostOnly || hint == null || hint.isEmpty
      ? const <String?>[null]
      : <String?>[null, hint];
  return [
    for (final path in paths)
      for (final domain in domains)
        (path: path, domain: domain, secure: secure),
  ];
}
