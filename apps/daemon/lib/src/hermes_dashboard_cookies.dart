import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_bridge.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_cookie_registry.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_http_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_dashboard_webview_rules.dart';
import 'package:conduit_core/features/hermes/services/hermes_http_transport.dart';
import 'package:conduit_core/ports/cookie_jar_port.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';

/// The secure store key the dashboard sessions' cookies are kept under.
const String kHermesDashboardCookiesKey = 'hermes.dashboardCookies';

/// The base names (without a `__Host-`/`__Secure-` prefix or a gateway's
/// `_<16 hex>` suffix) of the cookies that hold a dashboard session.
const Set<String> _sessionCookieNames = {
  'hermes_session_at',
  'hermes_session_rt',
};

bool _isSessionCookie(String name) => _sessionCookieNames.contains(
  name
      .replaceFirst(RegExp(r'^__(?:Host|Secure)-'), '')
      .replaceFirst(RegExp(r'_[0-9a-f]{16}$'), ''),
);

/// The daemon's cookie store: what a WebView's is on a phone, for the one
/// thing the daemon needs one for, a Desktop Gateway's dashboard sign-in.
///
/// The window runs the sign-in in a browser window of its own, with a
/// store of its own that goes with the window, and hands the dashboard's
/// cookies over ([adopt]). From then on the daemon is the browser: the
/// dashboard bridge ([bridge]) sends them with each dashboard request and
/// keeps what Hermes rotates, a sign-out ([signOut]) asks Hermes to end the
/// session, and the core's [clearForOrigin] deletes what the sign-in
/// recorded ([HermesDashboardCookieRegistry]), as the phone's WebView glue
/// does. The cookies are secrets: they live in the secure store.
///
/// A sign-in's cookies enter the jar at one commit point ([_commit]), taken
/// in turn with every clear: only while no clear started after the sign-in
/// did and its caller still wants them (the connection it was made under is
/// still in use).
///
/// Open WebUI's sign-in windows keep nothing (their stores go with them),
/// so the full purges the core asks for at an Open WebUI sign-out
/// ([clearAll] and the rest) have nothing of theirs here, and leave the
/// Hermes sessions alone.
final class DaemonHermesDashboardCookies implements CookieJarPort {
  DaemonHermesDashboardCookies._(this._store, this._jar);

  /// Reads the kept cookies from [store].
  static Future<DaemonHermesDashboardCookies> open(
    SecureKeyValueStore store,
  ) async {
    HermesDashboardCookieJar jar;
    try {
      final source = await store.read(key: kHermesDashboardCookiesKey);
      jar = source == null
          ? HermesDashboardCookieJar()
          : HermesDashboardCookieJar.fromJson(jsonDecode(source));
    } on Object {
      jar = HermesDashboardCookieJar();
    }
    return DaemonHermesDashboardCookies._(store, jar);
  }

  final SecureKeyValueStore _store;
  final HermesDashboardCookieJar _jar;
  Future<void> _saving = Future<void>.value();

  /// The tail of the commits and clears, run one at a time.
  Future<void> _turn = Future<void>.value();

  /// The cookies, for tests and diagnostics.
  List<HermesDashboardCookie> get cookies => _jar.cookies;

  Future<void> _save() {
    final value = _jar.isEmpty ? null : jsonEncode(_jar.toJson());
    return _saving = _saving
        .then(
          (_) => _store.write(key: kHermesDashboardCookiesKey, value: value),
        )
        .catchError((Object _) {});
  }

