/// The dashboard bridge for a host without a WebView to send requests from:
/// the dashboard session's cookies, captured once from a sign-in window,
/// sent from Dart with each request, and the session Hermes rotates in its
/// answers kept.
///
/// The phone issues dashboard requests from a hidden WebView page
/// ([HermesDashboardRestSession]) because the WebView holds the cookies. A
/// desktop sidecar has no WebView: its window runs the sign-in in its own
/// browser window and hands the cookies over. From then on this session is
/// the WebView's cookie store and its page in one: it keeps the cookies by
/// the browser's rules ([HermesDashboardCookieJar]), sends them only to the
/// dashboard's exact origin, with the gateway's access headers, and follows
/// no redirect, as the page's `fetch(..., {redirect: 'error'})` does.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/auth/webview_cookie_identity.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';

/// The most bytes a dashboard answer may have, as the page's fetch script
/// allows ([kHermesDashboardFetchScript]).
const int kHermesDashboardMaxResponseBytes = 4194304;

/// One cookie of a dashboard session: as a sign-in window read it, or as a
/// response set it.
final class HermesDashboardCookie {
  const HermesDashboardCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.secure = false,
    this.httpOnly = false,
    this.hostOnly = true,
    this.expires,
  });

  final String name;

  /// As the server wrote it, quotes included: it goes back verbatim.
  final String value;

  /// Lower case, without a leading dot.
  final String domain;
  final String path;
  final bool secure;
  final bool httpOnly;

  /// Sent to [domain] alone, not to its subdomains (no `Domain` attribute).
  final bool hostOnly;

  /// Null for a session cookie (kept until the session is cleared).
  final DateTime? expires;

  /// The identity the cookie registry records
  /// ([webViewCookieIdentity]: name, path, domain).
  String get identity => webViewCookieIdentity(
    name: name,
    path: path,
    domain: hostOnly ? domain : '.$domain',
  );

  bool isExpired(DateTime now) => expires != null && !expires!.isAfter(now);

  /// Whether a request to [url] carries this cookie (RFC 6265 §5.4).
  bool matches(Uri url, DateTime now) {
    if (isExpired(now)) return false;
    if (secure && url.scheme != 'https') return false;
    if (!hermesDashboardCookieDomainMatches(
      domain,
      url.host,
      hostOnly: hostOnly,
    )) {
      return false;
    }
    return hermesDashboardCookiePathMatches(
      path,
      url.path.isEmpty ? '/' : url.path,
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    if (secure) 'secure': true,
    if (httpOnly) 'httpOnly': true,
    if (!hostOnly) 'hostOnly': false,
    if (expires != null) 'expires': expires!.toUtc().millisecondsSinceEpoch,
  };

  static HermesDashboardCookie? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final value = json['value'];
    final domain = json['domain'];
    if (name is! String || name.isEmpty || value is! String) return null;
    if (domain is! String || domain.isEmpty) return null;
    final expires = json['expires'];
    return HermesDashboardCookie(
      name: name,
      value: value,
      domain: domain.toLowerCase(),
      path: json['path'] is String ? json['path'] as String : '/',
      secure: json['secure'] == true,
      httpOnly: json['httpOnly'] == true,
      hostOnly: json['hostOnly'] != false,
      expires: expires is int
          ? DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true)
          : null,
    );
  }
}

String _bareHost(String host) {
  final lower = host.toLowerCase();
  return lower.startsWith('[') && lower.endsWith(']')
      ? lower.substring(1, lower.length - 1)
      : lower;
}

/// Whether a cookie for [domain] goes to [host]: the same host, or for a
/// domain cookie a subdomain of it. An IP address only matches itself.
bool hermesDashboardCookieDomainMatches(
  String domain,
  String host, {
  bool hostOnly = true,
}) {
  final cookie = _bareHost(domain.replaceFirst(RegExp(r'^\.'), ''));
  final target = _bareHost(host);
  if (cookie.isEmpty) return false;
  if (cookie == target) return true;
  if (hostOnly || InternetAddress.tryParse(target) != null) return false;
  return target.endsWith('.$cookie');
}

/// Whether a cookie for [cookiePath] goes to [requestPath].
bool hermesDashboardCookiePathMatches(String cookiePath, String requestPath) {
  if (cookiePath == requestPath) return true;
  if (!requestPath.startsWith(cookiePath)) return false;
  return cookiePath.endsWith('/') || requestPath[cookiePath.length] == '/';
}

/// The default path of a cookie a response to [url] set without `Path`
/// (RFC 6265 §5.1.4).
String _defaultPath(Uri url) {
  final path = url.path;
  if (path.isEmpty || !path.startsWith('/')) return '/';
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}

