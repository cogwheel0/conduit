import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';

// Single sign-on to a LibreChat server: the rules a sign-in browser (the
// phone's web view, the desktop's window) follows, so both decide alike.

/// What the single sign-on page does with one navigation.
enum LibreChatSsoNavigation {
  /// Let it load: the provider's pages, and LibreChat's own sign-in routes.
  allow,

  /// LibreChat's OAuth callback: the provider sent the browser back, and
  /// this response sets the session. Let it load.
  providerReturned,

  /// A page of LibreChat's outside its sign-in routes. Once the provider has
  /// returned, this is LibreChat sending the browser on to its web app: the
  /// sign-in finished. Before that it may be a provider that shares
  /// LibreChat's address, which loads as usual.
  appPage,

  /// LibreChat sent the browser back to its sign-in page with an error.
  fail,
}

/// What to do with a navigation to [target] during single sign-on on a
/// server reached at [serverOrigins]. A path there is the server's base
/// path, which its routes are read below.
///
/// LibreChat signs in by redirecting through `/oauth/<provider>` and the
/// provider, back to `/oauth/<provider>/callback`, which sets its session
/// cookies and redirects to its web app. That last hop is cancelled: the
/// web app would renew the session on load and rotate the refresh cookie
/// under the app's feet.
LibreChatSsoNavigation libreChatSsoNavigation(
  Uri target, {
  required Iterable<Uri> serverOrigins,
}) {
  final server = serverOrigins
      .where((origin) => _sameOrigin(origin, target))
      .firstOrNull;
  if (server == null) return LibreChatSsoNavigation.allow;
  // A server under a sub-path such as `/oauth/librechat` must not have its
  // web app read as an OAuth route.
  final base = _basePath(server);
  var path = target.path;
  if (base.isNotEmpty && (path == base || path.startsWith('$base/'))) {
    path = path.substring(base.length);
  }
  final segments = Uri(path: path).pathSegments;
  final oauth = segments.lastIndexOf('oauth');
  if (oauth >= 0 &&
      oauth == segments.length - 3 &&
      segments.last == 'callback') {
    return LibreChatSsoNavigation.providerReturned;
  }
  if (segments.contains('oauth') || segments.contains('api')) {
    return LibreChatSsoNavigation.allow;
  }
  if (segments.isNotEmpty &&
      segments.last == 'login' &&
      target.queryParameters.containsKey('error')) {
    return LibreChatSsoNavigation.fail;
  }
  return LibreChatSsoNavigation.appPage;
}

/// Where single sign-on on [baseUrl] starts, and where its session cookies
/// are read: the server's own address for itself ([serverDomain]), since
/// the provider returns there, as long as that is the configured server --
/// the same origin and the same path.
///
/// A server naming another server as its own is not followed, nor another
/// path on the same host, which can be another server behind the same
/// proxy: the session that server's sign-in leaves would be sent to the
/// configured one. (Its own web app cannot sign in that way either.)
Uri libreChatSsoBase(String baseUrl, String? serverDomain) {
  final configured = Uri.parse(baseUrl);
  final own = serverDomain == null
      ? null
      : LibreChatServer.normalizeBaseUrl(serverDomain);
  if (own != null) {
    final domain = Uri.parse(own);
    if (_sameOrigin(domain, configured) &&
        _basePath(domain) == _basePath(configured)) {
      return domain;
    }
  }
  return configured;
}

/// Where a sign-in's session cookies are read: the server's base path, so a
/// server under a sub-path (whose proxy may scope its cookies to it) gives
/// them up too. Cookies scoped to the whole host match it as well.
Uri libreChatSsoCookieUrl(Uri base) => Uri(
  scheme: base.scheme,
  host: base.host,
  port: base.hasPort ? base.port : null,
  path: base.path.endsWith('/') ? base.path : '${base.path}/',
);

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    _port(a) == _port(b);

String _basePath(Uri uri) => uri.path.endsWith('/')
    ? uri.path.substring(0, uri.path.length - 1)
    : uri.path;

int _port(Uri uri) =>
    uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

/// The session cookies a finished single sign-on left in the web view, read
/// natively (they are httpOnly), as LibreChat cookies.
LibreChatCookies libreChatCookiesFrom(Map<String, String> cookies) =>
    LibreChatCookies.of([
      for (final entry in cookies.entries)
        if (entry.key.isNotEmpty && entry.value.isNotEmpty)
          LibreChatCookie(name: entry.key, value: entry.value),
    ]);