  /// Runs [body] after every commit and clear before it.
  Future<T> _inTurn<T>(Future<T> Function() body) {
    final run = _turn.then((_) => body());
    _turn = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  static String? _host(String origin) {
    final host = Uri.tryParse(origin)?.host;
    return host == null || host.isEmpty ? null : host;
  }

  /// The commit point: takes [cookies], a sign-in window's for [root]'s
  /// host, while sign-in [generation] is still [root]'s latest and
  /// [wanted] still holds, checked in turn right before the jar changes.
  /// Those of its host are kept, and recorded as this sign-in's for [root]
  /// (the window's store was fresh, so every one of them is), as the
  /// phone's registers its sign-in. True when a session cookie was among
  /// them; false, with nothing taken, once superseded or unwanted.
  Future<bool> _commit(
    Uri root,
    Iterable<HermesDashboardCookie> cookies, {
    required int generation,
    bool Function()? wanted,
  }) {
    final origin = root.toString();
    return _inTurn(() async {
      if (!HermesDashboardCookieRegistry.isCurrent(origin, generation) ||
          !(wanted?.call() ?? true)) {
        return false;
      }
      final host = root.host;
      final taken = [
        for (final cookie in cookies)
          if (hermesDashboardCookieDomainMatches(
            cookie.domain,
            host,
            hostOnly: cookie.hostOnly,
          ))
            cookie,
      ];
      for (final cookie in taken) {
        _jar.put(cookie);
      }
      await HermesDashboardCookieRegistry.record(
        origin,
        identities: hermesDashboardCookieIdentityDelta(
          current: {for (final cookie in taken) cookie.identity},
          baseline: const {},
          retainedNames: kHermesDashboardRetainedCookieNames,
          recorded: HermesDashboardCookieRegistry.identitiesFor(origin),
        ),
        retainedNames: kHermesDashboardRetainedCookieNames,
      );
      await _save();
      return taken.any((cookie) => _isSessionCookie(cookie.name));
    });
  }

  /// Whether a dashboard session this daemon recorded for [baseUrl]'s
  /// dashboard is still held.
  bool hasSession(String baseUrl) {
    final root = hermesDashboardRoot(baseUrl);
    final recorded = HermesDashboardCookieRegistry.identitiesFor(
      root.toString(),
    );
    if (recorded.isEmpty) return false;
    final held = _jar.identitiesFor(root.host);
    return _jar.cookies.any(
      (cookie) =>
          _isSessionCookie(cookie.name) &&
          recorded.contains(cookie.identity) &&
          held.contains(cookie.identity),
    );
  }

  /// The dashboard bridge for [root] ([HermesDashboardBridgeFactory]), on
  /// [httpClient] (the connection's certificate trust).
  HermesDashboardBridge bridge({
    required Uri root,
    required Map<String, String> accessHeaders,
    HermesDashboardHttpClientFactory? httpClient,
  }) => HermesDashboardHttpSession(
    root: root,
    accessHeaders: accessHeaders,
    jar: _jar,
    onCookiesChanged: _save,
    httpClient: httpClient,
  );

  /// Signs [root]'s dashboard session out on the server
  /// ([HermesDashboardSignOut]).
  Future<bool> signOut({
    required Uri root,
    required Map<String, String> accessHeaders,
    HermesDashboardHttpClientFactory? httpClient,
  }) => hermesDashboardHttpSignOut(
    root: root,
    accessHeaders: accessHeaders,
    jar: _jar,
    onCookiesChanged: _save,
    httpClient: httpClient,
  );

  /// Takes [cookies], which a sign-in window's page on [root]'s dashboard
  /// had, when the dashboard says they are a signed-in session
  /// ([hermesDashboardAuthCheckUrl] answers 2xx only then): checked on a
  /// jar of their own first, so cookies that are not a session never
  /// replace a session held. True when they were taken ([_commit]): not
  /// once a clear of [root] started after this sign-in did, or once
  /// [wanted] (the caller's own check, made in the commit's turn) fails.
  Future<bool> adopt(
    Uri root,
    Iterable<HermesDashboardCookie> cookies, {
    required Map<String, String> accessHeaders,
    HermesDashboardHttpClientFactory? httpClient,
    bool Function()? wanted,
  }) async {
    // Begun before the check goes out: a clear meanwhile supersedes it.
    final generation = HermesDashboardCookieRegistry.begin(root.toString());
    final host = root.host;
    final own = HermesDashboardCookieJar([
      for (final cookie in cookies)
        if (hermesDashboardCookieDomainMatches(
          cookie.domain,
          host,
          hostOnly: cookie.hostOnly,
        ))
          cookie,
    ]);
    if (!own.cookies.any((cookie) => _isSessionCookie(cookie.name))) {
      return false;
    }
    final session = HermesDashboardHttpSession(
      root: root,
      accessHeaders: accessHeaders,
      jar: own,
      httpClient: httpClient,
    );
    try {
      final answer = await session.request(
        'GET',
        hermesDashboardAuthCheckUrl(root),
      );
      if (answer.status < 200 || answer.status >= 300) return false;
    } on Object {
      return false;
    } finally {
      await session.close();
    }
    // The check's answer may have rotated the session: its cookies are kept.
    return _commit(root, own.cookies, generation: generation, wanted: wanted);
  }

  // CookieJarPort

  @override
  bool get isSupported => true;

  @override
  Future<Set<String>> identitiesFor(String origin) async {
    final host = _host(origin);
    return host == null ? const {} : _jar.identitiesFor(host);
  }

  @override
  Future<bool> clearForOrigin(String origin) {
    // Superseded now, before its turn: a sign-in waiting for one keeps
    // nothing.
    if (!HermesDashboardCookieRegistry.invalidate(origin)) {
      return Future<bool>.value(true);
    }
    return _inTurn(() async {
      final recorded = HermesDashboardCookieRegistry.identitiesFor(origin);
      if (_jar.removeAll(recorded)) await _save();
      await HermesDashboardCookieRegistry.forget(origin);
      return true;
    });
  }

  @override
  Future<bool> clearCookies() async => true;

  @override
  Future<bool> clearWebsiteData() async => true;

  @override
  Future<bool> clearAll() async => true;

  @override
  Future<bool> completePendingClear() async => true;
}

/// The HTTP client a dashboard request for [root] goes out on: [config]'s
/// certificate trust when it is that dashboard's connection.
HermesDashboardHttpClientFactory? hermesDashboardHttpClientFor(
  Uri root,
  HermesConfig config,
) {
  if (config.baseUrl.isEmpty ||
      !hermesDashboardIsExactOrigin(
        hermesDashboardRoot(config.baseUrl),
        root,
      )) {
    return null;
  }
  if (!config.allowSelfSignedCertificates) return null;
  return () => hermesTlsHttpClient(config) ?? HttpClient();
}