/// One `Set-Cookie` header of a response to [url] as a cookie, or null when
/// a browser would ignore it (no name, or a domain [url] is not in). A
/// cookie that is already expired comes back expired: it deletes the one it
/// names.
HermesDashboardCookie? parseHermesDashboardSetCookie(
  String header,
  Uri url, {
  DateTime? now,
}) {
  final parts = header.split(';');
  final pair = parts.first;
  final equals = pair.indexOf('=');
  if (equals <= 0) return null;
  final name = pair.substring(0, equals).trim();
  final value = pair.substring(equals + 1).trim();
  if (name.isEmpty) return null;
  final at = (now ?? DateTime.now()).toUtc();
  String? domain;
  String? path;
  var secure = false;
  var httpOnly = false;
  DateTime? expires;
  DateTime? maxAgeExpiry;
  for (final attribute in parts.skip(1)) {
    final eq = attribute.indexOf('=');
    final key = (eq < 0 ? attribute : attribute.substring(0, eq))
        .trim()
        .toLowerCase();
    final raw = eq < 0 ? '' : attribute.substring(eq + 1).trim();
    switch (key) {
      case 'domain':
        final d = raw.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
        if (d.isNotEmpty) domain = d;
      case 'path':
        if (raw.startsWith('/')) path = raw;
      case 'secure':
        secure = true;
      case 'httponly':
        httpOnly = true;
      case 'max-age':
        final seconds = int.tryParse(raw);
        if (seconds != null) {
          maxAgeExpiry = seconds <= 0
              ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
              : at.add(Duration(seconds: seconds));
        }
      case 'expires':
        try {
          expires = HttpDate.parse(raw);
        } on FormatException {
          // A browser ignores an Expires it cannot read.
        } on HttpException {
          // Likewise.
        }
    }
  }
  final host = _bareHost(url.host);
  if (domain != null &&
      !hermesDashboardCookieDomainMatches(domain, host, hostOnly: false)) {
    return null;
  }
  return HermesDashboardCookie(
    name: name,
    value: value,
    domain: domain ?? host,
    path: path ?? _defaultPath(url),
    secure: secure,
    httpOnly: httpOnly,
    hostOnly: domain == null,
    expires: maxAgeExpiry ?? expires,
  );
}

/// The dashboard sessions' cookies, kept by a browser's rules: one cookie
/// per name, domain and path; an expired one deleted.
final class HermesDashboardCookieJar {
  HermesDashboardCookieJar([Iterable<HermesDashboardCookie> cookies = const []])
    : _cookies = {for (final c in cookies) c.identity: c};

  final Map<String, HermesDashboardCookie> _cookies;

  List<HermesDashboardCookie> get cookies => List.unmodifiable(_cookies.values);

  bool get isEmpty => _cookies.isEmpty;

  /// The `Cookie` header a request to [url] carries, or null with none.
  /// Longer paths first, as a browser orders them.
  String? cookieHeader(Uri url, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    final sent = _cookies.values.where((c) => c.matches(url, at)).toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    if (sent.isEmpty) return null;
    return sent.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Puts [cookie] in, replacing the one of its identity; an expired one
  /// deletes it. True when the jar changed.
  bool put(HermesDashboardCookie cookie, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    if (cookie.isExpired(at)) return _cookies.remove(cookie.identity) != null;
    final previous = _cookies[cookie.identity];
    _cookies[cookie.identity] = cookie;
    return previous?.value != cookie.value ||
        previous?.expires != cookie.expires ||
        previous?.secure != cookie.secure;
  }

  /// Takes in the `Set-Cookie` headers of a response to [url]. True when
  /// the jar changed.
  bool absorb(Uri url, Iterable<String> setCookies, {DateTime? now}) {
    var changed = false;
    for (final header in setCookies) {
      final cookie = parseHermesDashboardSetCookie(header, url, now: now);
      if (cookie != null && put(cookie, now: now)) changed = true;
    }
    return changed;
  }

  /// The identities of the cookies [host] is sent (any port: cookies
  /// ignore ports), expired ones left out.
  Set<String> identitiesFor(String host, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    return {
      for (final c in _cookies.values)
        if (!c.isExpired(at) &&
            hermesDashboardCookieDomainMatches(
              c.domain,
              host,
              hostOnly: c.hostOnly,
            ))
          c.identity,
    };
  }

  /// Removes the cookies of [identities]. True when the jar changed.
  bool removeAll(Iterable<String> identities) {
    var changed = false;
    for (final identity in identities) {
      if (_cookies.remove(identity) != null) changed = true;
    }
    return changed;
  }

  List<Object?> toJson() => [for (final c in _cookies.values) c.toJson()];

  static HermesDashboardCookieJar fromJson(Object? json) =>
      HermesDashboardCookieJar([
        if (json is List)
          for (final entry in json) ?HermesDashboardCookie.fromJson(entry),
      ]);
}

/// Opens the HTTP client a dashboard request goes out on (the connection's
/// certificate trust).
typedef HermesDashboardHttpClientFactory = HttpClient Function();

/// [HermesDashboardBridge] over plain HTTP with [jar]'s cookies.
final class HermesDashboardHttpSession implements HermesDashboardBridge {
  HermesDashboardHttpSession({
    required Uri root,
    required Map<String, String> accessHeaders,
    required HermesDashboardCookieJar jar,
    Future<void> Function()? onCookiesChanged,
    HermesDashboardHttpClientFactory? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _root = root,
       _accessHeaders = Map.unmodifiable(accessHeaders),
       _jar = jar,
       _onCookiesChanged = onCookiesChanged,
       _httpClient = httpClient ?? HttpClient.new;

  final Uri _root;
  final Map<String, String> _accessHeaders;
  final HermesDashboardCookieJar _jar;
  final Future<void> Function()? _onCookiesChanged;
  final HermesDashboardHttpClientFactory _httpClient;
  final Duration requestTimeout;

  HttpClient? _client;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  HttpClient get _open => _client ??= _httpClient();

  @override
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
    bool urgent = false,
    bool Function()? beforeSend,
  }) {
    if (urgent) {
      return _send(method, url, body: body, beforeSend: beforeSend);
    }
    final completer = Completer<({int status, String body})>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(
          await _send(method, url, body: body, beforeSend: beforeSend),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<({int status, String body})> _send(
    String method,
    Uri url, {
    String? body,
    bool Function()? beforeSend,
  }) async {
    if (_closed) throw StateError('Hermes dashboard session is closed.');
    // The cookies and the access headers go to the dashboard alone.
    if (!hermesDashboardIsExactOrigin(url, _root)) {
      throw StateError('Hermes dashboard requests stay on the dashboard.');
    }
    if (beforeSend?.call() == false) {
      throw const HermesDashboardRequestWithdrawn();
    }
    final response = await _exchange(
      method,
      url,
      body: body,
    ).timeout(requestTimeout);
    return response;
  }

  Future<({int status, String body})> _exchange(
    String method,
    Uri url, {
    String? body,
  }) async {
    final request = await _open.openUrl(method, url);
    request.followRedirects = false;
    _accessHeaders.forEach(request.headers.set);
    final cookies = _jar.cookieHeader(url);
    if (cookies != null) request.headers.set(HttpHeaders.cookieHeader, cookies);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(body));
    }
    final response = await request.close();
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies != null && _jar.absorb(url, setCookies)) {
      await _onCookiesChanged?.call();
    }
    if (response.isRedirect ||
        (response.statusCode >= 300 && response.statusCode < 400)) {
      await response.drain<void>();
      throw StateError('Hermes dashboard answered with a redirect.');
    }
    final declared = response.contentLength;
    if (declared > kHermesDashboardMaxResponseBytes) {
      await response.drain<void>();
      throw StateError('Hermes dashboard response is too large.');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > kHermesDashboardMaxResponseBytes) {
        throw StateError('Hermes dashboard response is too large.');
      }
    }
    return (
      status: response.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
    );
  }

  /// Nothing to reload: Hermes rotates an expired session on the next
  /// request that carries its refresh cookie, and the answer's cookies are
  /// kept ([request]).
  @override
  Future<void> reload() => _tail;

  @override
  Future<void> close() async {
    await _tail;
    _closed = true;
    _client?.close(force: true);
    _client = null;
  }
}

/// Signs [root]'s dashboard session out on the server, with [jar]'s cookies
/// and [accessHeaders]: Hermes answers a sign-out with a redirect to its
/// sign-in page carrying the deletions of its cookies, which [jar] takes.
/// True when Hermes signed it out ([kHermesDashboardSignOutScript]'s rule).
Future<bool> hermesDashboardHttpSignOut({
  required Uri root,
  required Map<String, String> accessHeaders,
  required HermesDashboardCookieJar jar,
  Future<void> Function()? onCookiesChanged,
  HermesDashboardHttpClientFactory? httpClient,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final url = hermesDashboardLogoutUrl(root);
  final client = (httpClient ?? HttpClient.new)();
  try {
    return await Future<bool>(() async {
      final request = await client.postUrl(url);
      request.followRedirects = false;
      accessHeaders.forEach(request.headers.set);
      final cookies = jar.cookieHeader(url);
      if (cookies != null) {
        request.headers.set(HttpHeaders.cookieHeader, cookies);
      }
      // A same-origin write, as the page's own POST would be.
      request.headers.set('Origin', root.origin);
      final response = await request.close();
      final setCookies = response.headers[HttpHeaders.setCookieHeader];
      if (setCookies != null && jar.absorb(url, setCookies)) {
        await onCookiesChanged?.call();
      }
      await response.drain<void>();
      return response.statusCode >= 300 && response.statusCode < 400;
    }).timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
